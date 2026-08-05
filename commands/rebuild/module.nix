{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkCommand = import ../impl/mk-command.nix { inherit config lib pkgs; };
  rebuildVars = {
    configuredDotfiles = lib.escapeShellArg config.dotfiles.host.dotfilesDir;
    hostName = config.networking.hostName;
    distroName = config.wsl.wslConf.user.default or "NixOS";
    nixosRebuild = lib.escapeShellArg (lib.getExe config.system.build.nixos-rebuild);
    sudoCommand = lib.escapeShellArg "${config.security.wrapperDir}/sudo";
    nvd = lib.escapeShellArg (lib.getExe pkgs.nvd);
    wslRestartRequired = lib.escapeShellArg (lib.getExe wslRestartRequired);
  };

  wslRestartRequired = mkCommand {
    name = "dotfiles-wsl-restart-required";
    src = ./impl/wsl-restart-required.sh;
    runtimeInputs = with pkgs; [ coreutils ];
    vars = {
      bootIdFile = "/proc/sys/kernel/random/boot_id";
      awk = lib.escapeShellArg (lib.getExe pkgs.gawk);
    };
  };

  rebuild = mkCommand {
    name = "dotfiles-rebuild";
    src = ./impl/rebuild.sh;
    runtimeInputs = with pkgs; [
      git
      coreutils
      nix
      nvd
    ];
    vars = rebuildVars;
  };

  # PATH 上の直接呼び出しは、汚れた working tree の混入と WSL 再起動判定の欠落を招く
  nixosRebuildGuard = pkgs.writeShellApplication {
    name = "nixos-rebuild";
    text = ''
      echo "FATAL: use dotfiles-rebuild; it checks the working tree and the WSL restart plan" >&2
      echo "Initial provisioning is rebuild/impl/bootstrap.sh" >&2
      exit 2
    '';
  };
in
{
  dotfiles.commands = {
    inherit rebuild wslRestartRequired;
  };

  system.tools.nixos-rebuild.enable = false;
  environment.systemPackages = [ nixosRebuildGuard ];
}
