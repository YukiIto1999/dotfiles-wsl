{
  description = "NixOS on WSL2";

  inputs = {
    # NixOS
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # NixOS-WSL
    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-25.11";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    # Home-Manager
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Sops-Nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-wsl, home-manager, sops-nix, ... }:
    let
      # User
      username = "nixos";
      system   = "x86_64-linux";

      # Pkgs
      pkgs = import nixpkgs { inherit system; };

      # Gateway
      gatewayPort = "8765";
      gatewayUrl  = "http://localhost:${gatewayPort}/mcp";

      # Accounts
      accounts = [ "account-1" "account-2" "account-3" ];

      # Identity
      workIdentity = "~/projects/business/";

      # Plugins
      pluginSources = {
        superpowers             = ./upstream/superpowers;
        openai-plugins          = ./upstream/openai-plugins;
        claude-plugins-official = ./upstream/claude-plugins-official;
      };
    in {
      # System
      nixosConfigurations.${username} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit username gatewayPort accounts workIdentity; };
        modules = [
          ./etc/nixos/configuration.nix

          nixos-wsl.nixosModules.default
          sops-nix.nixosModules.sops

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs        = true;
            home-manager.useUserPackages      = true;
            home-manager.users.${username}    = import ./etc/nixos/home.nix;
            home-manager.backupFileExtension  = "hm-back";
            home-manager.extraSpecialArgs     = { inherit username pluginSources gatewayUrl workIdentity; };
          }
        ];
      };

      # Packages
      packages.${system} = {
        sops = pkgs.sops;
        ai-cli-install-tools = pkgs.buildEnv {
          name = "ai-cli-install-tools";
          paths = with pkgs; [ curl jq gnutar gzip ];
        };
      };

      # Checks
      checks.${system} = {
        nixos-toplevel = self.nixosConfigurations.${username}.config.system.build.toplevel;
      };
    };
}
