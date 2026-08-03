{
  pkgs,
  self,
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
        bash ${self}/rebuild/bootstrap/fixtures/age-key-test.sh \
          ${self}/rebuild/bootstrap/impl/bootstrap.sh \
          ${fakeRebuild}
        touch $out
      '';
}
