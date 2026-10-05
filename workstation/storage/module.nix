{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation.storage;
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  maximumJournalGiB = cfg.journal.maximumGiB;
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
  wslVhd = {
    sizeBytes = cfg.vhd.sizeGiB * gibibyte;
    sparse = cfg.vhd.sparse;
    powershellCommand = config.dotfiles.workstation.wsl.powershellCommand;
  };
  wslVhdObservation = import ./impl/wsl-vhd-package.nix {
    inherit pkgs lib;
    inherit (wslVhd) sizeBytes sparse powershellCommand;
    timeoutSeconds = observationTimeoutSeconds;
  };
  wslVhdContract = wslVhdObservation.dotfilesObservationContract;
in
{
  options.dotfiles.workstation.storage = {
    vhd = {
      sizeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 256;
        description = "Windows 準備と doctor で使用する root VHD 容量 GiB";
      };
      sparse = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "新規 VHD の sparse 選択 既存 VHD を変更しない宣言値";
      };
    };
    journal.maximumGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "journald 使用容量の上限 GiB";
    };
  };

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
