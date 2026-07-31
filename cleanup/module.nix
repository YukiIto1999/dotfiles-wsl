{
  config,
  lib,
  pkgs,
  mkCommand,
  ...
}:

let
  cfg = config.my;
  names = builtins.attrNames cfg.clis;

  # hm-back を掃く root。.config/<x> は 2 段まで、それ以外は先頭 1 段
  rootOf =
    path:
    let
      segs = lib.splitString "/" path;
    in
    if builtins.head segs == ".config" then
      lib.concatStringsSep "/" (lib.sublist 0 2 segs)
    else
      builtins.head segs;

  roots = lib.unique (map (name: rootOf cfg.clis.${name}.rulesFile) names) ++ [
    ".config/git"
    ".config/gh"
  ];
in
{
  my.commands.cleanup = mkCommand {
    name = "dotfiles-cleanup";
    src = ./impl/cleanup.sh;
    runtimeInputs = [ pkgs.coreutils ];
    vars = {
      cliRootsBashArray = lib.concatStringsSep " " (map (r: "'${r}'") roots);
      hmBackupExt = config.home-manager.backupFileExtension;
    };
  };
}
