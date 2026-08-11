{
  pkgs,
  lib,
  drive,
  powershellCommand,
  timeoutCommand ? "${pkgs.coreutils}/bin/timeout",
  timeoutSeconds,
}:

let
  name = "dotfiles-observe-windows-drive";
  powershellProbe = ''$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}'"; if ($null -eq $drive -or $drive.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor(($drive.FreeSpace * 100) / $drive.Size))'';
  substitutions = {
    "@powershellCommand@" = lib.escapeShellArg powershellCommand;
    "@powershellProbe@" = lib.escapeShellArg powershellProbe;
    "@timeoutCommand@" = lib.escapeShellArg timeoutCommand;
    "@timeoutSeconds@" = toString timeoutSeconds;
  };
in
assert lib.assertMsg (
  builtins.match "[A-Z]:" drive != null
) "Windows drive must use an uppercase drive letter";
(pkgs.writeShellApplication {
  inherit name;
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./impl/observe-windows-drive.sh);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = name;
    };
    passthru = (old.passthru or { }) // {
      dotfilesObservationCommandKind = "numeric-command-threshold";
    };
  })
