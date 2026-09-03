{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  homeDir = cfg.workstation.homeDir;
  backupExtension = config.home-manager.backupFileExtension;
  backupCommand = config.home-manager.backupCommand;
  usesBackupExtension = backupCommand == null && backupExtension != null;
  homeConfig = config.home-manager.users.${cfg.workstation.username};
  currentHomeFiles = "${homeConfig.home.activationPackage}/home-files";
in
{
  dotfiles.platform.cli.commands.cleanup = mkCommand {
    name = "dotfiles-cleanup";
    src = ./impl/cleanup.sh;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
    ];
    vars = {
      currentBackupExtension = lib.escapeShellArg (if usesBackupExtension then backupExtension else "");
      currentHomeFiles = lib.escapeShellArg currentHomeFiles;
      currentUsesBackupExtension = if usesBackupExtension then "1" else "0";
      homeDir = lib.escapeShellArg homeDir;
      systemRoot = "/etc";
    };
    extra.passthru = {
      cleanupHomeDir = homeDir;
      cleanupCurrentHomeFiles = currentHomeFiles;
      cleanupCurrentUsesBackupExtension = usesBackupExtension;
    };
  };

  assertions = [
    {
      assertion =
        !usesBackupExtension || builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" backupExtension != null;
      message = "Home Manager backupFileExtension must be a filename suffix when cleanup uses it.";
    }
  ];
}
