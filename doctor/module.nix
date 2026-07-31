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
  gatewayFileLimit = lib.splitString ":" config.systemd.services.agentgateway.serviceConfig.LimitNOFILE;
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
        atomicFileFunctions = builtins.readFile ../rebuild/impl/lib/atomic-file.sh;
        ociImageStateFunctions = builtins.readFile ../images/impl/lib/image-state.sh;
      };
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          nixImageIdentityFiles = cfg.contract.images.identityFiles;
        };
      });
in
{
  my.commands.doctor = doctor;

  environment.etc."dotfiles/doctor.json".source = doctorManifest;

  # rebuild が読む契約。manifest の場所と schema を doctor が所有する
  my.contract.doctor = {
    manifest = doctorManifest;
    schemaVersion = cfg.doctor.schemaVersion;
  };

  assertions = [
    {
      assertion = builtins.length managedFilePaths == builtins.length (lib.unique managedFilePaths);
      message = "my.doctor.managedFiles contains duplicate runtime paths";
    }
  ];

  security.sudo.extraRules = [
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
