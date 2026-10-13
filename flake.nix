{
  description = "NixOS on WSL2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-26.05";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    devenv.url = "github:cachix/devenv/b904dcb51fe48c30db250038241507f60752f222";
    actrun.url = "github:mizchi/actrun/1db9aff5b364de6eacda68e3f2ce2238f9992272";

    orca = {
      url = "github:stablyai/orca/a7927b28ce45cbb044add478d957abe36c99ccd8";
      flake = false;
    };

    architectureStandard = {
      url = "github:YukiIto1999/architecture-standard";
      flake = false;
    };

    mattSkills = {
      url = "github:mattpocock/skills/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d";
      flake = false;
    };

    chromeDevtoolsMcp = {
      url = "tarball+https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-1.10.1.tgz";
      flake = false;
    };

    dotnetSkills = {
      url = "github:dotnet/skills/0dcd43ceb15e15a2c45dd54075fbcf3a30632154";
      flake = false;
    };

    explainerSkills = {
      url = "github:mizchi/explainer/578defba7249fde5366689424ed6017f76b5598b";
      flake = false;
    };

    modernWebGuidance = {
      url = "github:GoogleChrome/modern-web-guidance/650eb83619134adb947b1ee8755e6511270bc444";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
      sops-nix,
      orca,
      architectureStandard,
      mattSkills,
      chromeDevtoolsMcp,
      dotnetSkills,
      explainerSkills,
      modernWebGuidance,
      ...
    }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;
      referenceHostName = "nixos";
      hostProfileDirectory = ./profiles/hosts;
      hostProfileEntries = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
        builtins.readDir hostProfileDirectory
      );
      hostNames = map (lib.removeSuffix ".nix") (builtins.attrNames hostProfileEntries);
      pluginSources = {
        inherit orca;
        matt-pocock = mattSkills;
        architecture-standard = architectureStandard;
        chrome-devtools = chromeDevtoolsMcp;
        dotnet = dotnetSkills;
        explainer = explainerSkills;
        modern-web-guidance = modernWebGuidance;
      };
      collectUnits = import ./checks/impl/collect-units.nix { inherit (nixpkgs) lib; };
      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      readOnlyPackageModule = "${nixpkgs}/nixos/modules/misc/nixpkgs/read-only.nix";
      packageOwnerModule = {
        _file = toString ./flake.nix;
        nixpkgs.pkgs = systemPkgs;
      };
      mkNixosSystem =
        machineModules:
        let
          machine = lib.nixosSystem {
            specialArgs = {
              inherit pluginSources self;
            };
            modules =
              unitModules
              ++ [
                readOnlyPackageModule
                packageOwnerModule
                nixos-wsl.nixosModules.default
                sops-nix.nixosModules.sops
                home-manager.nixosModules.home-manager
              ]
              ++ lib.toList machineModules;
          };
        in
        assert lib.assertMsg (lib.all (definition: definition.file == packageOwnerModule._file)
          machine.options.nixpkgs.pkgs.definitionsWithLocations
        ) "Nixpkgs package set must be declared in flake.nix";
        assert lib.assertMsg (lib.all
          (
            option:
            lib.all (definition: definition.file == readOnlyPackageModule) option.definitionsWithLocations
          )
          [
            machine.options.nixpkgs.config
            machine.options.nixpkgs.overlays
            machine.options.nixpkgs.hostPlatform
            machine.options.nixpkgs.buildPlatform
          ]
        ) "Nixpkgs config, overlays and platforms must be declared in flake.nix";
        machine;

      # 検査用 system ごとの manual 評価が T1 の予算を圧迫するため host と同一構成のままは不可
      probeModule = {
        documentation.nixos.enable = false;
        home-manager.sharedModules = [ { manual.manpages.enable = false; } ];
      };
      mkProbeSystem = machineModules: mkNixosSystem (lib.toList machineModules ++ [ probeModule ]);

      mkMachineModule = hostName: {
        imports = [
          ./profiles/workstation.nix
          (hostProfileDirectory + "/${hostName}.nix")
        ];
        networking.hostName = hostName;
      };
      normalMachineModule = mkMachineModule referenceHostName;
      nixosSystems = lib.genAttrs hostNames (hostName: mkNixosSystem (mkMachineModule hostName));
      machineConfigs = lib.mapAttrs (_: machine: machine.config) nixosSystems;
      machineOptions = lib.mapAttrs (_: machine: machine.options) nixosSystems;

      systemPkgs = nixpkgs.legacyPackages.${system};

      artifactVariantSystem = mkNixosSystem [
        normalMachineModule
        { dotfiles.platform.mcp.gateway.port = 9876; }
      ];
      artifactVariantConfig = artifactVariantSystem.config;
      minimalCapabilityConfig =
        (mkProbeSystem [
          normalMachineModule
          { dotfiles.capabilities.enabled = lib.mkForce [ "project-memory" ]; }
        ]).config;
      projectMemoryDisabledConfig =
        (mkProbeSystem [
          normalMachineModule
          {
            dotfiles.capabilities.enabled = lib.mkForce (
              builtins.filter (
                name: name != "project-memory"
              ) machineConfigs.${referenceHostName}.dotfiles.capabilities.enabled
            );
          }
        ]).config;

      mergeCheckParts = import ./checks/impl/merge-check-parts.nix { inherit lib; };
      hostToplevelChecks = lib.mapAttrs' (
        hostName: machine: lib.nameValuePair "${hostName}-toplevel" machine.config.system.build.toplevel
      ) nixosSystems;

      closureChecks = mergeCheckParts [
        hostToplevelChecks
        { nixos-variant-toplevel = artifactVariantConfig.system.build.toplevel; }
      ];

      unitChecks =
        let
          # 各 unit の checks.nix を集め、id の重複を拒否する
          mergeChecks =
            args: units:
            let
              files = builtins.filter builtins.pathExists (map (unit: unit.path + "/checks.nix") units);
              # 名前は attrset の spine だけで決まるので、値が allCheckNames を参照しても循環しない
              perUnit = map (file: import file (args // { inherit allCheckNames; })) files;
              names = lib.concatMap builtins.attrNames perUnit;
              allCheckNames = builtins.attrNames closureChecks ++ names;
            in
            if allCheckNames == lib.unique allCheckNames then
              lib.foldl' (acc: set: acc // set) { } perUnit
            else
              throw "duplicate check id: ${
                lib.concatStringsSep " " (
                  lib.unique (lib.filter (n: lib.count (m: m == n) allCheckNames > 1) allCheckNames)
                )
              }";

          hostConfig = machineConfigs.${referenceHostName};
          inherit (nixosSystems.${referenceHostName}) pkgs;
          inherit (pkgs) lib;
        in
        mergeChecks {
          inherit
            pkgs
            lib
            self
            hostConfig
            hostNames
            machineConfigs
            machineOptions
            minimalCapabilityConfig
            projectMemoryDisabledConfig
            mkProbeSystem
            pluginSources
            sops-nix
            ;
          inherit normalMachineModule;
          hostOptions = nixosSystems.${referenceHostName}.options;
          inherit units;
          # checks が共有する eval 時 helper。unit の impl を path で直読みさせない
          helpers = {
            execTokens = import ./checks/impl/exec-tokens.nix { inherit lib; };
            inherit mergeCheckParts;
            unitOwnership = import ./checks/impl/unit-ownership.nix { inherit lib; };
            observationRegistryModule = {
              options.dotfiles.health.observations = lib.mkOption {
                type = nixosSystems.${referenceHostName}.options.dotfiles.health.observations.type;
                default = { };
                internal = true;
              };
            };
            containerArgv = import ./platform/containers/impl/container-argv.nix {
              inherit lib hostConfig;
              execTokens = import ./checks/impl/exec-tokens.nix { inherit lib; };
            };
          };
          # gateway port を変えた第二の評価。artifact が宣言に追随することを示す
          variantConfig = artifactVariantConfig;
        } units;

      unitChecksPackage = "verification-unit-checks";
      closureChecksPackage = "verification-host-closures";
      verificationPrograms = import ./toolchain/verification/package.nix { pkgs = systemPkgs; };
      inherit (verificationPrograms) runWithin runEach;

      # agent wrapperが同じfileを読むためflake内の秒数の直書きは不可
      verificationBudget = builtins.fromJSON (builtins.readFile ./verification-budget.json);
      # dotfiles-verify-entryの受理範囲と割れるため別の上限は不可
      maxBudgetSeconds = 2147483647;
      # 宣言の欠落を既定値で補うと予算の根拠を失うため既定値は不可
      budgetSecondsFor =
        stage:
        let
          version = verificationBudget.version or null;
          seconds = verificationBudget.${stage}.seconds or null;
        in
        assert lib.assertMsg
          (
            version == 1
            && (builtins.isInt seconds || builtins.isFloat seconds)
            && seconds >= 1
            && seconds <= maxBudgetSeconds
            && seconds == builtins.floor seconds
          )
          "verification-budget.json must declare version 1 and an integral ${stage}.seconds from 1 to ${toString maxBudgetSeconds}";
        builtins.floor seconds;
      verifyBudgetSeconds = budgetSecondsFor "verify";
      pushBudgetSeconds = budgetSecondsFor "verify-push";

      # 単一評価器でのT1予算超過のため逐次実行は不採用
      t1Evaluators = 2;
      t1EvaluatorHeapBytes = 4 * 1024 * 1024 * 1024;
      # system評価の重複を避けるため共通systemを読む検査の別shard配置は不採用
      t1SystemChecks = builtins.attrNames closureChecks ++ [
        "nixos-system-negative-eval"
        # 変更で再buildする静的検査を先に始めるため評価の重いunitsへの配置は不採用
        "actionlint"
        "deadnix"
        "docs-constraint-coverage"
        "docs-links"
        "docs-path-labels"
        "docs-reader"
        "dotfiles-option-namespace"
        "nixfmt"
        "shellcheck"
        "statix"
        "unit-boundary-name-only"
      ];
      t1Shards = {
        systems = t1SystemChecks;
        units = builtins.filter (name: !(builtins.elem name t1SystemChecks)) (
          builtins.attrNames unitChecks
        );
      };
      t1ShardPackage = shard: "verification-t1-${shard}";
      t1ShardPackages = lib.mapAttrs' (
        shard: names:
        let
          pick = lib.filterAttrs (name: _: builtins.elem name names);
          unknown = builtins.filter (name: !(closureChecks ? ${name} || unitChecks ? ${name})) names;
        in
        lib.nameValuePair (t1ShardPackage shard) (
          assert lib.assertMsg (unknown == [ ]) "T1 shard ${shard} names no check: ${toString unknown}";
          builtins.deepSeq (lib.mapAttrs (_: check: check.drvPath) (pick closureChecks)) (
            systemPkgs.linkFarm (t1ShardPackage shard) (pick unitChecks)
          )
        )
      ) t1Shards;
      t1Installables = lib.concatMapStringsSep " " (shard: packageRef (t1ShardPackage shard)) (
        builtins.attrNames t1Shards
      );

      lockedSource = "path:${self}?narHash=${self.narHash}";
      sourceRef = lib.escapeShellArg lockedSource;
      packageRef = name: lib.escapeShellArg "${lockedSource}#packages.${system}.${name}";

      verificationTiers = {
        verify = {
          description = "T1: unit の検査と全 host の評価";
          # app の shell を残すと呼び出し側の signal で shell だけが先に終わり run-within の待機が見えなくなるため exec なしは不可
          commands = ''
            export GC_INITIAL_HEAP_SIZE="''${GC_INITIAL_HEAP_SIZE-${toString t1EvaluatorHeapBytes}}"
            exec ${lib.getExe runWithin} ${toString verifyBudgetSeconds} ${lib.getExe runEach} ${toString t1Evaluators} \
              nix build --no-link --no-write-lock-file -L -- \
              ${t1Installables}
          '';
        };
        verify-push = {
          description = "T2: unit の検査と全 host の closure";
          commands = ''
            exec ${lib.getExe runWithin} ${toString pushBudgetSeconds} \
              nix build --no-link --no-write-lock-file -L ${packageRef unitChecksPackage} ${packageRef closureChecksPackage}
          '';
        };
        verify-full = {
          description = "T3: flake の全量 check";
          commands = ''
            nix flake check --no-write-lock-file -L ${sourceRef}
          '';
        };
      };

      verificationApp = name: tier: {
        type = "app";
        program = lib.getExe (
          systemPkgs.writeShellApplication {
            name = "dotfiles-${name}";
            text = ''
              if [ "$#" -ne 0 ]; then
                echo "usage: dotfiles-${name}" >&2
                exit 64
              fi
              ${tier.commands}
            '';
          }
        );
        meta.description = tier.description;
      };
    in
    {
      nixosConfigurations = nixosSystems;

      packages.${system} =
        let
          hostConfig = machineConfigs.${referenceHostName};
          inherit (nixosSystems.${referenceHostName}) pkgs;
        in
        {
          inherit (pkgs) age sops;
          sourceSnapshot = pkgs.runCommand "dotfiles-source-snapshot" { } ''
            mkdir -p "$out"
            cp -R --preserve=mode ${self}/. "$out/"
            test -x "$out/workstation/activation/rebuild/impl/bootstrap.sh"
          '';
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-agents = hostConfig.dotfiles.platform.cli.commands.installAgents;
          dotfiles-doctor = hostConfig.dotfiles.platform.cli.commands.doctor;
          dotfiles-rebuild = hostConfig.dotfiles.platform.cli.commands.rebuild;
          # 配備済みのagent wrapperはcli.commandsに登録が無いためcli.commands経由は不可
          dotfiles-agent-verify = hostConfig.dotfiles.agents.packages.verification;
          ${unitChecksPackage} = builtins.deepSeq (lib.mapAttrs (_: check: check.drvPath) closureChecks) (
            pkgs.linkFarm unitChecksPackage unitChecks
          );
          ${closureChecksPackage} = pkgs.linkFarm closureChecksPackage closureChecks;
        }
        // t1ShardPackages;

      apps.${system} = lib.mapAttrs verificationApp verificationTiers;

      devShells.${system}.default = systemPkgs.mkShellNoCC {
        packages = machineConfigs.${referenceHostName}.dotfiles.toolchain.devShellPackages;
      };

      formatter.${system} = systemPkgs.nixfmt-tree;

      checks.${system} = closureChecks // unitChecks;
    };
}
