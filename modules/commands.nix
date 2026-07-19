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

  # cleanup が hm-back を掃く root、.config/<x> は 2 段まで、それ以外は先頭 1 段
  cliRootOf =
    path:
    let
      segs = lib.splitString "/" path;
    in
    if builtins.head segs == ".config" then
      lib.concatStringsSep "/" (lib.sublist 0 2 segs)
    else
      builtins.head segs;

  cliRoots = lib.unique (map (name: cliRootOf clis.${name}.rulesFile) names) ++ [
    ".config/git"
    ".config/gh"
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
      echo "Use dotfiles-rebuild for normal changes; use scripts/bootstrap.sh only for initial provisioning." >&2
      exit 2
    '';
  };

  sopsGeneration = import ./lib/sops-generation-contract.nix { inherit config pkgs; };

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
          requestedProtocolVersion = "2025-11-25";
          supportedProtocolVersions = [
            "2024-11-05"
            "2025-03-26"
            "2025-06-18"
            "2025-11-25"
          ];
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
    nixosRebuild = lib.escapeShellArg (lib.getExe config.system.build.nixos-rebuild);
    operationLockFunctions = builtins.readFile ../scripts/lib/operation-lock.sh;
    rebuildReceiptFunctions = builtins.readFile ../scripts/lib/rebuild-receipt.sh;
    installTable = lib.concatStringsSep "\n" (map installRow names);
    cliRootsBashArray = lib.concatStringsSep " " (map (r: "'${r}'") cliRoots);
    hmBackupExt = config.home-manager.backupFileExtension;
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

  doctor = mkCommand "dotfiles-doctor" ./commands/doctor (with pkgs; [
    curl
    jq
    gnugrep
    coreutils
    systemd
    sudo
    rootProbe
    wslRestartRequired
  ]) { };
  wslRestartRequired = mkCommand "dotfiles-wsl-restart-required" ./commands/wsl-restart-required (
    with pkgs; [ coreutils ]) { };
  rebuild =
    mkCommand "dotfiles-rebuild" ./commands/rebuild
      (
        (with pkgs; [
          git
          coreutils
          jq
          nix
          nix-output-monitor
          nvd
          sudo
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
  cleanup = mkCommand "dotfiles-cleanup" ./commands/cleanup (with pkgs; [ coreutils ]) { };

  sopsVerifier = pkgs.writeShellApplication {
    name = "dotfiles-sops-verifier";
    runtimeInputs = with pkgs; [
      coreutils
      sops
    ];
    text = substitute {
      sopsRuntimePath = lib.escapeShellArg (
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.sops
        ]
      );
    } (builtins.readFile ./commands/sops-verifier);
  };

  mkSopsKeyctl =
    name: allowTestHooks:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        age
        coreutils
        jq
        nix
        sops
        util-linux
      ];
      text = substitute {
        inherit allowTestHooks;
        nixEnv = lib.escapeShellArg (lib.getExe' pkgs.nix "nix-env");
        sopsKeyDirectory = lib.escapeShellArg (builtins.dirOf config.sops.age.keyFile);
        sopsRuntimePath = lib.escapeShellArg (
          lib.makeBinPath [
            pkgs.age
            pkgs.coreutils
            pkgs.sops
          ]
        );
        sopsVerifier = lib.escapeShellArg (lib.getExe sopsVerifier);
        systemdRun = lib.escapeShellArg (lib.getExe' pkgs.systemd "systemd-run");
      } (builtins.readFile ./commands/sops-keyctl);
    };

  sopsKeyctl = mkSopsKeyctl "dotfiles-sops-keyctl" "0";
  sopsKeyctlTest = mkSopsKeyctl "dotfiles-sops-keyctl-test" "1";
  sopsTestSudo = pkgs.writeShellApplication {
    name = "dotfiles-sops-test-sudo";
    text = ''
      case ''${1-} in
        -v)
          [[ $# -eq 1 ]]
          ;;
        --)
          shift
          exec "$@"
          ;;
        *)
          exit 2
          ;;
      esac
    '';
  };

  mkSopsEnroll =
    name: allowTestHooks: keyctl: sudoCommand:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        age
        coreutils
        diffutils
        findutils
        git
        gnugrep
        jq
        sops
        util-linux
        yq
      ];
      text = substitute {
        inherit allowTestHooks;
        configuredDotfiles = lib.escapeShellArg cfg.dotfilesDir;
        operationLockFunctions = builtins.readFile ../scripts/lib/operation-lock.sh;
        sopsKeyctl = lib.escapeShellArg (lib.getExe keyctl);
        sopsRuntimePath = lib.escapeShellArg (
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.sops
          ]
        );
        sudoCommand = lib.escapeShellArg sudoCommand;
      } (builtins.readFile ./commands/sops-enroll);
    };

  sopsEnrollTest = mkSopsEnroll "dotfiles-sops-enroll-test" "1" sopsKeyctlTest (
    lib.getExe sopsTestSudo
  );
  sopsEnroll =
    (mkSopsEnroll "dotfiles-sops-enroll" "0" sopsKeyctl (lib.getExe pkgs.sudo)).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          testPackage = sopsEnrollTest;
          testKeyctl = sopsKeyctlTest;
          productionKeyctl = sopsKeyctl;
          productionVerifier = sopsVerifier;
        };
      });
in
{
  options.my.commands = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    description = "config から生成する運用コマンド。flake.nix の packages 出力が nixosConfiguration 経由でここを参照する。";
  };

  config.my.commands = {
    inherit
      doctor
      rebuild
      wslRestartRequired
      cleanup
      installClis
      sopsEnroll
      ;
  };

  # system generation を書き換える通常経路は dotfiles-rebuild に限定する。
  # 上流実体は config.system.build.nixos-rebuild に残し、transaction 内から store path で呼ぶ。
  config.system.tools.nixos-rebuild.enable = false;
  config.environment.systemPackages = builtins.attrValues cfg.commands ++ [ nixosRebuildGuard ];

  config.environment.etc."dotfiles/doctor.json".source = doctorManifest;
  config.environment.etc."dotfiles/sops-generation.json".source = sopsGeneration.contract;

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
