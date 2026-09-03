{
  pkgs,
  lib,
  ...
}:

let
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  zramAlgorithm = "lzo-rle";
  zramMemoryPercent = 25;
  zramPriority = 100;
  minimumSwapGiB = 8;
  virtualMemorySysctl = {
    "vm.min_free_kbytes" = 262144;
    "vm.watermark_scale_factor" = 100;
    "vm.compaction_proactiveness" = 40;
    "vm.defrag_mode" = 1;
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
    powershellCommand = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
    metric = "used-percent";
    warning = 85;
    failure = 95;
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
  zramGenerator = "${pkgs.zram-generator}/lib/systemd/system-generators/zram-generator";
  zramSetup = pkgs.writeShellScript "dotfiles-zram-setup" ''
    set -euo pipefail

    ${lib.getExe' pkgs.kmod "modprobe"} zram num_devices=1
    test -b /dev/zram0
    ${zramGenerator} --setup-device zram0
    ${lib.getExe' pkgs.util-linux "swapon"} --priority ${toString swap.zram.priority} /dev/zram0
  '';
  zramTeardown = pkgs.writeShellScript "dotfiles-zram-teardown" ''
    set -euo pipefail

    if ${lib.getExe pkgs.gnugrep} -q '^/dev/zram0[[:space:]]' /proc/swaps; then
      ${lib.getExe' pkgs.util-linux "swapoff"} /dev/zram0
    fi
    if test -e /sys/block/zram0/reset; then
      ${zramGenerator} --reset-device zram0
    fi
  '';
in
{
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
