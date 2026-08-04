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

    # vendored な agent/skill source、flake = false で plain tree 扱い
    superpowers = {
      url = "github:obra/superpowers/v5.1.0";
      flake = false;
    };
    openaiPlugins = {
      url = "github:openai/plugins/ed8ce2eacc07964f0f556519e0737a420da14e00";
      flake = false;
    };
    claudePlugins = {
      url = "github:anthropics/claude-plugins-official/ae21a9367949f92df4e31231d7efe43eaa08207c";
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
      superpowers,
      openaiPlugins,
      claudePlugins,
      ...
    }:
    let
      system = "x86_64-linux";
      hostName = "nixos";

      pluginSources = {
        inherit superpowers;
        openai-plugins = openaiPlugins;
        claude-plugins-official = claudePlugins;
      };

      # unit の収集。module.nix / package.nix / checks.nix / impl のいずれかを持つ directory が unit
      collectUnits =
        root:
        let
          inherit (nixpkgs) lib;
          isUnit =
            path:
            let
              inner = builtins.readDir path;
            in
            (inner ? "module.nix")
            || (inner ? "package.nix")
            || (inner ? "checks.nix")
            || ((inner."impl" or null) == "directory");
          walk =
            prefix: path:
            let
              inner = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir path);
              children = lib.concatMap (name: walk "${prefix}${name}/" (path + "/${name}")) (
                builtins.attrNames inner
              );
            in
            (lib.optional (isUnit path) {
              id = lib.removeSuffix "/" prefix;
              inherit path;
            })
            ++ children;
          dirs = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir root);
        in
        lib.concatMap (name: walk "${name}/" (root + "/${name}")) (builtins.attrNames dirs);

      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      mkNixosSystem =
        machineModule:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit pluginSources; };
          modules = unitModules ++ [
            nixos-wsl.nixosModules.default
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager

            machineModule
          ];
        };

      maintenancePkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.${hostName} = mkNixosSystem {
        # マシン固有の値のみ、他は各 unit の option の default
        my = {
          accounts = [
            "account-1"
            "account-2"
            "account-3"
          ];
          git.workIdentity = "~/projects/business/";
        };
      };

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
            test -x "$out/rebuild/bootstrap/impl/bootstrap.sh"
          '';
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
          dotfiles-rebuild = hostConfig.my.commands.rebuild;
          dotfiles-sync-images = hostConfig.my.commands.syncImages;
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = self.nixosConfigurations.${hostName}.config.my.gates.devShellPackages;
      };

      formatter.${system} = maintenancePkgs.nixfmt-tree;

      checks.${system} =
        let
          # unit の収集。module.nix / package.nix / impl のいずれかを持つ directory が unit
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

          # port と accounts を変えた第二の評価。artifact が宣言に追随することを示す
          artifactVariantConfig =
            (mkNixosSystem {
              my = {
                accounts = [ ];
                gateway.endpoints.default.port = 9876;
              };
            }).config;

          checkSet = {
            nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;
          };
        in
        checkSet
        // mergeChecks {
          inherit
            pkgs
            lib
            self
            hostConfig
            sops-nix
            ;
          hostOptions = self.nixosConfigurations.${hostName}.options;
          inherit units;
          # checks が共有する eval 時 helper。unit の impl を path で直読みさせない
          helpers = {
            execTokens = import ./gates/impl/exec-tokens.nix { inherit lib; };
            containerArgv = import ./images/impl/container-argv.nix {
              inherit lib hostConfig;
              execTokens = import ./gates/impl/exec-tokens.nix { inherit lib; };
            };
          };
          # port と accounts を変えた第二の評価。artifact が宣言に追随することを示す
          variantConfig = artifactVariantConfig;
        } units;
    };
}
