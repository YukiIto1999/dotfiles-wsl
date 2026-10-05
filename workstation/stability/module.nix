{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  zramAlgorithm = "lzo-rle";
  zramMemoryPercent = cfg.swap.zramMemoryPercent;
  zramPriority = 100;
  minimumSwapGiB = cfg.swap.minimumTotalGiB;
  pageblockKbytes = 2048;
  lowmemZones = 2;
  migratetypes = 3;
  khugepagedMinFreeKbytes = lowmemZones * (2 + migratetypes * migratetypes) * pageblockKbytes;
  # WSL の kernel は distro の再起動を越えて旧世代の値を保つため kernel の既定値の宣言の省略は不可
  virtualMemorySysctl = {
    # high watermark に比例する boost が空き block のある zone でも GFP_KERNEL の VMBus ring 確保を watermark で落とすため min と kswapd の間隔の引き上げは不可
    "vm.min_free_kbytes" = khugepagedMinFreeKbytes;
    "vm.watermark_scale_factor" = 10;
    "vm.compaction_proactiveness" = 20;
    # fallback を禁じると unmovable な order-7 の VMBus ring 確保が失敗するため有効化は不可
    "vm.defrag_mode" = 0;
  };
  swap = {
    minimumTotalBytes = minimumSwapGiB * gibibyte;
    requireZram = true;
    zramAboveDisk = true;
    zram = {
      algorithm = zramAlgorithm;
      priority = zramPriority;
      size = "${toString zramMemoryPercent} / 100 * ram";
    };
  };
  windowsMemoryCommit = {
    powershellCommand = cfg.wsl.powershellCommand;
    metric = "used-percent";
    warning = cfg.windowsMemoryCommit.warning;
    failure = cfg.windowsMemoryCommit.failure;
  };
  mkWindowsPercentageObservation = import ../package.nix;
  windowsMemoryCommitObservation = mkWindowsPercentageObservation {
    inherit pkgs lib;
    commandName = "dotfiles-observe-windows-memory-commit";
    powershellProbe = ''
      $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; if ($null -eq $memory -or $memory.CommitLimit -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor(($memory.CommittedBytes * 100) / $memory.CommitLimit))
    '';
    inherit (windowsMemoryCommit) powershellCommand;
    timeoutSeconds = observationTimeoutSeconds;
  };
  wslMemoryObservation = import ./impl/wsl-memory-package.nix {
    inherit pkgs lib;
    journalTimeoutSeconds = 20;
    pressureWarning = 10;
    pressureFailure = 40;
    relayMinimumAgeSeconds = 300;
  };
  wslMemoryContract = wslMemoryObservation.dotfilesObservationContract;
  zramGenerator = "${pkgs.zram-generator.outPath}/lib/systemd/system-generators/zram-generator";
  zramSetup = pkgs.writeShellScript "dotfiles-zram-setup" ''
    set -euo pipefail

    if ${lib.getExe pkgs.gnugrep} -Eq '^(/dev)?/zram0[[:space:]]' /proc/swaps; then
      exit 0
    fi
    ${lib.getExe' pkgs.kmod "modprobe"} zram num_devices=1
    test -b /dev/zram0
    ${zramGenerator} --setup-device zram0
    ${lib.getExe' pkgs.util-linux "swapon"} --priority ${toString swap.zram.priority} /dev/zram0
  '';
  zramTeardown = pkgs.writeShellScript "dotfiles-zram-teardown" ''
    set -euo pipefail

    if ${lib.getExe pkgs.gnugrep} -Eq '^(/dev)?/zram0[[:space:]]' /proc/swaps; then
      exit 0
    fi
    if test -e /sys/block/zram0/reset; then
      ${zramGenerator} --reset-device zram0
    fi
  '';
in
{
  options.dotfiles.workstation = {
    swap = {
      zramMemoryPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 25;
        description = "物理 memory に対する zram device size の割合。";
      };
      minimumTotalGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "zram と disk swap を合わせた最小容量 GiB";
      };
    };
    windowsMemoryCommit = {
      warning = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 85;
        description = "Windows committed memory 使用率の警告値。";
      };
      failure = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 95;
        description = "Windows committed memory 使用率の異常値。";
      };
    };
  };

  config.assertions = [
    {
      assertion = cfg.windowsMemoryCommit.warning < cfg.windowsMemoryCommit.failure;
      message = "Windows committed memory warning threshold must be below failure";
    }
  ];

  config.dotfiles.health.observations = {
    "host/swap" = {
      kind = "swap-policy";
      checkId = "resource/swap";
      resourceKey = "swap";
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "swap must include ${swap.zram.algorithm} zram above any disk swap with at least ${toString minimumSwapGiB} GiB total";
      inherit (swap) minimumTotalBytes requireZram zramAboveDisk;
      requiredZramAlgorithm = swap.zram.algorithm;
    };
    "host/windows-memory-commit" = {
      kind = "numeric-command-threshold";
      checkId = "resource/windows-memory-commit";
      resourceKey = "windowsMemoryCommit";
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "could not observe Windows committed memory";
      command = windowsMemoryCommitObservation;
      inherit (windowsMemoryCommit) metric warning failure;
    };
    "host/wsl-memory" = {
      kind = "normalized-protocol";
      checkId = "resource/wsl-memory";
      resourceKey = null;
      timeoutSeconds = wslMemoryContract.outerTimeout;
      failureMessage = "could not observe WSL memory health";
      command = wslMemoryObservation;
      inherit (wslMemoryContract)
        allowedOutcomeIds
        requiredOutcomeIds
        requiredResourceKeys
        envelopeVersion
        ;
    };
  };

  config.boot.kernel.sysctl = virtualMemorySysctl;

  # zram-generator は WSL を container と判定して unit 生成を省略するため、
  # 設定と device setup は再利用し、lifecycle だけを専用 service で接続する
  config.zramSwap.enable = false;
  config.services.zram-generator = {
    enable = true;
    settings.zram0 = {
      compression-algorithm = swap.zram.algorithm;
      swap-priority = swap.zram.priority;
      zram-size = swap.zram.size;
    };
  };
  config.systemd.services.dotfiles-zram-swap = {
    description = "Create compressed swap on /dev/zram0 under WSL";
    wantedBy = [ "swap.target" ];
    before = [
      "swap.target"
      "shutdown.target"
    ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    unitConfig.DefaultDependencies = false;
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = zramSetup;
      ExecStopPost = zramTeardown;
    };
  };

}
