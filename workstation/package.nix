{
  pkgs,
  lib,
  commandName,
  powershellProbe,
  powershellCommand,
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
  timeoutSeconds,
}:

let
  substitutions = {
    "@powershellCommand@" = lib.escapeShellArg powershellCommand;
    "@powershellProbe@" = lib.escapeShellArg powershellProbe;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@timeoutSeconds@" = toString timeoutSeconds;
  };
in
assert lib.assertMsg (
  builtins.match "[a-z0-9][a-z0-9-]*" commandName != null
) "Windows percentage observation command name is invalid";
(pkgs.writeShellApplication {
  name = commandName;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./impl/observe-windows-percent.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = commandName;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "numeric-command-threshold";
    };
  })
