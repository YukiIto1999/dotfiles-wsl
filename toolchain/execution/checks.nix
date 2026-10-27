{
  pkgs,
  lib,
  ...
}:
{
  source = [
    (
      let
        programs = import ./package.nix { inherit lib pkgs; };
        fakeNix = pkgs.writeShellScript "fake-nix-command" ''
          printf '%s\0' "$@" > "$ARG_CAPTURE"
        '';
        fixtureShims = programs.mkNixBuildShims {
          nixCommand = fakeNix;
          nixBuildCommand = fakeNix;
        };
        fixturePolicy = programs.mkPolicy { shims = fixtureShims; };
        # direnv status --json が答える承認状態を fixture が決める。
        fakeDirenv = pkgs.writeShellScript "fake-direnv" ''
          if [ "$#" -eq 2 ] && [ "$1" = status ] && [ "$2" = --json ]; then
            [ "''${FAKE_DIRENV_FAIL-}" != 1 ] || exit 1
            exec ${pkgs.coreutils}/bin/cat "$FAKE_DIRENV_JSON"
          fi
          exit 2
        '';
        # nix develop が --command の前に行う環境の書換え(TMP 系の新しい nix-shell directory と、devShell の PATH を
        # host の PATH の前に置くこと)を再現する。install の確認は実物の nix でしかできない。
        fakeNixDevelop = pkgs.writeShellScript "fake-nix-develop" ''
          printf '%s\0' "$@" > "$NIX_ARGV"
          [ "$1" = develop ] || exit 2
          if [ "''${FAKE_NIX_FAIL-}" = 1 ]; then
            echo 'error: flake evaluation failed' >&2
            exit 1
          fi
          shift
          while [ "$#" -gt 0 ] && [ "$1" != --command ]; do
            shift
          done
          shift
          shell_dir=$(${pkgs.coreutils}/bin/mktemp -d -p "$FAKE_SHELL_ROOT" nix-shell.XXXXXX)
          export NIX_BUILD_TOP=$shell_dir TMP=$shell_dir TMPDIR=$shell_dir TEMP=$shell_dir TEMPDIR=$shell_dir
          export PATH="$DEVSHELL_BIN:$PATH"
          exec "$@"
        '';
        boundedCgroupFile = pkgs.writeText "bounded-project-cgroup" "0::/user.slice/user-1000.slice/user@1000.service/agents.slice/client.scope\n";
        fixtureProjectRun = programs.mkProjectRun {
          nixCommand = fakeNixDevelop;
          direnvCommand = fakeDirenv;
          cgroupFile = boundedCgroupFile;
        };
        nativeProjectRun = programs.mkProjectRun {
          direnvCommand = fakeDirenv;
          cgroupFile = boundedCgroupFile;
        };
        unboundedProjectRun = programs.mkProjectRun {
          nixCommand = fakeNixDevelop;
          direnvCommand = fakeDirenv;
          cgroupFile = pkgs.writeText "unbounded-project-cgroup" "0::/init.scope\n";
          systemdRunCommand = pkgs.writeShellScript "unavailable-user-manager" "exit 69";
        };
      in
      {
        toolchain-execution-policy =
          pkgs.runCommandLocal "check-toolchain-execution-policy"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
              ];
              POLICY = lib.getExe fixturePolicy;
              SHIM_DIR = "${fixtureShims}";
            }
            ''
              bash ${./fixtures/policy.sh}
              touch $out
            '';

        toolchain-nix-build-shims =
          pkgs.runCommandLocal "check-toolchain-nix-build-shims"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
              ];
              SHIM_DIR = "${fixtureShims}";
            }
            ''
              bash ${./fixtures/nix-build-shims.sh}
              touch $out
            '';

        toolchain-project-run =
          pkgs.runCommandLocal "check-toolchain-project-run"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                jq
              ];
              PROJECT_RUN = lib.getExe fixtureProjectRun;
              UNBOUNDED_PROJECT_RUN = lib.getExe unboundedProjectRun;
            }
            ''
              bash ${./fixtures/project-run.sh}
              touch $out
            '';

        toolchain-project-run-native =
          pkgs.runCommandLocal "check-toolchain-project-run-native"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                jq
                nix
              ];
              PROJECT_RUN = lib.getExe nativeProjectRun;
              SYSTEM = pkgs.stdenv.hostPlatform.system;
            }
            ''
              bash ${./fixtures/project-run-native.sh}
              touch $out
            '';
      }
    )
  ];
}
