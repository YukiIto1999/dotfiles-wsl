{ ... }:

{
  imports = [
    ./options.nix
    ./wsl.nix
    ./nix.nix
    ./fonts.nix
    ./secrets.nix
    ./mcp
    ./clis
    ./user
    ./commands.nix
  ];

  system.stateVersion = "25.11";
}
