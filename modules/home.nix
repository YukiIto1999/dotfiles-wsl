{ config, pluginSources, ... }:

{
  home-manager.useGlobalPkgs       = true;
  home-manager.useUserPackages     = true;
  home-manager.backupFileExtension = "hm-back";
  home-manager.extraSpecialArgs    = { inherit pluginSources; };
  home-manager.users.${config.my.username} = import ../home;
}
