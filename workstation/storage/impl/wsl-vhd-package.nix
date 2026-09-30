{
  pkgs,
  lib,
  sizeBytes,
  sparse,
  powershellCommand,
  timeoutSeconds,
  blockDevices ? "/sys/dev/block",
  jqCommand ? lib.getExe pkgs.jq,
  statCommand ? "${pkgs.coreutils}/bin/stat",
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
}:

let
  name = "dotfiles-observe-wsl-vhd";
  outcomeIds = {
    capacity = "resource/wsl-vhd/capacity";
    wslconfig = "resource/wsl-vhd/wslconfig";
  };
  contract = {
    envelopeVersion = 1;
    allowedOutcomeIds = builtins.attrValues outcomeIds;
    requiredOutcomeIds = builtins.attrValues outcomeIds;
    requiredResourceKeys = [ ];
    # PowerShell が期限を過ぎても容量の結果を返せるよう、observation の期限を長くとる
    outerTimeout = 2 * timeoutSeconds;
  };
  # doctor が probe に渡す環境には Windows の user profile の path がないため、PowerShell に
  # .wslconfig を読ませる。file がなければ空を返し、宣言した値の欠落として扱う
  powershellProbe = "$profileDirectory = $env:USERPROFILE; if (-not $profileDirectory) { exit 1 }; $path = Join-Path $profileDirectory '.wslconfig'; if ([IO.File]::Exists($path)) { [Console]::Out.Write([IO.File]::ReadAllText($path)) }";
  substitutions = {
    "@blockDevices@" = lib.escapeShellArg blockDevices;
    "@capacityOutcome@" = lib.escapeShellArg outcomeIds.capacity;
    "@envelopeVersion@" = toString contract.envelopeVersion;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@powershellCommand@" = lib.escapeShellArg powershellCommand;
    "@powershellProbe@" = lib.escapeShellArg powershellProbe;
    "@sizeBytes@" = toString sizeBytes;
    "@sparse@" = lib.boolToString sparse;
    "@statCommand@" = lib.escapeShellArg statCommand;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@timeoutSeconds@" = toString timeoutSeconds;
    "@wslconfigOutcome@" = lib.escapeShellArg outcomeIds.wslconfig;
  };
in
assert lib.assertMsg (
  builtins.isInt sizeBytes && sizeBytes > 0
) "WSL VHD size must be a positive byte count";
assert lib.assertMsg (builtins.isBool sparse) "WSL VHD sparse setting must be a boolean";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./observe-wsl-vhd.sh);
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
