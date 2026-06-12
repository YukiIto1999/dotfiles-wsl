{ pkgs, lib, osConfig, ... }:

let
  inherit (osConfig) my;
in
{
  imports = [
    ./cli.nix
    ./git.nix
  ];

  home.username      = my.username;
  home.homeDirectory = "/home/${my.username}";
  home.stateVersion  = "25.11";

  home.packages = with pkgs; [
    nodejs_24
    uv
    chromium
    ripgrep
    fd
    jq
    yq
    xh
    shellcheck
    shfmt
    just
    nixfmt
    nixd
    nvd
  ];

  home.sessionVariables.BROWSER = "wslview";
  home.sessionPath = [ "$HOME/.local/bin" ];

  programs = lib.genAttrs [ "gh" "bash" "fzf" "zoxide" "bat" "eza" ] (_: { enable = true; });
}
