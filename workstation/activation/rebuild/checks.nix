{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:

      let
        wslRestartRequired = hostConfig.dotfiles.platform.cli.commands.wslRestartRequired;
        wslConfig = hostConfig.environment.etc."wsl.conf".source;
        failingCmp = pkgs.writeShellScript "cmp-always-fails" "exit 2";
        failingManifestCmp = pkgs.writeShellScript "cmp-manifest-fails" ''
          if [[ $3 == */init-interface-version ]]; then
            exec ${pkgs.coreutils}/bin/cmp "$@"
          fi
          exit 2
        '';
        fakeRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
          [[ ''${NIX_CONFIG:-} == *'experimental-features = nix-command flakes'* ]]
          printf '%q ' "$@" >> "$BOOTSTRAP_CALL_LOG"
          printf '\n' >> "$BOOTSTRAP_CALL_LOG"
        '';
        rebuildDependencies = pkgs.runCommand "rebuild-test-dependencies" { } ''
          mkdir -p "$out/bin"
          cp ${./fixtures/rebuild-dependency.sh} "$out/dependency"
          chmod u+w "$out/dependency"
          substituteInPlace "$out/dependency" --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'
          chmod +x "$out/dependency"
          for name in nix nix-env nvd sudo nixos-rebuild; do
            ln -s ../dependency "$out/bin/$name"
          done
        '';
        testRestartPlanner = pkgs.writeShellScript "test-restart-planner" ''
          exec "$REBUILD_RESTART_PLANNER" \
            --booted-system "$REBUILD_BOOTED_SYSTEM" \
            --current-system "$REBUILD_RUNNING_SYSTEM" "$@"
        '';
        testRebuildScript = pkgs.replaceVars ./impl/rebuild.sh {
          configuredDotfiles = ''"$REBUILD_CHECKOUT"'';
          hostName = "fixture-host";
          distroName = lib.escapeShellArg "Fixture Distro";
          systemProfilePath = "$REBUILD_SYSTEM_PROFILE";
          nixosRebuild = lib.escapeShellArg "${rebuildDependencies}/bin/nixos-rebuild";
          sudoCommand = lib.escapeShellArg "${rebuildDependencies}/bin/sudo";
          nvd = lib.escapeShellArg "${rebuildDependencies}/bin/nvd";
          wslRestartRequired = lib.escapeShellArg testRestartPlanner;
        };
        testRebuild = pkgs.writeShellApplication {
          name = "dotfiles-rebuild-test";
          runtimeInputs = with pkgs; [
            coreutils
            git
          ];
          text = ''exec ${pkgs.bash}/bin/bash -euo pipefail ${testRebuildScript} "$@"'';
        };
      in
      {
        wsl-restart-policy = pkgs.runCommandLocal "check-wsl-restart-policy" { } ''
          set -euo pipefail

          mkdir -p booted/etc bad-booted/etc current/etc candidate/etc missing/etc invalid/etc/wsl.conf fake-bin
          cp ${wslConfig} booted/etc/wsl.conf
          cp ${wslConfig} bad-booted/etc/wsl.conf
          cp ${wslConfig} candidate/etc/wsl.conf
          printf 'fixture-init-interface\n' > current/init-interface-version
          cp current/init-interface-version candidate/init-interface-version
          chmod u+w bad-booted/etc/wsl.conf candidate/etc/wsl.conf candidate/init-interface-version

          assert_plan() {
            expected=$1
            shift
            actual=$(${lib.getExe wslRestartRequired} --plan \
              --booted-system booted --current-system current "$@")
            test "$actual" = "$expected"
          }

          assert_invalid_candidate() {
            if ${lib.getExe wslRestartRequired} --plan \
              --booted-system booted --current-system current candidate 2>/dev/null; then
              echo "invalid candidate WSL user metadata was accepted" >&2
              exit 1
            else
              test "$?" -eq 2
            fi
            cp ${wslConfig} candidate/etc/wsl.conf
          }

          assert_plan switch candidate
          test "$(${lib.getExe wslRestartRequired} --default-user \
            --booted-system booted --current-system current candidate)" = ${lib.escapeShellArg hostConfig.dotfiles.workstation.username}
          if ${lib.getExe wslRestartRequired} --plan --default-user candidate 2>/dev/null; then
            echo "mutually exclusive output modes were accepted" >&2
            exit 1
          else
            test "$?" -eq 2
          fi

          printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
          assert_plan switch-restart candidate
          cp ${wslConfig} candidate/etc/wsl.conf

          printf 'incompatible\n' >> candidate/init-interface-version
          assert_plan boot-restart candidate

          printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
          assert_plan boot-two-stage candidate
          cp ${wslConfig} candidate/etc/wsl.conf
          cp current/init-interface-version candidate/init-interface-version

          sed -i '/^\[user\]$/,/^\[/ s/^default=.*/  default = other-user  /' \
            candidate/etc/wsl.conf
          assert_plan boot-two-stage candidate
          printf 'incompatible\n' >> candidate/init-interface-version
          assert_plan boot-two-stage candidate
          cp ${wslConfig} candidate/etc/wsl.conf
          cp current/init-interface-version candidate/init-interface-version

          sed -i '/^\[user\]$/,$d' candidate/etc/wsl.conf
          assert_invalid_candidate

          sed -i '/^\[user\]$/,/^\[/ s/^default=.*/default=/' candidate/etc/wsl.conf
          assert_invalid_candidate

          sed -i '/^default=/a default=duplicate-user' candidate/etc/wsl.conf
          assert_invalid_candidate

          sed -i '/^\[user\]$/,$d' bad-booted/etc/wsl.conf
          test "$(${lib.getExe wslRestartRequired} --plan \
            --booted-system bad-booted --current-system current candidate)" = boot-two-stage

          test "$(${lib.getExe wslRestartRequired} --plan \
            --booted-system missing --current-system current candidate)" = boot-two-stage
          test "$(${lib.getExe wslRestartRequired} --plan \
            --booted-system booted --current-system missing candidate)" = boot-two-stage

          if ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system current candidate; then
            echo "unchanged manifest was classified as restart-required" >&2
            exit 1
          else
            test "$?" -eq 1
          fi

          ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system missing candidate

          ln -s ${failingCmp} fake-bin/cmp
          if PATH="$PWD/fake-bin:$PATH" ${pkgs.bash}/bin/bash \
            ${./impl/wsl-restart-required.sh} \
            --quiet --booted-system booted --current-system current candidate 2>/dev/null; then
            echo "cmp I/O error was accepted" >&2
            exit 1
          else
            test "$?" -eq 2
          fi

          ln -sf ${failingManifestCmp} fake-bin/cmp
          if PATH="$PWD/fake-bin:$PATH" ${pkgs.bash}/bin/bash \
            ${./impl/wsl-restart-required.sh} \
            --quiet --booted-system booted --current-system current candidate 2>/dev/null; then
            echo "manifest cmp I/O error was accepted" >&2
            exit 1
          else
            test "$?" -eq 2
          fi

          printf 'incompatible\n' >> candidate/init-interface-version
          ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system current candidate
          cp current/init-interface-version candidate/init-interface-version

          printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
          ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system current candidate

          ${lib.getExe wslRestartRequired} --quiet \
            --booted-system missing --current-system current candidate

          if ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system current missing 2>/dev/null; then
            echo "missing candidate manifest was accepted" >&2
            exit 1
          else
            test "$?" -eq 2
          fi

          if ${lib.getExe wslRestartRequired} --quiet \
            --booted-system booted --current-system current invalid 2>/dev/null; then
            echo "invalid candidate manifest was accepted" >&2
            exit 1
          else
            test "$?" -eq 2
          fi

          touch $out
        '';

        rebuild-entrypoint =
          pkgs.runCommandLocal "check-rebuild-entrypoint"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                git
                gnugrep
              ];
            }
            ''
              bash ${./fixtures/rebuild-test.sh} \
                ${lib.getExe testRebuild} \
                ${rebuildDependencies} \
                ${lib.getExe wslRestartRequired}
              touch $out
            '';

        bootstrap-age-key =
          pkgs.runCommandLocal "check-bootstrap-age-key"
            {
              nativeBuildInputs = with pkgs; [
                age
                bash
                coreutils
                git
                gnugrep
                sops
              ];
            }
            ''
              bash ${./fixtures/age-key-test.sh} \
                ${./impl/bootstrap.sh} \
                ${fakeRebuild}
              touch $out
            '';
      }
    )
  ];
}
