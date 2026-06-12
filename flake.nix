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
  };

  outputs = { self, nixpkgs, nixos-wsl, home-manager, sops-nix, ... }:
    let
      system   = "x86_64-linux";
      hostName = "nixos";

      pluginSources = {
        superpowers             = ./upstream/superpowers;
        openai-plugins          = ./upstream/openai-plugins;
        claude-plugins-official = ./upstream/claude-plugins-official;
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
