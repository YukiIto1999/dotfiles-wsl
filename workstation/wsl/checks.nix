{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  extraBin = hostConfig.wsl.extraBin;
  extraBinNames = map (entry: entry.name) extraBin;
  modelDrive = hostConfig.fileSystems."/mnt/g" or { };

  requiredBins = [
    "awk"
    "base64"
    "cat"
    "chmod"
    "cp"
    "find"
    "grep"
    "head"
    "mkdir"
    "mktemp"
    "mv"
    "readlink"
    "rm"
    "sed"
    "tr"
    "xargs"
  ];

  missingBins = lib.filter (name: !lib.elem name extraBinNames) requiredBins;
  storeEntries = lib.filter (entry: entry.src != "/init") extraBin;
in
{
  wsl-model-drive-contract =
    assert lib.assertMsg (
      modelDrive.device or null == "G:"
    ) "WSL model drive must use the Windows G: drive";
    assert lib.assertMsg (modelDrive.fsType or null == "drvfs") "WSL model drive must use drvfs";
    assert lib.assertMsg (
      lib.elem "nofail" (modelDrive.options or [ ])
      && lib.elem "x-systemd.automount" (modelDrive.options or [ ])
    ) "WSL model drive must be a non-blocking systemd automount";
    pkgs.runCommandLocal "check-wsl-model-drive-contract" { } ''
      touch $out
    '';

  wsl-extra-bin-contract =
    assert lib.assertMsg hostConfig.wsl.enable "WSL must be enabled";
    assert lib.assertMsg (
      missingBins == [ ]
    ) "missing required extraBin entries: ${lib.concatStringsSep " " missingBins}";
    assert lib.assertMsg (
      builtins.length extraBinNames == builtins.length (lib.unique extraBinNames)
    ) "extraBin names must be unique";
    pkgs.runCommandLocal "check-wsl-extra-bin-contract" { } ''
      set -euo pipefail
      ${lib.concatMapStrings (entry: ''
        test -n "${entry.name}"
        test -x "${entry.src}"
      '') storeEntries}
      touch $out
    '';
}
