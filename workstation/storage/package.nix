{
  pkgs,
  lib,
  dfCommand ? "${pkgs.coreutils}/bin/df",
}:

let
  name = "dotfiles-observe-windows-drives";
in
(pkgs.writeShellApplication {
  inherit name;
  text = builtins.replaceStrings [ "@dfCommand@" ] [ (lib.escapeShellArg dfCommand) ] (
    builtins.readFile ./impl/observe-windows-drives.sh
  );
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "numeric-command-threshold-set";
    };
  })
