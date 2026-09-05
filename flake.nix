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

    # OMP は Bun/Rust native addon を含むため、upstream の Nix package をそのまま使う。
    omp.url = "github:can1357/oh-my-pi";


    orca = {
      url = "github:stablyai/orca/637dc30a3211ec0667c55118a4d17edbee5cff80";
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
      omp,
      orca,
      ...
    }:
    let
      system = "x86_64-linux";
      hostName = "nixos";
      pluginSources = {
        orca = orca;
      };
      collectUnits = import ./checks/impl/collect-units.nix { inherit (nixpkgs) lib; };
      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      mkNixosSystem =
        machineModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit omp pluginSources self;
          };
          modules =
            unitModules
            ++ [
              nixos-wsl.nixosModules.default
              sops-nix.nixosModules.sops
              home-manager.nixosModules.home-manager
            ]
            ++ nixpkgs.lib.toList machineModules;
        };

      normalMachineModule = import ./profiles/workstation.nix;

      maintenancePkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.${hostName} = mkNixosSystem normalMachineModule;

      packages.${system} =
        let
          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
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
          dotfiles-sync-images = hostConfig.dotfiles.platform.cli.commands.syncImages;
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = self.nixosConfigurations.${hostName}.config.dotfiles.toolchain.devShellPackages;
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

          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
          inherit (pkgs) lib;

          # gateway port を変えた第二の評価。artifact が宣言に追随することを示す
          artifactVariantSystem = mkNixosSystem [
            normalMachineModule
            { dotfiles.platform.mcp.gateway.port = 9876; }
          ];
          artifactVariantConfig = artifactVariantSystem.config;

          checkSet = {
            nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;
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
            mkNixosSystem
            sops-nix
            ;
          inherit normalMachineModule;
          hostOptions = self.nixosConfigurations.${hostName}.options;
          inherit units;
          # checks が共有する eval 時 helper。unit の impl を path で直読みさせない
          helpers = {
            execTokens = import ./checks/impl/exec-tokens.nix { inherit lib; };
            mergeCheckParts = import ./checks/impl/merge-check-parts.nix { inherit lib; };
            unitOwnership = import ./checks/impl/unit-ownership.nix { inherit lib; };
            observationRegistryModule = {
              options.dotfiles.health.observations = lib.mkOption {
                type = self.nixosConfigurations.${hostName}.options.dotfiles.health.observations.type;
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
