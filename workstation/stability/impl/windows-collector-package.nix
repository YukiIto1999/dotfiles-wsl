{
  pkgs,
  lib,
  reader,
  powershellCommand,
  intervalSeconds,
  taskName ? "dotfiles-windows-resource-collector",
  operationTimeoutSeconds ? 60,
  publishWaitSeconds ? 30,
  retrySeconds ? 1,
  jqCommand ? lib.getExe pkgs.jq,
  sleepCommand ? "${pkgs.coreutils}/bin/sleep",
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
  wslpathCommand ? "/bin/wslpath",
}:

let
  name = "dotfiles-windows-resource-collector";
  # PowerShell 5.1 が BOM のない file を ANSI として読むため非 ASCII 文字を含む script は不可
  collectorSource = pkgs.writeText "windows-memory-collector.ps1" (
    builtins.readFile ./windows-memory-collector.ps1
  );
  manageScript = pkgs.writeText "windows-collector-manage.ps1" (
    builtins.readFile ./windows-collector-manage.ps1
  );
  expectedSha256 = builtins.hashFile "sha256" ./windows-memory-collector.ps1;
  snapshotDirectory = dirOf reader.dotfilesWindowsSnapshot.snapshotPath;
  snapshotName = baseNameOf reader.dotfilesWindowsSnapshot.snapshotPath;
  driveParts = builtins.match "/mnt/([a-z])(/.+)" snapshotDirectory;
  windowsDirectory = "${lib.toUpper (builtins.head driveParts)}:${
    builtins.replaceStrings [ "/" ] [ "\\" ] (builtins.elemAt driveParts 1)
  }";
  substitutions = {
    "@collectorSource@" = lib.escapeShellArg (toString collectorSource);
    "@expectedSha256@" = lib.escapeShellArg expectedSha256;
    "@intervalSeconds@" = toString intervalSeconds;
    "@jqCommand@" = lib.escapeShellArg jqCommand;
    "@manageScript@" = lib.escapeShellArg (toString manageScript);
    "@operationTimeoutSeconds@" = toString operationTimeoutSeconds;
    "@powershellCommand@" = lib.escapeShellArg powershellCommand;
    "@publishWaitSeconds@" = toString publishWaitSeconds;
    "@readerCommand@" = lib.escapeShellArg (lib.getExe reader);
    "@readerTimeoutSeconds@" = toString reader.dotfilesWindowsSnapshot.outerTimeout;
    "@retrySeconds@" = toString retrySeconds;
    "@snapshotName@" = lib.escapeShellArg snapshotName;
    "@sleepCommand@" = lib.escapeShellArg sleepCommand;
    "@taskName@" = lib.escapeShellArg taskName;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@windowsDirectory@" = lib.escapeShellArg windowsDirectory;
    "@wslpathCommand@" = lib.escapeShellArg wslpathCommand;
  };
in
assert lib.assertMsg (
  driveParts != null
) "the Windows snapshot directory must be /mnt/<drive>/<path>: ${snapshotDirectory}";
assert lib.assertMsg (
  builtins.match "[A-Za-z0-9][A-Za-z0-9-]*" taskName != null
) "the collector task name must be a plain token";
assert lib.assertMsg (
  builtins.isInt intervalSeconds && intervalSeconds >= 1 && intervalSeconds <= 3600
) "the collector interval must be from 1 to 3600 seconds";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./windows-collector-cli.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesWindowsCollector = {
        inherit collectorSource manageScript;
      };
    };
  })
