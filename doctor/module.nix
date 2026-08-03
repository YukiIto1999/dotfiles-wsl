{
  config,
  lib,
  pkgs,
  mkCommand,
  ...
}:

let
  cfg = config.my;
  homeConfig = config.home-manager.users.${cfg.username};
  inherit (cfg) clis;
  names = builtins.attrNames clis;

  # doctor が観測する gateway service の資源値、上限は systemd 宣言から導く
  mcpFileLimits = lib.mapAttrs' (
    _: endpoint:
    let
      limit = lib.splitString ":" config.systemd.services."${endpoint.service}".serviceConfig.LimitNOFILE;
    in
    lib.nameValuePair endpoint.service {
      LimitNOFILE = builtins.elemAt limit 1;
      LimitNOFILESoft = builtins.elemAt limit 0;
    }
  ) cfg.contract.gateway.endpoints;
  mcpResourceProperties = [
    "MainPID"
    "TasksCurrent"
    "MemoryCurrent"
    "MemorySwapCurrent"
    "LimitNOFILE"
    "LimitNOFILESoft"
  ];

  unitManifest = lib.mapAttrsToList (id: unit: {
    inherit id;
    expected = lib.filterAttrs (_: value: value != null) unit.expected;
  }) cfg.doctor.units;

  # 生成物は artifacts が一度だけ宣言する。配備先を持つものが乖離検査の対象
  deployedArtifacts = lib.filterAttrs (_: a: a.deployedAt != null) cfg.artifacts;

  managedFileManifest = lib.mapAttrsToList (id: a: {
    inherit id;
    path = a.deployedAt;
    inherit (a) source;
  }) deployedArtifacts;

  managedFilePaths = map (a: a.deployedAt) (builtins.attrValues deployedArtifacts);

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
          endpoints = lib.mapAttrsToList (_: endpoint: {
            inherit (endpoint) id url;
            healthUnit = "${endpoint.service}.service";
            inherit (endpoint) targets;
            resources = {
              properties = mcpResourceProperties;
              expected = mcpFileLimits."${endpoint.service}";
            };
          }) cfg.contract.gateway.endpoints;
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

  doctor =
    (mkCommand {
      name = "dotfiles-doctor";
      src = ./impl/doctor.sh;
      runtimeInputs =
        (with pkgs; [
          curl
          jq
          gnugrep
          coreutils
          systemd
          util-linux
        ])
        ++ [
          rootProbe
          cfg.commands.wslRestartRequired
        ];
      vars = {
        doctorSchemaVersion = toString cfg.doctor.schemaVersion;
        doctorManifestPath = "/run/current-system/etc/dotfiles/doctor.json";
        atomicFileFunctions = builtins.readFile cfg.contract.primitives.libraries.atomicFile;
        ociImageStateFunctions = builtins.readFile cfg.contract.images.libraries.imageState;
      };
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          nixImageIdentityFiles = cfg.contract.images.identityFiles;
        };
      });
in
{
  options.my.doctor = {
    schemaVersion = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      readOnly = true;
      internal = true;
      description = "dotfiles-doctor manifest の schema version。";
    };

    units = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.expected = lib.mkOption {
            type = lib.types.submodule {
              options = {
                LoadState = lib.mkOption {
                  type = lib.types.str;
                  description = "systemd LoadState の期待値。";
                };
                ActiveState = lib.mkOption {
                  type = lib.types.str;
                  description = "systemd ActiveState の期待値。";
                };
                SubState = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "systemd SubState の期待値。null は検査しない。";
                };
                Result = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "systemd Result の期待値。null は検査しない。";
                };
              };
            };
            description = "systemctl show で検査する property と期待値。";
          };
        }
      );
      default = { };
      internal = true;
      description = "dotfiles-doctor が検査する systemd unit。attribute key が安定 id。";
    };

    probePolicy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          cliTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          systemTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          windowsTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          mcpRequestTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          mcpCleanupTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          totalTimeoutSeconds = lib.mkOption { type = lib.types.ints.positive; };
          maxPages = lib.mkOption { type = lib.types.ints.positive; };
          maxResponseBytes = lib.mkOption { type = lib.types.ints.positive; };
        };
      };
      default = {
        cliTimeoutSeconds = 5;
        systemTimeoutSeconds = 5;
        windowsTimeoutSeconds = 5;
        mcpRequestTimeoutSeconds = 5;
        mcpCleanupTimeoutSeconds = 5;
        totalTimeoutSeconds = 30;
        maxPages = 20;
        maxResponseBytes = 1048576;
      };
      internal = true;
      description = "doctor の bounded probe が共有する制限値。";
    };

    skillNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "各 CLI に配備されることを要求する skill 名。";
    };

    agentFiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      internal = true;
      description = "CLI ごとに配備を要求する agent file 名。";
    };

    wslInterop = lib.mkOption {
      type = lib.types.submodule {
        options = {
          launcherName = lib.mkOption { type = lib.types.str; };
          launcherPath = lib.mkOption { type = lib.types.str; };
          launcherSource = lib.mkOption { type = lib.types.path; };
          windowsCommand = lib.mkOption { type = lib.types.str; };
        };
      };
      internal = true;
      description = "WSL から Windows を起動する launcher と固定 command の検査契約。";
    };
  };

  config.my.commands.doctor = doctor;

  config.environment.etc."dotfiles/doctor.json".source = doctorManifest;

  # rebuild が読む契約。manifest の場所と schema を doctor が所有する
  config.my.contract.doctor.schemaVersion = cfg.doctor.schemaVersion;

  config.assertions = [
    {
      assertion = builtins.length managedFilePaths == builtins.length (lib.unique managedFilePaths);
      message = "artifact deployedAt contains duplicate runtime paths";
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

}
