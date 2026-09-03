{ config, ... }:

let
  cfg = config.dotfiles.workstation;
in
{
  # docker group は containers/module.nix が追加
  config.users.users.${cfg.username} = {
    isNormalUser = true;
    home = cfg.homeDir;
    extraGroups = [ "wheel" ];
  };

  config.home-manager.users.${cfg.username} = _: {
    home.username = cfg.username;
    home.homeDirectory = cfg.homeDir;
  };
}
