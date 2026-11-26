{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation;
in
{
  imports = [
    ./docker/module.nix
    ./doctor/module.nix
    ./fonts/module.nix
    ./home/module.nix
    ./locale/module.nix
    ./memory/module.nix
    ./nix/module.nix
    ./rebuild/module.nix
    ./storage/module.nix
    ./user/module.nix
    ./wsl/module.nix
  ];

  options.dotfiles.workstation = {
    username = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "この host の主 user。WSL の既定 user でもある。";
    };

    homeDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "主 user の home。username から導く。";
    };

    dotfilesDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.environmentDir}/dotfiles-wsl";
      description = "script と設定が実行時に読む checkout の絶対パス。";
    };

    environmentDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.homeDir}/environment";
      description = "dotfiles と一緒に手入れする環境系 repository を並べる directory の絶対パス。";
    };
  };

  config.dotfiles.workstation.homeDir = "/home/${cfg.username}";
  config.system.stateVersion = "25.11";
}
