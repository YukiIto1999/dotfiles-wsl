{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkCommand = import ../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  childGraceSeconds = "10";
  rebuildVars = {
    configuredDotfiles = lib.escapeShellArg config.dotfiles.workstation.dotfilesDir;
    hostName = lib.escapeShellArg config.networking.hostName;
    distroName = lib.escapeShellArg config.dotfiles.workstation.wsl.distroName;
    nixosRebuild = lib.escapeShellArg (lib.getExe config.system.build.nixos-rebuild);
    sudoCommand = lib.escapeShellArg "${config.security.wrapperDir}/sudo";
    nvd = lib.escapeShellArg (lib.getExe pkgs.nvd);
    wslRestartRequired = lib.escapeShellArg (lib.getExe wslRestartRequired);
    verificationEntry = lib.escapeShellArg (lib.getExe config.dotfiles.toolchain.verification.entry);
    agentVerify = lib.escapeShellArg (lib.getExe config.dotfiles.agents.packages.verification);
    supervise = lib.escapeShellArg (lib.getExe config.dotfiles.platform.supervise.package);
    # clientごとの配備先は別のstateであり、rollbackは戻さない。実際に指す先を報告するため選択済みの契約を渡す
    clientExecutables = lib.escapeShellArg (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (id: path: "${id}\t${path}") config.dotfiles.agents.clientExecutables
      )
    );
    inherit childGraceSeconds;
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
      diffutils
      jq
      nix
      nvd
      util-linux
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
  dotfiles.platform.cli.commands = {
    inherit rebuild wslRestartRequired;
  };

  system.tools.nixos-rebuild.enable = false;
  environment.systemPackages = [ nixosRebuildGuard ];
}
