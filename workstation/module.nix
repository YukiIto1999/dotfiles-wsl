{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation;
in
{
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
      default = "${cfg.homeDir}/dotfiles-wsl";
      description = "out-of-store symlink と script が参照する checkout の絶対パス。";
    };

    binaryCaches = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            substituter = lib.mkOption { type = lib.types.str; };
            publicKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      readOnly = true;
      internal = true;
      description = "Nix が利用する binary cache の型付き contract。";
    };
  };

  config.dotfiles.workstation.homeDir = "/home/${cfg.username}";
}
