{ lib, pkgs }:

let
  mkNixBuildShims =
    {
      nixCommand,
      nixBuildCommand,
    }:
    pkgs.symlinkJoin {
      name = "dotfiles-nix-build-shims";
      paths = [
        (pkgs.writeShellApplication {
          name = "nix";
          text = builtins.replaceStrings [ "@nixCommand@" ] [ (toString nixCommand) ] (
            builtins.readFile ./impl/nix.sh
          );
        })
        (pkgs.writeShellApplication {
          name = "nix-build";
          text = builtins.replaceStrings [ "@nixBuildCommand@" ] [ (toString nixBuildCommand) ] (
            builtins.readFile ./impl/nix-build.sh
          );
        })
      ];
    };
  nixBuildShims = mkNixBuildShims {
    nixCommand = lib.getExe pkgs.nix;
    nixBuildCommand = "${pkgs.nix}/bin/nix-build";
  };
  mkPolicy =
    { shims }:
    pkgs.writeShellApplication {
      name = "dotfiles-execution-policy";
      runtimeInputs = with pkgs; [
        coreutils
        taplo
      ];
      text = builtins.replaceStrings [ "@shimDirectory@" ] [ "${shims}/bin" ] (
        builtins.readFile ./impl/policy.sh
      );
    };
  mkProjectRun =
    {
      nixCommand ? lib.getExe pkgs.nix,
      direnvCommand ? lib.getExe pkgs.direnv,
      systemdRunCommand ? lib.getExe' pkgs.systemd "systemd-run",
      cgroupFile ? "/proc/self/cgroup",
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-project-run";
      runtimeInputs = with pkgs; [
        coreutils
        jq
      ];
      text =
        builtins.replaceStrings
          [ "@direnvCommand@" "@nixCommand@" "@envCommand@" "@systemdRunCommand@" "@cgroupFile@" ]
          [
            (lib.escapeShellArg (toString direnvCommand))
            (lib.escapeShellArg (toString nixCommand))
            (lib.escapeShellArg "${pkgs.coreutils}/bin/env")
            (lib.escapeShellArg (toString systemdRunCommand))
            (lib.escapeShellArg (toString cgroupFile))
          ]
          (builtins.readFile ./impl/project-run.sh);
    };
  # git は鍵の repository の根を求める実行 file。利用者の PATH を変えずに、環境によらず同じ根を得るため、固定した path で渡す
  mkWorkloadRun =
    {
      supervise,
      policy,
      gitCommand ? lib.getExe pkgs.git,
    }:
    pkgs.writeShellApplication {
      name = "dotfiles-workload-run";
      text = ''
        exec ${lib.getExe pkgs.python3} -I -S ${./impl/workload-run.py} \
          ${lib.escapeShellArg (toString supervise)} ${lib.escapeShellArg (toString policy)} \
          ${lib.escapeShellArg (toString gitCommand)} "$@"
      '';
    };
in
{
  inherit
    mkNixBuildShims
    mkPolicy
    mkProjectRun
    mkWorkloadRun
    nixBuildShims
    ;
  policy = mkPolicy { shims = nixBuildShims; };
  projectRun = mkProjectRun { };
}
