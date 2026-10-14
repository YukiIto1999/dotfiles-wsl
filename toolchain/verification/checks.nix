{ pkgs, lib, ... }:

let
  programs = import ./package.nix { inherit pkgs; };
in
{
  source = [
    {
      verification-run-within =
        pkgs.runCommandLocal "check-verification-run-within"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
            ];
            WITHIN = lib.getExe programs.runWithin;
          }
          ''
            bash ${./fixtures/run-within.sh}
            touch $out
          '';
      verification-run-each =
        pkgs.runCommandLocal "check-verification-run-each"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gnugrep
            ];
            EACH = lib.getExe programs.runEach;
          }
          ''
            bash ${./fixtures/run-each.sh}
            touch $out
          '';
    }
  ];
  configuration = [
    (
      { hostConfig, ... }:
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
    )
  ];
}
