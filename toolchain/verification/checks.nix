{
  pkgs,
  lib,
  hostConfig,
  ...
}:

{
  verification-entry-resolution =
    pkgs.runCommandLocal "check-verification-entry-resolution"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          git
        ];
        ENTRY = lib.getExe hostConfig.dotfiles.toolchain.verification.entry;
      }
      ''
        export NIX_REMOTE="$PWD/nix-store"
        export NIX_CONFIG="experimental-features = nix-command flakes"
        bash ${./fixtures/entry.sh}
        touch $out
      '';
}
