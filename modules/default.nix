{ ... }:

{
  imports = [
    ./options.nix
    ./wsl.nix
    ./nix.nix
    ./base.nix
    ./secrets.nix
    ./mcp
    ./home.nix
  ];

  system.stateVersion = "25.11";
}
