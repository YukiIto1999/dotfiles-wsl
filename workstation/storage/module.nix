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
  # sparse VHD が host drive を使い切ると root ext4 が壊れる（2026-09-28）。VHD は上限付きの non-sparse
  # にする。この二つは Windows 側の .wslconfig が VHD の作成時に与えるため配らず、doctor が宣言との差を検出する
  wslVhd = {
    sizeBytes = 800 * gibibyte;
    sparse = false;
    powershellCommand = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
  };
  wslVhdObservation = import ./impl/wsl-vhd-package.nix {
    inherit pkgs lib;
    inherit (wslVhd) sizeBytes sparse powershellCommand;
    timeoutSeconds = observationTimeoutSeconds;
  };
  wslVhdContract = wslVhdObservation.dotfilesObservationContract;
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
    "host/wsl-vhd" = {
      kind = "normalized-protocol";
      checkId = "resource/wsl-vhd";
      resourceKey = null;
      timeoutSeconds = wslVhdContract.outerTimeout;
      failureMessage = "could not observe the WSL root VHD";
      command = wslVhdObservation;
      inherit (wslVhdContract)
        allowedOutcomeIds
        requiredOutcomeIds
        requiredResourceKeys
        envelopeVersion
        ;
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
