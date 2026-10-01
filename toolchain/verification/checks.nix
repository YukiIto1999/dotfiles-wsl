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
        bash ${./fixtures/entry.sh}
        touch $out
      '';
}
