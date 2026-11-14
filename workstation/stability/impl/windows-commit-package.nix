{
  pkgs,
  lib,
  reader,
  jqCommand ? lib.getExe pkgs.jq,
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
}:

let
  name = "dotfiles-observe-windows-memory-commit";
  substitutions = {
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@readerCommand@" = lib.escapeShellArg (lib.getExe reader);
    "@readerTimeoutSeconds@" = toString reader.dotfilesWindowsSnapshot.outerTimeout;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
  };
in
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-windows-commit.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "numeric-command-threshold";
    };
  })
