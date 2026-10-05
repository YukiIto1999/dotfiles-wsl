{
  pkgs,
  lib,
  hostOptions,
  machineConfigs,
  ...
}:

let
  machineNameType = hostOptions.dotfiles.agents.journal.machineName.type;
  machineNameOf = host: machineConfigs.${host}.dotfiles.agents.journal.machineName;
  acceptedMachineNames = [
    "y-itoh"
    "tcs-a295"
    "DESKTOP-1A2B3C"
  ];
  rejectedMachineNames = [
    ""
    "."
    ".."
    "../escape"
    "a/b"
    "y itoh"
    "y-itoh\r"
    "y-itoh\n"
    "\"quoted\""
  ];
in
{
  agent-journal-behavior =
    assert lib.assertMsg (lib.all machineNameType.check acceptedMachineNames)
      "journal machine names that are safe file names were rejected";
    assert lib.assertMsg (
      !lib.any machineNameType.check rejectedMachineNames
    ) "journal machine names that are not safe file names were accepted";
    assert lib.assertMsg (
      machineNameOf "nixos" == "y-itoh"
    ) "the nixos host must keep the machine name of its existing journal files";
    assert lib.assertMsg (
      machineNameOf "tcs-a295" == "tcs-a295"
    ) "a host without a declared machine name must use its host ID";
    pkgs.runCommandLocal "check-agent-journal-behavior"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
        python3 ${./checks/journal_test.py} ${./package}
        touch "$out"
      '';
}
