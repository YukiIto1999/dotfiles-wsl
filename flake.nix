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

      collectUnits = import ./gates/impl/collect-units.nix { inherit (nixpkgs) lib; };
      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      mkNixosSystem =
        machineModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit pluginSources self; };
          modules =
            unitModules
            ++ [
              nixos-wsl.nixosModules.default
              sops-nix.nixosModules.sops
              home-manager.nixosModules.home-manager
            ]
            ++ nixpkgs.lib.toList machineModules;
        };

      normalMachineModule = {
        dotfiles = {
          accounts = [
            "account-1"
            "account-2"
            "account-3"
          ];
          host = { };
          toolchain = {
            enabledLsp = [
              "bash"
              "csharp"
              "java"
              "nix"
              "python"
              "rust"
              "typescript"
            ];
            git.workIdentity = "~/projects/business/";
          };
          agents.enabled = [
            "antigravity"
            "claude"
            "codex"
            "opencode"
          ];
          containers.enabled = [
            "agentmemory"
            "crawl4ai"
            "searxng"
            "sonarqube"
          ];
          mcp.enabledProviders = [
            "chrome-devtools"
            "codex"
            "context7"
            "crawl4ai"
            "github"
            "memory"
            "playwright"
            "searxng"
            "sonarqube"
          ];
        };
      };

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
            test -x "$out/commands/rebuild/impl/bootstrap.sh"
          '';
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-agents = hostConfig.dotfiles.commands.installAgents;
          dotfiles-rebuild = hostConfig.dotfiles.commands.rebuild;
          dotfiles-sync-images = hostConfig.dotfiles.commands.syncImages;
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = self.nixosConfigurations.${hostName}.config.dotfiles.gates.devShellPackages;
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
          artifactVariantSystem = mkNixosSystem {
            dotfiles = {
              accounts = [
                "account-1"
                "account-2"
                "account-3"
              ];
              host = { };
              toolchain.enabledLsp = [
                "bash"
                "csharp"
                "java"
                "nix"
                "python"
                "rust"
                "typescript"
              ];
              agents.enabled = [
                "antigravity"
                "claude"
                "codex"
                "opencode"
              ];
              containers.enabled = [
                "agentmemory"
                "crawl4ai"
                "searxng"
                "sonarqube"
              ];
              mcp = {
                enabledProviders = [
                  "chrome-devtools"
                  "codex"
                  "context7"
                  "crawl4ai"
                  "github"
                  "memory"
                  "playwright"
                  "searxng"
                  "sonarqube"
                ];
                gateway.port = 9876;
              };
            };
          };
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
            execTokens = import ./gates/impl/exec-tokens.nix { inherit lib; };
            unitOwnership = import ./gates/impl/unit-ownership.nix { inherit lib; };
            containerArgv = import ./containers/impl/container-argv.nix {
              inherit lib hostConfig;
              execTokens = import ./gates/impl/exec-tokens.nix { inherit lib; };
            };
          };
          # gateway port を変えた第二の評価。artifact が宣言に追随することを示す
          variantConfig = artifactVariantConfig;
        } units;
    };
}
