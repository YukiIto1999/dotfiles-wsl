{
  description = "NixOS on WSL2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-25.11";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # vendored な agent/skill source、flake = false で plain tree 扱い
    superpowers   = { url = "github:obra/superpowers/v5.1.0"; flake = false; };
    openaiPlugins = { url = "github:openai/plugins/ed8ce2eacc07964f0f556519e0737a420da14e00"; flake = false; };
    claudePlugins = { url = "github:anthropics/claude-plugins-official/ae21a9367949f92df4e31231d7efe43eaa08207c"; flake = false; };
  };

  outputs = { self, nixpkgs, nixos-wsl, home-manager, sops-nix, superpowers, openaiPlugins, claudePlugins, ... }:
    let
      system   = "x86_64-linux";
      hostName = "nixos";

      pluginSources = {
        superpowers             = superpowers;
        openai-plugins          = openaiPlugins;
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
              accounts     = [ "account-1" "account-2" "account-3" ];
              workIdentity = "~/projects/business/";
            };
          }
        ];
      };

      packages.${system} =
        let
          pkgs = self.nixosConfigurations.${hostName}.pkgs;
        in
        {
          sops = pkgs.sops;
          ai-cli-install-tools = pkgs.buildEnv {
            name  = "ai-cli-install-tools";
            paths = with pkgs; [ curl jq gnutar gzip ];
          };
        };

      checks.${system} = {
        nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;
      };
    };
}
