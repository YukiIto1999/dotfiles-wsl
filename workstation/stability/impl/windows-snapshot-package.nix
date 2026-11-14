{
  pkgs,
  lib,
  snapshotPath,
  maximumAgeSeconds,
  futureSkewSeconds,
  dateCommand ? "${pkgs.coreutils}/bin/date",
  headCommand ? "${pkgs.coreutils}/bin/head",
  jqCommand ? lib.getExe pkgs.jq,
  sleepCommand ? "${pkgs.coreutils}/bin/sleep",
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
}:

let
  name = "dotfiles-read-windows-snapshot";
  schemaVersion = 1;
  maximumBytes = 4096;
  readAttempts = 2;
  readTimeoutSeconds = 2;
  retryDelaySeconds = "0.1";
  killAfterSeconds = 1;
  outerTimeout = readAttempts * (readTimeoutSeconds + killAfterSeconds) + 2;
  substitutions = {
    "@dateCommand@" = lib.escapeShellArg dateCommand;
    "@futureSkewSeconds@" = toString futureSkewSeconds;
    "@headCommand@" = lib.escapeShellArg headCommand;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@killAfterSeconds@" = toString killAfterSeconds;
    "@maximumAgeSeconds@" = toString maximumAgeSeconds;
    "@maximumBytes@" = toString maximumBytes;
    "@readAttempts@" = toString readAttempts;
    "@readTimeoutSeconds@" = toString readTimeoutSeconds;
    "@retryDelaySeconds@" = retryDelaySeconds;
    "@schemaVersion@" = toString schemaVersion;
    "@sleepCommand@" = lib.escapeShellArg sleepCommand;
    "@snapshotPath@" = lib.escapeShellArg snapshotPath;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
  };
in
assert lib.assertMsg (lib.hasPrefix "/" snapshotPath)
  "Windows snapshot path must be an absolute Linux path";
assert lib.assertMsg (
  builtins.isInt maximumAgeSeconds && maximumAgeSeconds > 0
) "Windows snapshot maximum age must be a positive number of seconds";
assert lib.assertMsg (
  builtins.isInt futureSkewSeconds && futureSkewSeconds >= 0
) "Windows snapshot future skew must be a non-negative number of seconds";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./read-windows-snapshot.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesWindowsSnapshot = {
        inherit snapshotPath outerTimeout;
      };
    };
  })
