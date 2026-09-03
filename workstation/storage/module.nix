{
  pkgs,
  lib,
  ...
}:

let
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  maximumJournalGiB = 4;
  rootFilesystem = {
    path = "/";
    metric = "used-percent";
    warning = 85;
    failure = 95;
  };
  powershellCommand = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
  windowsDrives = {
    c = {
      letter = "C:";
      resourceKey = "windowsCDrive";
    };
    d = {
      letter = "D:";
      resourceKey = "windowsDDrive";
    };
    e = {
      letter = "E:";
      resourceKey = "windowsEDrive";
    };
  };
  journal = {
    storage = "persistent";
    maximumBytes = maximumJournalGiB * gibibyte;
    systemMaxUse = "${toString maximumJournalGiB}G";
    maximumRetention = "30day";
  };
  fstrim = {
    timerName = "fstrim";
    serviceName = "fstrim";
    interval = "weekly";
    virtualizationCondition = [
      ""
      "wsl"
    ];
  };
  mkWindowsPercentageObservation = import ../package.nix;
  windowsPercentageObservation =
    commandName: powershellProbe:
    mkWindowsPercentageObservation {
      inherit
        pkgs
        lib
        commandName
        powershellProbe
        powershellCommand
        ;
      timeoutSeconds = observationTimeoutSeconds;
    };
  windowsDriveObservations = lib.mapAttrs (
    name: drive:
    windowsPercentageObservation "dotfiles-observe-windows-${name}-drive" ''
      $volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive.letter}'"; if ($null -eq $volume -or $volume.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor(($volume.FreeSpace * 100) / $volume.Size))
    ''
  ) windowsDrives;
  driveObservations = lib.mapAttrs' (
    name: drive:
    lib.nameValuePair "host/windows-${name}-drive" {
      kind = "numeric-command-threshold";
      checkId = "resource/windows-${name}-drive";
      inherit (drive) resourceKey;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe Windows ${lib.toUpper name} drive free space";
      command = windowsDriveObservations.${name};
      metric = "free-percent";
      warning = 15;
      failure = 10;
    }
  ) windowsDrives;
in
{
  config.dotfiles.health.observations = driveObservations // {
    "host/root-filesystem" = {
      kind = "filesystem-threshold";
      checkId = "resource/root-filesystem";
      resourceKey = "rootFilesystem";
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe root filesystem utilization";
      inherit (rootFilesystem)
        path
        metric
        warning
        failure
        ;
    };
    "host/journald" = {
      kind = "journal-size";
      checkId = "resource/journald";
      resourceKey = "journald";
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe journald disk usage";
      inherit (journal) maximumBytes;
    };
    "host/fstrim" = {
      kind = "systemd-timer";
      checkId = "maintenance/${fstrim.timerName}.timer";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "${fstrim.timerName}.timer or its service is not operational";
      timer = "${fstrim.timerName}.timer";
      service = "${fstrim.serviceName}.service";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
  };

  # 障害履歴を残しつつ、長期稼働時の journal に明示的な上限を設ける
  config.services.journald = {
    inherit (journal) storage;
    extraConfig = ''
      SystemMaxUse=${journal.systemMaxUse}
      MaxRetentionSec=${journal.maximumRetention}
    '';
  };

  # util-linux の unit 本体、ExecStart、schedule は再利用し、WSL で失敗する
  # vendor condition だけを drop-in で置き換える
  config.services.fstrim.interval = fstrim.interval;
  config.systemd.services.${fstrim.serviceName} = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionVirtualization = fstrim.virtualizationCondition;
  };
  config.systemd.timers.${fstrim.timerName} = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionVirtualization = fstrim.virtualizationCondition;
  };
}
