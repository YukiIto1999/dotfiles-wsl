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
in
{
  config.dotfiles.health.observations = {
    "host/windows-drives" = {
      kind = "numeric-command-threshold-set";
      checkId = "resource/windows-drives";
      resourceKey = "windowsDrives";
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe Windows drive free space";
      command = import ./package.nix { inherit pkgs lib; };
      metric = "free-percent";
      warning = 15;
      failure = 10;
    };
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
