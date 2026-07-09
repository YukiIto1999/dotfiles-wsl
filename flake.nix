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
    in
    {
      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pluginSources; };
        modules = [
          ./modules

          nixos-wsl.nixosModules.default
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager

          # マシン固有の値のみ、他は modules/options.nix の default
          {
            my = {
              accounts = [
                "account-1"
                "account-2"
                "account-3"
              ];
              workIdentity = "~/projects/business/";
            };
          }
        ];
      };

      packages.${system} =
        let
          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
        in
        {
          inherit (pkgs) sops;
          # bootstrap が最初の rebuild 前、system closure が無い状態から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
        };

      checks.${system} =
        let
          inherit (self.nixosConfigurations.${hostName}) pkgs;
          inherit (pkgs) lib;

          # config-syntax check 専用の @var@ 埋め、実際の値は各 module 側にありここでは構文検査用
          dummyVars = {
            gatewayUrl = "http://127.0.0.1:1/mcp";
            codexModel = "dummy-model";
            httpPort = "1";
            streamPort = "2";
            searxngSecret = "dummy";
            searxngPort = "3";
            valkeyPort = "4";
          };

          jsonConfigs = [
            ./modules/clis/claude/managed-settings.json
            ./modules/clis/claude/settings.json
            (pkgs.replaceVars ./modules/clis/claude/managed-mcp.json {
              inherit (dummyVars) gatewayUrl;
            })
            (pkgs.replaceVars ./modules/clis/antigravity/mcp_config.json {
              inherit (dummyVars) gatewayUrl;
            })
            (pkgs.replaceVars ./modules/clis/opencode/opencode.json { inherit (dummyVars) gatewayUrl; })
          ];

          tomlConfigs = [
            (pkgs.replaceVars ./modules/clis/codex/config-system.toml {
              inherit (dummyVars) gatewayUrl;
            })
            (pkgs.replaceVars ./modules/clis/codex/config.toml { inherit (dummyVars) codexModel; })
          ];

          yamlConfigs = [
            (pkgs.replaceVars ./modules/mcp/servers/agentmemory.yaml {
              inherit (dummyVars) httpPort streamPort;
            })
            (pkgs.replaceVars ./modules/mcp/servers/searxng-settings.yml {
              inherit (dummyVars) searxngSecret searxngPort valkeyPort;
            })
          ];

          asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;
        in
        {
          nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;

          deadnix = pkgs.runCommandLocal "check-deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
            deadnix --fail ${self}
            touch $out
          '';

          shellcheck = pkgs.runCommandLocal "check-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck --severity=warning ${self}/scripts/*.sh ${self}/modules/user/git/hooks/*
            touch $out
          '';

          statix = pkgs.runCommandLocal "check-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
            statix check --config ${self} ${self}
            touch $out
          '';

          nixfmt = pkgs.runCommandLocal "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';

          # 配備対象 config の構文検査、@var@ 込みの template は dummy 値を焼き込んだ derivation を対象にする
          config-syntax =
            pkgs.runCommandLocal "check-config-syntax"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.taplo
                  pkgs.yq
                ];
              }
              ''
                for f in ${asArgs jsonConfigs}; do
                  jq empty "$f"
                done
                for f in ${asArgs tomlConfigs}; do
                  taplo lint "$f"
                done
                for f in ${asArgs yamlConfigs}; do
                  yq . "$f" > /dev/null
                done
                touch $out
              '';
        };
    };
}
