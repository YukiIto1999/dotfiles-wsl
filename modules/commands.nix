{
  config,
  lib,
  pkgs,
  ...
}:

# writeShellApplication は shellcheck を build に含むため、規約逸脱は nix build 時点で落ちる
let
  cfg = config.my;
  inherit (cfg) clis;
  names = builtins.attrNames clis;

  orElse = v: default: if v == null then default else v;

  installRow =
    name:
    let
      c = clis.${name};
    in
    if c.install.kind == "installer-script" then
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.scriptUrl
        ""
        ""
        ""
      ]
    else
      lib.concatStringsSep "|" [
        name
        c.install.kind
        c.binary
        c.install.repo
        c.install.assetByArch.x86_64
        c.install.assetByArch.aarch64
        (orElse (c.install.binaryInArchive or null) "")
      ];

  nixosRebuildGuard = pkgs.writeShellApplication {
    name = "nixos-rebuild";
    text = ''
      echo "FATAL: direct nixos-rebuild bypasses the dotfiles rebuild transaction" >&2
      echo "Use dotfiles-rebuild for normal changes; use bootstrap/impl/bootstrap.sh only for initial provisioning." >&2
      exit 2
    '';
  };

  substitute =
    vars: text:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames vars
    )) (builtins.attrValues vars) text;

  commonVars = {
    inherit (cfg) dotfilesDir username;
    bootIdFile = "/proc/sys/kernel/random/boot_id";
    nixGcAutoRootDir = "/nix/var/nix/gcroots/auto";
    nixStoreDir = builtins.storeDir;
    systemProfilePath = "/nix/var/nix/profiles/system";
    nixosRebuild = lib.escapeShellArg (lib.getExe config.system.build.nixos-rebuild);
    nixosRebuildPath = lib.getExe config.system.build.nixos-rebuild;
    sudoCommand = lib.escapeShellArg "${config.security.wrapperDir}/sudo";
    awk = lib.escapeShellArg (lib.getExe pkgs.gawk);
    activationLogLimitBytes = toString (8 * 1024 * 1024);
    legacySchema2RebuildSourceSha256 = "6981dc736aa6c38070e448b8568aa96ea67802611675129cea60ef5bfbe0c710";
    legacySchema2CandidateHelperSha256 = "6a88d31acbc01b0da1c474757bcfd02dfd58a0fc95230a1fb1ef168af57a6ae5";
    legacySchema2NixpkgsRev = "bd0ff2d3eac24699c3664d5966b9ef36f388e2ca";
    legacySchema2NixosRebuildPath = "/nix/store/gi6qsdlby13jf9szb23blh8rmywvi81i-nixos-rebuild-ng-26.05/bin/nixos-rebuild";
    atomicFileFunctions = builtins.readFile ../rebuild/impl/lib/atomic-file.sh;
    operationLockFunctions = builtins.readFile ../rebuild/impl/lib/operation-lock.sh;
    ociImageStateFunctions = builtins.readFile ../images/impl/lib/image-state.sh;
    rebuildAttemptFunctions = builtins.readFile ../rebuild/impl/lib/rebuild-attempt.sh;
    rebuildReceiptFunctions = builtins.readFile ../rebuild/impl/lib/rebuild-receipt.sh;
    installTable = lib.concatStringsSep "\n" (map installRow names);
    doctorSchemaVersion = toString cfg.doctor.schemaVersion;
    doctorManifestPath = "/run/current-system/etc/dotfiles/doctor.json";
  };

  mkCommand =
    name: srcFile: runtimeInputs: extra:
    pkgs.writeShellApplication (
      {
        inherit name runtimeInputs;
        text = substitute commonVars (builtins.readFile srcFile);
      }
      // extra
    );

  wslRestartRequired = mkCommand "dotfiles-wsl-restart-required" ./commands/wsl-restart-required (
    with pkgs; [ coreutils ]) { };
  rebuild =
    mkCommand "dotfiles-rebuild" ./commands/rebuild
      (
        (with pkgs; [
          git
          gawk
          coreutils
          jq
          nix
          nix-output-monitor
          nvd
          systemd
          util-linux
        ])
        ++ [ wslRestartRequired ]
      )
      {
        # jq programs are single-quoted; their $names come from --arg/--argjson.
        excludeShellChecks = [ "SC2016" ];
      };
  installClis = mkCommand "dotfiles-install-clis" ./commands/install-clis (with pkgs; [
    bash
    curl
    jq
    gnutar
    gzip
    coreutils
  ]) { };
in
{
  config.my.commands = {
    inherit
      rebuild
      wslRestartRequired
      installClis
      ;
  };

  # system generation を書き換える通常経路は dotfiles-rebuild に限定する。
  # 上流実体は config.system.build.nixos-rebuild に残し、transaction 内から store path で呼ぶ。
  config.system.tools.nixos-rebuild.enable = false;
  config.environment.systemPackages = builtins.attrValues cfg.commands ++ [ nixosRebuildGuard ];

  config.my.doctor.units = {
    "home-manager-${cfg.username}.service".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "exited";
      Result = "success";
    };
    "dotfiles-cli-autoupdate.timer".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "waiting";
      Result = "success";
    };
  };

  config.assertions = [
    {
      assertion =
        cfg.doctor.probePolicy.mcpCleanupTimeoutSeconds < cfg.doctor.probePolicy.totalTimeoutSeconds;
      message = "my.doctor.probePolicy must reserve time for active MCP requests";
    }
  ];

  config.systemd.services.dotfiles-cli-autoupdate = {
    description = "AI CLI を latest へ更新";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = cfg.username;
      Environment = [
        "HOME=${cfg.homeDir}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
      ];
      ExecStart = lib.getExe installClis;
    };
  };

  config.systemd.timers.dotfiles-cli-autoupdate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
