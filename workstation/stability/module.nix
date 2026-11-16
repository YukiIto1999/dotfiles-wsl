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
  reserveSwapFile = "/var/lib/dotfiles-agent-swap/reserve.swap";
  minimumSwapGiB = cfg.swap.minimumTotalGiB;
  inherit (cfg) workload;
  inherit (workload) reservation;
  runtimeDirectory = "/run/dotfiles-workload/${cfg.username}";
  # class は走行が待つ者のいる検証か（acceptance）、いない検証か（deep）。計測の一行が持つ
  workloadPolicy =
    class: memoryPercent:
    pkgs.writeText "dotfiles-workload-policy-${class}.json" (
      builtins.toJSON {
        inherit class runtimeDirectory memoryPercent;
        observation = [ (lib.getExe workload.observationPackage) ];
        maximumObservationAgeSeconds = 10;
      }
    );
  workloadMemoryMaxPercent = 100 - workload.hostReservePercent;
  workloadMemoryHighPercent = workloadMemoryMaxPercent - workload.reclaimMarginPercent;
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
    metric = "used-percent";
    warning = cfg.windowsMemoryCommit.warning;
    failure = cfg.windowsMemoryCommit.failure;
  };
  pressure = {
    warning = 10;
    failure = 40;
  };
  windowsSnapshotPolicy = {
    collectorIntervalSeconds = 10;
    maximumAgeSeconds = 60;
    futureSkewSeconds = 5;
    fileName = "windows-memory.json";
  };
  windowsSnapshotReader = import ./impl/windows-snapshot-package.nix {
    inherit pkgs lib;
    snapshotPath = "${workload.windowsSnapshotDirectory}/${windowsSnapshotPolicy.fileName}";
    inherit (windowsSnapshotPolicy) maximumAgeSeconds futureSkewSeconds;
  };
  windowsMemoryCommitObservation = import ./impl/windows-commit-package.nix {
    inherit pkgs lib;
    reader = windowsSnapshotReader;
  };
  windowsCollector = import ./impl/windows-collector-package.nix {
    inherit pkgs lib;
    reader = windowsSnapshotReader;
    inherit (cfg.wsl) powershellCommand;
    intervalSeconds = windowsSnapshotPolicy.collectorIntervalSeconds;
  };
  workloadObservation = import ./impl/workload-package.nix {
    inherit pkgs lib;
    reader = windowsSnapshotReader;
    inherit (workload) hostReservePercent;
    aggregateCgroup = "/${workload.slices.aggregate}";
    pressureWarning = pressure.warning;
    pressureFailure = pressure.failure;
    windowsCommitWarning = windowsMemoryCommit.warning;
    windowsCommitFailure = windowsMemoryCommit.failure;
    windowsPhysicalReserveBytes = workload.windowsPhysicalReserveGiB * gibibyte;
    declaredMemoryBytes = lib.mapNullable (
      memoryGiB: memoryGiB * gibibyte
    ) cfg.wsl.windowsConfig.memoryGiB;
    declaredProcessors = cfg.wsl.windowsConfig.processors;
  };
  wslMemoryObservation = import ./impl/wsl-memory-package.nix {
    inherit pkgs lib;
    journalTimeoutSeconds = 20;
    pressureWarning = pressure.warning;
    pressureFailure = pressure.failure;
    relayMinimumAgeSeconds = 300;
  };
  wslMemoryContract = wslMemoryObservation.dotfilesObservationContract;
  workloadContract = workloadObservation.dotfilesObservationContract;
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
    workload = {
      reservation = {
        verificationMemoryPercent = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = 25;
          description = ''
            計測の記録が無い走行だけに使う未計測の値。検証一走行が予約する物理memoryを、
            最初の有効な資源観測の cgroup limitBytes の最小値（無ければ物理memory総量）に対する割合で表す。
            記録のある走行は、直近の実測のピークから決めた需要を予約する。hard limitではなく開始前の需要宣言。
          '';
        };
        jobMemoryPercent = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = reservation.verificationMemoryPercent;
          description = ''
            計測の記録が無い走行だけに使う未計測の値。非対話agent job全体の物理memory需要を、
            検証と同じ基準（cgroup limitBytes の最小値、無ければ物理memory総量）に対する割合で表す。
            入れ子の検証を含む需要を外側で予約する。
          '';
        };
      };
      admissionPolicy = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        internal = true;
        description = "同じhostの全検証で共有する、待つ者のいる検証（T1とpre-push）の資源予約policy。";
      };
      deepAdmissionPolicy = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        internal = true;
        description = "同じregistryへ参加する、待つ者のいない検証（dotfiles-workload-run）の資源予約policy。";
      };
      jobAdmissionPolicy = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        internal = true;
        description = "検証と同じregistryへ参加する非対話jobの予約policy。";
      };
      hostReservePercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 20;
        description = ''
          物理 memory のうち user.slice の外へ残す割合。kernel、WSL の init と WSLg、systemd、
          Docker daemon と基盤 service がこの残りで動く。user.slice の MemoryMax は 100 からこの値を引いた値になる。
        '';
      };
      reclaimMarginPercent = lib.mkOption {
        type = lib.types.ints.between 1 98;
        default = 5;
        description = "user.slice の MemoryHigh を MemoryMax より手前に置く幅（物理 memory の百分率）。";
      };
      memorySwapMaxPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 50;
        description = "user.slice 全体の MemorySwapMax。swap 総量ではなく物理 memory に対する割合。";
      };
      memoryHighPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        readOnly = true;
        internal = true;
        description = "user.slice の MemoryHigh。reserve と回収の幅から導く。";
      };
      memoryMaxPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        readOnly = true;
        internal = true;
        description = "user.slice の MemoryMax。reserve から導く。";
      };
      slices = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        internal = true;
        default = {
          aggregate = "user.slice";
          support = "user-workload.slice";
          containers = "user-workload-containers.slice";
        };
        description = ''
          資源の共通の祖先と、その下の root 所有 workload の slice 名。
          container の配置、Nix、MCP の slice はこの値だけを参照する。
        '';
      };
      windowsSnapshotDirectory = lib.mkOption {
        type = lib.types.strMatching "/mnt/[a-z]/ProgramData/[A-Za-z0-9._-]+";
        default =
          let
            drive = builtins.match "/mnt/([a-z])/Windows/.+" cfg.wsl.powershellCommand;
          in
          if drive == null then
            throw "dotfiles.workstation.workload.windowsSnapshotDirectory must be set when wsl.powershellCommand is not under /mnt/<drive>/Windows"
          else
            "/mnt/${builtins.head drive}/ProgramData/dotfiles-resource-observation";
        description = ''
          Windows 側の collector が memory の snapshot を置く directory を、この WSL から見た path。
          Windows の ProgramData の直下に置き、利用者名は path に含めない。
          既定は wsl.powershellCommand の drive から導く。
        '';
      };
      windowsPhysicalReserveGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = ''
          Windows の物理 memory の空きのうち、workload の admission が使わず Windows に残す GiB。
          windowsPhysicalHeadroomBytes は空きからこの値を引いた余力で、実測で見直す方針値。
        '';
      };
      observationPackage = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        internal = true;
        description = ''
          dotfiles-observe-workload。Linux の memory と CPU の余力、祖先 cgroup の memory 制限の余力、PSI、
          Windows 側 snapshot の memory を正規化 envelope の resource workload として返す。
          passthru の dotfilesObservationContract が health と admission の共通の契約になる。

          memoryLimits の headroomBytes は min(memory.high, memory.max) から working set を引いた値で、
          有限の memory.high に対する保証ではない。working set は memory.current から、回収できる page cache
          （inactive_file と active_file の和から file_mapped、file_dirty、file_writeback を引いた値、負なら 0）を
          引いた値で、host 側の MemAvailable と同じく map されていない clean な cache を回収可能と数える。
          回収が重くなった場合は memory full pressure の閾値が入場を止める。
          回収の見込みを数えない値は limitBytes と currentBytes から limitBytes - currentBytes で得る。

          windowsCommitHeadroomBytes は windowsMemoryCommit.warning の割合までの余力で、
          残りの commit 全量ではない。windowsPhysicalHeadroomBytes は物理 memory の空きから
          windowsPhysicalReserveGiB を引いた余力。wsl-cap の outcome は宣言と .wslconfig と稼働中の VM の差を診断し、
          admission は稼働中の VM の容量を測るため圧迫の判断には使わない。
        '';
      };
    };
  };

  config.assertions = [
    {
      assertion = cfg.windowsMemoryCommit.warning < cfg.windowsMemoryCommit.failure;
      message = "Windows committed memory warning threshold must be below failure";
    }
    {
      assertion = workload.reclaimMarginPercent < workloadMemoryMaxPercent;
      message = "Workload reclaim margin must be below the workload MemoryMax";
    }
    {
      assertion =
        windowsSnapshotPolicy.collectorIntervalSeconds * 3 <= windowsSnapshotPolicy.maximumAgeSeconds;
      message = "The Windows memory snapshot must stay fresh across two missed collector samples";
    }
    {
      assertion = windowsSnapshotReader.dotfilesWindowsSnapshot.outerTimeout < observationTimeoutSeconds;
      message = "Reading the Windows memory snapshot must finish before the observation timeout";
    }
    {
      assertion =
        workload.slices.aggregate == "user.slice"
        && lib.hasPrefix "user-" workload.slices.support
        && lib.hasPrefix "${lib.removeSuffix ".slice" workload.slices.support}-" workload.slices.containers;
      message = "Workload slices must retain user.slice as the common ancestor of native user sessions and support workloads";
    }
  ];

  config.dotfiles.workstation.workload = {
    memoryHighPercent = workloadMemoryHighPercent;
    memoryMaxPercent = workloadMemoryMaxPercent;
    observationPackage = workloadObservation;
    admissionPolicy = workloadPolicy "acceptance" reservation.verificationMemoryPercent;
    deepAdmissionPolicy = workloadPolicy "deep" reservation.verificationMemoryPercent;
    jobAdmissionPolicy = workloadPolicy "deep" reservation.jobMemoryPercent;
  };
  config.dotfiles.platform.cli.commands = {
    observeWorkload = workloadObservation;
    windowsResourceCollector = windowsCollector;
  };

  config.systemd.tmpfiles.rules = [
    "d /run/dotfiles-workload 0755 root root -"
    "d ${runtimeDirectory} 0700 ${cfg.username} users -"
  ];

  config.systemd.slices.${lib.removeSuffix ".slice" workload.slices.aggregate}.sliceConfig = {
    MemoryHigh = "${toString workloadMemoryHighPercent}%";
    MemoryMax = "${toString workloadMemoryMaxPercent}%";
    MemorySwapMax = "${toString workload.memorySwapMaxPercent}%";
  };
  config.systemd.slices.${lib.removeSuffix ".slice" workload.slices.support}.description =
    "Root-owned development support inside the user slice";

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
    "host/workload" = {
      kind = "normalized-protocol";
      checkId = "resource/workload";
      resourceKey = null;
      timeoutSeconds = workloadContract.outerTimeout;
      failureMessage = "could not observe workload resources";
      command = workloadObservation;
      inherit (workloadContract)
        allowedOutcomeIds
        requiredOutcomeIds
        requiredResourceKeys
        envelopeVersion
        ;
    };
  };

  config.systemd.services.dotfiles-agent-reserve-swap = {
    description = "Activate provisioned agent swap reserve";
    wantedBy = [ "multi-user.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig.ConditionPathExists = reserveSwapFile;
    path = [
      pkgs.util-linux
      pkgs.gnugrep
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "dotfiles-agent-reserve-swap" (builtins.readFile ./impl/reserve-swap.sh)} ${lib.escapeShellArg reserveSwapFile}";
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
