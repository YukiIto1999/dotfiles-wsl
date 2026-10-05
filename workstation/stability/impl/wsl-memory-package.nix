{
  pkgs,
  lib,
  journalTimeoutSeconds,
  pressureWarning,
  pressureFailure,
  relayMinimumAgeSeconds,
  awkCommand ? lib.getExe pkgs.gawk,
  buddyinfo ? "/proc/buddyinfo",
  jqCommand ? lib.getExe pkgs.jq,
  journalctlCommand ? "${pkgs.systemd}/bin/journalctl",
  pressureRoot ? "/proc/pressure",
  psCommand ? "${pkgs.procps}/bin/ps",
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
  zoneinfo ? "/proc/zoneinfo",
}:

let
  name = "dotfiles-observe-wsl-memory";
  vmbusRingOrder = 7;
  pageblockOrder = 9;
  outcomeIds = {
    vmbus = "resource/wsl-memory/vmbus-ring-failures";
    relay = "resource/wsl-memory/stuck-relays";
    highOrder = "resource/wsl-memory/high-order-pages";
    memoryPressure = "resource/wsl-memory/memory-pressure";
    ioPressure = "resource/wsl-memory/io-pressure";
  };
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = builtins.attrValues outcomeIds;
    requiredOutcomeIds = builtins.attrValues outcomeIds;
    requiredResourceKeys = [ "wslMemory" ];
    # kernel log の走査の期限切れでも他の観測を返すため走査と同じ期限の observation は不可
    outerTimeout = journalTimeoutSeconds + 10;
  };
  substitutions = {
    "@awkCommand@" = lib.escapeShellArg awkCommand;
    "@buddyinfo@" = lib.escapeShellArg buddyinfo;
    "@envelopeVersion@" = toString contract.envelopeVersion;
    "@highOrderOutcome@" = lib.escapeShellArg outcomeIds.highOrder;
    "@ioPressureOutcome@" = lib.escapeShellArg outcomeIds.ioPressure;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@journalTimeoutSeconds@" = toString journalTimeoutSeconds;
    "@journalctlCommand@" = lib.escapeShellArg journalctlCommand;
    "@memoryPressureOutcome@" = lib.escapeShellArg outcomeIds.memoryPressure;
    "@pageblockOrder@" = toString pageblockOrder;
    "@pressureFailure@" = toString pressureFailure;
    "@pressureRoot@" = lib.escapeShellArg pressureRoot;
    "@pressureWarning@" = toString pressureWarning;
    "@psCommand@" = lib.escapeShellArg psCommand;
    "@relayMinimumAgeSeconds@" = toString relayMinimumAgeSeconds;
    "@relayOutcome@" = lib.escapeShellArg outcomeIds.relay;
    "@ringOrder@" = toString vmbusRingOrder;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@vmbusOutcome@" = lib.escapeShellArg outcomeIds.vmbus;
    "@zoneinfo@" = lib.escapeShellArg zoneinfo;
  };
in
assert lib.assertMsg (
  pressureWarning < pressureFailure
) "PSI warning threshold must be below failure";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-wsl-memory.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "normalized-protocol";
      dotfilesObservationContract = contract;
    };
  })
