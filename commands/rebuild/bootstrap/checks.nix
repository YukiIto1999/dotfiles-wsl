{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  # bootstrap は generation が無い時点で走るので、rebuild を差し替えて呼び出しを記録する
  fakeRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    printf '%q ' "$@" >> "$BOOTSTRAP_CALL_LOG"
    printf '\n' >> "$BOOTSTRAP_CALL_LOG"
    if [[ -n ''${BOOTSTRAP_REBUILD_READY:-} ]]; then
      : > "$BOOTSTRAP_REBUILD_READY"
      while [[ ! -e $BOOTSTRAP_REBUILD_RELEASE ]]; do
        sleep 0.01
      done
    fi
  '';
in
{
  bootstrap-age-key =
    pkgs.runCommandLocal "check-bootstrap-age-key"
      {
        nativeBuildInputs = with pkgs; [
          age
          bash
          coreutils
          diffutils
          git
          gnugrep
          gnused
          sops
          util-linux
        ];
      }
      ''
        # bootstrap は generation が無い時点で走るので config を読めず、鍵 path を
        # literal で持つ。二つの転記がずれると鍵を別の場所へ置く
        grep -Fq ${lib.escapeShellArg hostConfig.sops.age.keyFile} ${./impl/bootstrap.sh}

        bash ${./fixtures/age-key-test.sh} \
          ${./impl/bootstrap.sh} \
          ${fakeRebuild}
        touch $out
      '';
}
