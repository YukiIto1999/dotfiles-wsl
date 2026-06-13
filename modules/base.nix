{ config, pkgs, ... }:

let
  cfg = config.my;
in
{
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
}
