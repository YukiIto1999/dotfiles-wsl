{ ... }:

{
  imports = [
    ./options.nix
    ./wsl.nix
    ./nix.nix
    ./fonts.nix
    ./mcp
    ./user
  ];

  system.stateVersion = "25.11";
}
