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
  };

  # 障害履歴を残しつつ、長期稼働時の journal に明示的な上限を設ける
  config.services.journald = {
    inherit (journal) storage;
    extraConfig = ''
      SystemMaxUse=${journal.systemMaxUse}
      MaxRetentionSec=${journal.maximumRetention}
    '';
  };

  # WSL は root ext4 を discard 付きで mount するため、定期 TRIM を重ねて I/O を増やさない。
  config.services.fstrim.enable = false;
}
