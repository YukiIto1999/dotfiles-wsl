{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../impl/mk-command.nix { inherit config lib pkgs; };
  names = builtins.attrNames cfg.agents.clients;

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

  roots = lib.unique (map (name: rootOf cfg.agents.clients.${name}.rulesDestination) names) ++ [
    ".config/git"
    ".config/gh"
  ];
in
{
  dotfiles.commands.cleanup = mkCommand {
    name = "dotfiles-cleanup";
    src = ./impl/cleanup.sh;
    runtimeInputs = [ pkgs.coreutils ];
    vars = {
      agentRootsBashArray = lib.concatStringsSep " " (map (r: "'${r}'") roots);
      hmBackupExt = config.home-manager.backupFileExtension;
    };
  };
}
