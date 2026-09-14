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

    orca = {
      url = "github:stablyai/orca/637dc30a3211ec0667c55118a4d17edbee5cff80";
      flake = false;
    };

    architectureStandard = {
      url = "github:YukiIto1999/architecture-standard/07b348bf6aa45829c828484913df9924de424e87";
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
        architecture-standard = architectureStandard;
      };
      collectUnits = import ./checks/impl/collect-units.nix { inherit (nixpkgs) lib; };
      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      mkNixosSystem =
        machineModules:
        lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit pluginSources self;
          };
          modules =
            unitModules
            ++ [
              nixos-wsl.nixosModules.default
              sops-nix.nixosModules.sops
              home-manager.nixosModules.home-manager
            ]
            ++ lib.toList machineModules;
        };

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

      maintenancePkgs = nixpkgs.legacyPackages.${system};
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
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = machineConfigs.${referenceHostName}.dotfiles.toolchain.devShellPackages;
      };

      formatter.${system} = maintenancePkgs.nixfmt-tree;

      checks.${system} =
        let
          # 各 unit の checks.nix を集め、id の重複を拒否する
          mergeChecks =
            args: units:
            let
              files = builtins.filter builtins.pathExists (map (unit: unit.path + "/checks.nix") units);
              # 名前は attrset の spine だけで決まるので、値が allCheckNames を参照しても循環しない
              perUnit = map (file: import file (args // { inherit allCheckNames; })) files;
              names = lib.concatMap builtins.attrNames perUnit;
              allCheckNames = builtins.attrNames checkSet ++ names;
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

          # gateway port を変えた第二の評価。artifact が宣言に追随することを示す
          artifactVariantSystem = mkNixosSystem [
            normalMachineModule
            { dotfiles.platform.mcp.gateway.port = 9876; }
          ];
          artifactVariantConfig = artifactVariantSystem.config;

          hostToplevelChecks = lib.mapAttrs' (
            hostName: machine: lib.nameValuePair "${hostName}-toplevel" machine.config.system.build.toplevel
          ) nixosSystems;

          checkSet = hostToplevelChecks // {
            nixos-variant-toplevel = artifactVariantConfig.system.build.toplevel;
          };
        in
        checkSet
        // mergeChecks {
          inherit
            pkgs
            lib
            self
            hostConfig
            hostNames
            machineConfigs
            machineOptions
            mkNixosSystem
            pluginSources
            sops-nix
            ;
          inherit normalMachineModule;
          hostOptions = nixosSystems.${referenceHostName}.options;
          inherit units;
          # checks が共有する eval 時 helper。unit の impl を path で直読みさせない
          helpers = {
            execTokens = import ./checks/impl/exec-tokens.nix { inherit lib; };
            mergeCheckParts = import ./checks/impl/merge-check-parts.nix { inherit lib; };
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
    };
}
