{
  pkgs,
  lib,
  hostConfig,
  mkNixosSystem,
  normalMachineModule,
  ...
}:

let
  extraBin = hostConfig.wsl.extraBin;
  extraBinNames = map (entry: entry.name) extraBin;
  wsl = hostConfig.dotfiles.workstation.wsl;
  driveContractMatches =
    candidate:
    lib.all (
      drive:
      let
        mount = candidate.fileSystems."/mnt/${lib.toLower (lib.substring 0 1 drive)}";
      in
      mount.device == drive
      && mount.fsType == "drvfs"
      && lib.elem "nofail" mount.options
      && lib.elem "x-systemd.automount" mount.options
    ) candidate.dotfiles.workstation.wsl.extraDrives;
  portableConfig =
    (mkNixosSystem [
      normalMachineModule
      ({ lib, ... }: {
        dotfiles.workstation.wsl = {
          distroName = lib.mkForce "Development WSL";
          nameservers = lib.mkForce [ ];
          extraDrives = lib.mkForce [ ];
          windowsConfig = {
            memoryGiB = lib.mkForce 8;
            processors = lib.mkForce 2;
            swapGiB = lib.mkForce 2;
          };
        };
        dotfiles.workstation.storage.vhd.sizeGiB = lib.mkForce 128;
        dotfiles.workstation.nix = {
          maxJobs = lib.mkForce 1;
          cores = lib.mkForce 2;
          minimumFreeGiB = lib.mkForce 4;
          targetFreeGiB = lib.mkForce 8;
        };
      })
    ]).config;
  automaticConfig =
    (mkNixosSystem [
      normalMachineModule
      ({ lib, ... }: {
        dotfiles.workstation.wsl = {
          extraDrives = lib.mkForce [ "H:" ];
          windowsConfig = {
            memoryGiB = lib.mkForce null;
            processors = lib.mkForce null;
            swapGiB = lib.mkForce null;
          };
        };
        dotfiles.workstation.storage.vhd.sizeGiB = lib.mkForce 128;
      })
    ]).config;
  fakePowerShell = pkgs.writeShellScript "wslview-powershell" ''
    printf '%s\0' "$@" > "$WSLVIEW_CAPTURE"
    exit "''${WSLVIEW_WINDOWS_STATUS:-0}"
  '';
  fakeWslpath = pkgs.writeShellScript "wslview-wslpath" ''
    test "$#" -eq 2
    test "$1" = -w
    printf '%s' "$2" > "$WSLVIEW_PATH_CAPTURE"
    if test "''${WSLVIEW_PATH_STATUS:-0}" != 0; then
      exit "$WSLVIEW_PATH_STATUS"
    fi
    printf '%s\n' "''${WSLVIEW_WINDOWS_PATH:?}"
  '';
  launcher = import ./package.nix {
    inherit pkgs lib;
    powershellCommand = fakePowerShell;
    wslpathCommand = fakeWslpath;
  };
  workstationUsername = hostConfig.dotfiles.workstation.username;

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
  wsl-user-session-contract =
    assert lib.assertMsg (
      (hostConfig.users.users.${workstationUsername}.linger or null) == true
    ) "WSL default user must keep a persistent systemd user manager";
    assert lib.assertMsg (
      (hostConfig.users.users.root.linger or null) == true
    ) "WSL root user must keep a persistent systemd user manager";
    pkgs.runCommandLocal "check-wsl-user-session-contract" { } ''
      touch $out
    '';

  wsl-host-policy-contract =
    assert lib.assertMsg (driveContractMatches hostConfig)
      "declared Windows drives must be non-blocking automounts";
    assert lib.assertMsg (
      hostConfig.wsl.wslConf.network.generateResolvConf == (wsl.nameservers == [ ])
      && hostConfig.networking.nameservers == wsl.nameservers
    ) "WSL DNS must follow the host resolver selection";
    assert lib.assertMsg (
      portableConfig.dotfiles.workstation.wsl.distroName == "Development WSL"
      && portableConfig.wsl.defaultUser == workstationUsername
      && portableConfig.wsl.wslConf.network.generateResolvConf
      && portableConfig.networking.nameservers == [ ]
      && !(portableConfig.fileSystems ? "/mnt/g")
      && portableConfig.nix.settings.max-jobs == 1
      && portableConfig.nix.settings.cores == 2
      && portableConfig.nix.settings.min-free == 4 * 1073741824
      && portableConfig.nix.settings.max-free == 8 * 1073741824
      &&
        portableConfig.dotfiles.workstation.wsl.windowsConfigTemplate == ''
          [wsl2]
          defaultVhdSize=128GB
          memory=8GB
          processors=2
          swap=2GB

          [experimental]
          sparseVhd=false
        ''
    ) "small host resources, DNS, drives and distro name did not reach their owners";
    assert lib.assertMsg (
      driveContractMatches automaticConfig
      && !(automaticConfig.fileSystems ? "/mnt/g")
      && automaticConfig.fileSystems."/mnt/h".device == "H:"
      &&
        automaticConfig.dotfiles.workstation.wsl.windowsConfigTemplate == ''
          [wsl2]
          defaultVhdSize=128GB

          [experimental]
          sparseVhd=false
        ''
    ) "automatic Windows resource defaults or alternate drive mount were not preserved";
    pkgs.runCommandLocal "check-wsl-host-policy-contract" { } ''
      ${lib.getExe hostConfig.dotfiles.platform.cli.commands.wslConfig} > template
      cmp template ${pkgs.writeText "expected-wslconfig" wsl.windowsConfigTemplate}
      ${lib.getExe hostConfig.dotfiles.platform.cli.commands.wslConfig} --help > help
      test -s help
      status=0
      ${lib.getExe hostConfig.dotfiles.platform.cli.commands.wslConfig} unexpected > invalid 2>/dev/null || status=$?
      test "$status" -eq 2
      test ! -s invalid
      touch $out
    '';

  wslview-behavior =
    pkgs.runCommandLocal "check-wslview-behavior"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        export WSLVIEW_CAPTURE="$TMPDIR/powershell-args"
        export WSLVIEW_PATH_CAPTURE="$TMPDIR/wslpath-arg"
        export WSLVIEW_WINDOWS_PATH='C:\Users\Example\file with spaces.txt'
        export WSLVIEW_LAUNCHER=${lib.getExe launcher}
        python3 ${./impl/check-wslview.py}
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
