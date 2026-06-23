{ config, pkgs, lib, pluginSources, ... }:

let
  cfg = config.my;
in
{
  imports = [ ./git ];

  # docker group は modules/mcp/backends.nix が追加
  users.users.${cfg.username} = {
    isNormalUser = true;
    home = cfg.homeDir;
    extraGroups = [ "wheel" ];
  };

  environment.systemPackages = with pkgs; [
    wget
    curl
    vim
    direnv
    nix-direnv
    devenv
    sops
    age
  ];

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  home-manager.useGlobalPkgs       = true;
  home-manager.useUserPackages     = true;
  home-manager.backupFileExtension = "hm-back";
  home-manager.extraSpecialArgs    = { inherit pluginSources; };

  home-manager.users.${cfg.username} = { ... }: {
    home.username      = cfg.username;
    home.homeDirectory = cfg.homeDir;
    home.stateVersion  = "25.11";

    home.packages = with pkgs; [
      nodejs_24
      uv
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
  };
}
