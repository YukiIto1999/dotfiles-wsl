{ config, pkgs, lib, osConfig, ... }:

let
  inherit (osConfig) my;
in
{
  imports = [
    ./cli.nix
    ./git.nix
  ];

  home.username      = my.username;
  home.homeDirectory = my.homeDir;
  home.stateVersion  = "25.11";

  # home module 間で共有する値
  _module.args = {
    dotfilesAbs = "${my.homeDir}/dotfiles-wsl";
    symlink     = config.lib.file.mkOutOfStoreSymlink;
  };

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
