{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  wslRestartRequired = hostConfig.my.commands.wslRestartRequired;
  wslConfig = hostConfig.environment.etc."wsl.conf".source;
  failingCmp = pkgs.writeShellScript "cmp-always-fails" "exit 2";
  failingManifestCmp = pkgs.writeShellScript "cmp-manifest-fails" ''
    if [[ $3 == */init-interface-version ]]; then
      exec ${pkgs.coreutils}/bin/cmp "$@"
    fi
    exit 2
  '';
in
{
  wsl-restart-policy = pkgs.runCommandLocal "check-wsl-restart-policy" { } ''
    set -euo pipefail

    mkdir -p booted/etc bad-booted/etc current/etc candidate/etc missing/etc invalid/etc/wsl.conf fake-bin
    cp ${wslConfig} booted/etc/wsl.conf
    cp ${wslConfig} bad-booted/etc/wsl.conf
    cp ${wslConfig} candidate/etc/wsl.conf
    cp ${hostConfig.system.build.toplevel}/init-interface-version current/init-interface-version
    cp ${hostConfig.system.build.toplevel}/init-interface-version candidate/init-interface-version
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
      --booted-system booted --current-system current candidate)" = ${lib.escapeShellArg hostConfig.my.username}
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
      ${self}/rebuild/impl/wsl-restart-required.sh \
      --quiet --booted-system booted --current-system current candidate 2>/dev/null; then
      echo "cmp I/O error was accepted" >&2
      exit 1
    else
      test "$?" -eq 2
    fi

    ln -sf ${failingManifestCmp} fake-bin/cmp
    if PATH="$PWD/fake-bin:$PATH" ${pkgs.bash}/bin/bash \
      ${self}/rebuild/impl/wsl-restart-required.sh \
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

    test -r ${hostConfig.system.build.toplevel}/etc/wsl.conf
    test -r ${hostConfig.system.build.toplevel}/init-interface-version
    cmp --silent ${wslConfig} ${hostConfig.system.build.toplevel}/etc/wsl.conf
    touch $out
  '';

  rebuild-routing =
    pkgs.runCommandLocal "check-rebuild-routing"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.util-linux
        ];
      }
      ''
        bash ${self}/rebuild/tests/rebuild-routing.sh \
          ${self}/rebuild/impl/rebuild.sh \
          ${pkgs.bash}/bin/bash \
          ${lib.getExe pkgs.fakeroot} \
          ${self}/rebuild/impl/lib/atomic-file.sh \
          ${self}/rebuild/impl/lib/operation-lock.sh \
          ${self}/rebuild/impl/lib/rebuild-receipt.sh \
          ${self}/rebuild/impl/lib/rebuild-attempt.sh \
          ${toString hostConfig.my.contract.doctor.schemaVersion}
        touch $out
      '';

  rebuild-attempt =
    pkgs.runCommandLocal "check-rebuild-attempt"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        bash ${self}/rebuild/tests/rebuild-attempt.sh \
          ${self}/rebuild/impl/lib/rebuild-attempt.sh
        touch $out
      '';

  atomic-publication =
    pkgs.runCommandLocal "check-atomic-publication"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.util-linux
        ];
      }
      ''
        bash ${self}/rebuild/tests/atomic-publication.sh \
          ${self}/rebuild/impl/lib/atomic-file.sh \
          ${self}/rebuild/impl/lib/operation-lock.sh \
          ${hostConfig.my.contract.images.libraries.imageState} \
          full
        bash ${self}/rebuild/tests/atomic-publication.sh \
          ${self}/rebuild/impl/lib/atomic-file.sh \
          ${self}/rebuild/impl/lib/operation-lock.sh \
          ${hostConfig.my.contract.images.libraries.imageState} \
          interop \
          ${self}/rebuild/fixtures/legacy-operation-lock.sh \
          ${hostConfig.my.contract.images.libraries.legacyImageState}
        touch $out
      '';

  active-publication =
    pkgs.runCommandLocal "check-active-publication"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.jq
        ];
      }
      ''
        bash ${self}/rebuild/tests/active-publication.sh \
          ${self}/rebuild/impl/lib/atomic-file.sh \
          ${self}/rebuild/impl/lib/rebuild-receipt.sh \
          full
        touch $out
      '';

  preparation-parent-evidence =
    pkgs.runCommandLocal "check-preparation-parent-evidence"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        bash ${self}/rebuild/tests/preparation-parent-evidence.sh \
          ${self}/rebuild/impl/lib/rebuild-receipt.sh \
          full
        touch $out
      '';

  gc-root-observer =
    pkgs.runCommandLocal "check-gc-root-observer"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.jq
        ];
      }
      ''
        bash ${self}/rebuild/tests/gc-root-observer.sh \
          ${self}/rebuild/impl/lib/rebuild-receipt.sh \
          full
        touch $out
      '';

  rebuild-entrypoint =
    let
      systemPackageNames = map lib.getName hostConfig.environment.systemPackages;
      upstreamRebuild = lib.getExe hostConfig.system.build.nixos-rebuild;
      publicRebuild = "${hostConfig.system.path}/bin/nixos-rebuild";
    in
    assert !hostConfig.system.tools.nixos-rebuild.enable;
    assert !(lib.elem "nixos-rebuild-ng" systemPackageNames);
    pkgs.runCommandLocal "check-rebuild-entrypoint" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail
      test -x ${publicRebuild}
      test -x ${upstreamRebuild}
      test "$(readlink -f ${publicRebuild})" != ${upstreamRebuild}
      set +e
      ${publicRebuild} >stdout 2>stderr
      status=$?
      set -e
      test "$status" -eq 2
      test ! -s stdout
      grep -Fqx 'FATAL: direct nixos-rebuild bypasses the dotfiles rebuild transaction' stderr
      grep -Fqx \
        'Use dotfiles-rebuild for normal changes; use rebuild/bootstrap/impl/bootstrap.sh only for initial provisioning.' \
        stderr
      touch $out
    '';
}
