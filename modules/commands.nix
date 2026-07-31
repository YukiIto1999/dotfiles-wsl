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
  homeConfig = config.home-manager.users.${cfg.username};

  orElse = v: default: if v == null then default else v;

  # doctor が観測する gateway service の資源値、上限は systemd 宣言から導く
  gatewayFileLimit = lib.splitString ":" config.systemd.services.agentgateway.serviceConfig.LimitNOFILE;
  mcpResourceProperties = [
    "MainPID"
    "TasksCurrent"
    "MemoryCurrent"
    "MemorySwapCurrent"
    "LimitNOFILE"
    "LimitNOFILESoft"
  ];

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

  rootProbe = pkgs.writeShellApplication {
    name = "dotfiles-doctor-root-probe";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [[ $# -ne 0 ]]; then
        echo "dotfiles-doctor-root-probe does not accept arguments" >&2
        exit 2
      fi

      directory_metadata=$(stat --format='%u|%g|%a' /var/lib/sops-nix)
      key_metadata=$(stat --format='%u|%g|%a' /var/lib/sops-nix/key.txt)
      IFS='|' read -r directory_uid directory_gid directory_mode <<< "$directory_metadata"
      IFS='|' read -r key_uid key_gid key_mode <<< "$key_metadata"

      printf '{"directory":{"uid":%s,"gid":%s,"mode":"%s"},"key":{"uid":%s,"gid":%s,"mode":"%s"}}\n' \
        "$directory_uid" \
        "$directory_gid" \
        "$directory_mode" \
        "$key_uid" \
        "$key_gid" \
        "$key_mode"
    '';
  };

  nixosRebuildGuard = pkgs.writeShellApplication {
    name = "nixos-rebuild";
    text = ''
      echo "FATAL: direct nixos-rebuild bypasses the dotfiles rebuild transaction" >&2
      echo "Use dotfiles-rebuild for normal changes; use bootstrap/impl/bootstrap.sh only for initial provisioning." >&2
      exit 2
    '';
  };

  unitManifest = lib.mapAttrsToList (id: unit: {
    inherit id;
    expected = lib.filterAttrs (_: value: value != null) unit.expected;
  }) cfg.doctor.units;

  managedFileManifest = lib.mapAttrsToList (id: file: {
    inherit id;
    inherit (file) path source;
  }) cfg.doctor.managedFiles;

  managedFilePaths = map (file: file.path) (builtins.attrValues cfg.doctor.managedFiles);

  doctorManifest =
    (pkgs.formats.json { }).generate "doctor-manifest-v${toString cfg.doctor.schemaVersion}.json"
      {
        schemaVersion = cfg.doctor.schemaVersion;
        user = {
          name = cfg.username;
          home = cfg.homeDir;
        };
        generation = {
          current = "/run/current-system";
          booted = "/run/booted-system";
          profile = "/nix/var/nix/profiles/system";
        };
        sops = {
          rootProbe = lib.getExe rootProbe;
          homeKey = {
            path = "${cfg.homeDir}/.config/sops/age/keys.txt";
            policy = if cfg.sops.enrollmentState == "enrolled" then "reject" else "warn";
          };
        };
        units = unitManifest;
        managedFiles = managedFileManifest;
        clis = map (
          name:
          let
            cli = clis.${name};
          in
          {
            inherit name;
            binaryName = cli.binary;
            binaryPath = "${cfg.homeDir}/.local/bin/${cli.binary}";
            rules = {
              path = "${cfg.homeDir}/${cli.rulesFile}";
              source = homeConfig.home.file.${cli.rulesFile}.source;
            };
            skills = {
              directory = "${cfg.homeDir}/${cli.skillsDir}";
              names = cfg.doctor.skillNames;
            };
            agents =
              if cli.agentsDir == null then
                null
              else
                {
                  directory = "${cfg.homeDir}/${cli.agentsDir}";
                  files = cfg.doctor.agentFiles.${name};
                };
            gatewayFile =
              if cli.gatewayFile == null then
                null
              else
                {
                  path = "${cfg.homeDir}/${cli.gatewayFile}";
                  source = homeConfig.home.file.${cli.gatewayFile}.source;
                };
          }
        ) names;
        mcp = {
          url = cfg.gatewayUrl;
          targets = builtins.attrNames cfg.mcp.targets;
          healthUnit = "agentgateway.service";
          resources = {
            properties = mcpResourceProperties;
            expected = {
              LimitNOFILE = builtins.elemAt gatewayFileLimit 1;
              LimitNOFILESoft = builtins.elemAt gatewayFileLimit 0;
            };
          };
          requestedProtocolVersion = "2025-11-25";
          supportedProtocolVersions = [
            "2024-11-05"
            "2025-03-26"
            "2025-06-18"
            "2025-11-25"
          ];
        };
        oci = {
          healthUnit = "docker.service";
          stateRoot = "${cfg.homeDir}/.local/state/dotfiles-wsl/image-sync";
          dockerCommand = lib.getExe pkgs.docker;
          syncStatusCommand = cfg.contract.images.syncStatusCommand;
          images = cfg.contract.images.entries;
        };
        probePolicy = cfg.doctor.probePolicy;
        wslInterop = cfg.doctor.wslInterop;
        nixLdPath = "/lib64/ld-linux-x86-64.so.2";
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

  doctor =
    (mkCommand "dotfiles-doctor" ./commands/doctor (with pkgs; [
      curl
      jq
      gnugrep
      coreutils
      systemd
      util-linux
      rootProbe
      wslRestartRequired
    ]) { }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          nixImageIdentityFiles = cfg.contract.images.identityFiles;
        };
      });
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
      doctor
      rebuild
      wslRestartRequired
      installClis
      ;
  };

  # system generation を書き換える通常経路は dotfiles-rebuild に限定する。
  # 上流実体は config.system.build.nixos-rebuild に残し、transaction 内から store path で呼ぶ。
  config.system.tools.nixos-rebuild.enable = false;
  config.environment.systemPackages = builtins.attrValues cfg.commands ++ [ nixosRebuildGuard ];

  config.environment.etc."dotfiles/doctor.json".source = doctorManifest;

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
      assertion = builtins.length managedFilePaths == builtins.length (lib.unique managedFilePaths);
      message = "my.doctor.managedFiles contains duplicate runtime paths";
    }
    {
      assertion =
        cfg.doctor.probePolicy.mcpCleanupTimeoutSeconds < cfg.doctor.probePolicy.totalTimeoutSeconds;
      message = "my.doctor.probePolicy must reserve time for active MCP requests";
    }
  ];

  config.security.sudo.extraRules = [
    {
      users = [ cfg.username ];
      runAs = "root";
      commands = [
        {
          command = ''${lib.getExe rootProbe} ""'';
          options = [ "NOPASSWD" ];
        }
      ];
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
