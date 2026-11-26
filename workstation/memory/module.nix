{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation.memory;
  zram = {
    algorithm = "lzo-rle";
    priority = 100;
  };
  reserveSwapFile = "/var/lib/dotfiles-agent-swap/reserve.swap";
  userMemoryMaxPercent = 100 - cfg.user.hostReservePercent;
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
  zramGenerator = "${pkgs.zram-generator.outPath}/lib/systemd/system-generators/zram-generator";
  zramSetup = pkgs.writeShellScript "dotfiles-zram-setup" ''
    set -euo pipefail

    if ${lib.getExe pkgs.gnugrep} -Eq '^(/dev)?/zram0[[:space:]]' /proc/swaps; then
      exit 0
    fi
    ${lib.getExe' pkgs.kmod "modprobe"} zram num_devices=1
    test -b /dev/zram0
    ${zramGenerator} --setup-device zram0
    ${lib.getExe' pkgs.util-linux "swapon"} --priority ${toString zram.priority} /dev/zram0
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
  percent = value: "${toString value}%";
in
{
  options.dotfiles.workstation.memory = {
    zramMemoryPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 25;
      description = "物理 memory に対する zram device size の割合。";
    };
    user = {
      hostReservePercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 20;
        description = ''
          物理 memory のうち user.slice の外へ残す割合。kernel、WSL の init と WSLg、systemd、
          Docker daemon と基盤 service がこの残りで動く。user.slice の MemoryMax は 100 からこの値を引いた値になる。
        '';
      };
      swapMaxPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 50;
        description = "user.slice 全体の MemorySwapMax。swap 総量ではなく物理 memory に対する割合。";
      };
    };
    agents = {
      memoryMaxPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 70;
        description = "agents.slice の MemoryMax を物理 RAM の百分率で指定する。";
      };
      # 11-01 の凍結は agent の作業が swap へ溢れ続けた thrash だった。swap の上限を低く置き、
      # 溢れた cgroup が swap で粘らずに MemoryMax の OOM と systemd-oomd で止まるようにする
      memorySwapMaxPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 25;
        description = "agents.slice の MemorySwapMax を物理 RAM の百分率で指定する。";
      };
      cpuWeight = lib.mkOption {
        type = lib.types.ints.between 1 10000;
        default = 50;
        description = "agents.slice の CPUWeight。同じ user manager の他の slice の既定 100 より低くする。";
      };
    };
    userManager.memoryMaxPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 75;
      description = "user manager 全体の MemoryMax を物理 RAM の百分率で指定する。";
    };
    supportSlice = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      # 名前を変えると nix-daemon と docker の unit が変わり、switch が動いている build と container を止める
      default = "user-workload.slice";
      description = "user.slice の上限の中で動かす root 所有の開発支援 service（nix-daemon、backend container）の slice。";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.agents.memoryMaxPercent < cfg.userManager.memoryMaxPercent;
        message = "The user manager's MemoryMax must enclose agents.slice";
      }
    ];

    boot.kernel.sysctl = virtualMemorySysctl;

    # user session と開発支援 service の共通の上限。kernel と WSL の基盤の分を外に残す。
    # どの層にも MemoryHigh は置かない。2026-11-26 の実測で user.slice は起動後約23時間に high を 3,414,763 回、
    # user@1000 は 2,358,221 回、agents.slice は 2,285,613 回超え、agents.slice の memory PSI は full avg60 ≈ 11 % だった。
    # 超えた分の大半は回収できる page cache で、high は超過量に応じて process を待たせる。
    # 予備を残す役目は MemoryMax が持ち、到達時は cache から回収し、回収できなければその層の中で OOM になる
    systemd.slices.user.sliceConfig = {
      MemoryMax = percent userMemoryMaxPercent;
      MemorySwapMax = percent cfg.user.swapMaxPercent;
    };
    systemd.slices.${lib.removeSuffix ".slice" cfg.supportSlice}.description =
      "Root-owned development support inside the user slice";

    # Chromium が自ら app.slice へ作る scope による agents.slice の迂回
    systemd.services."user@".serviceConfig.MemoryMax = percent cfg.userManager.memoryMaxPercent;

    # agent client の wrapper が session ごとの scope をこの slice の直下へ置く。
    # 防ぎたい 2026-11-01 の凍結は anon と swap の thrash で、それは MemoryMax の上限、小さい swap の上限、
    # systemd-oomd の kill が、待たせずに止める
    systemd.user.slices.agents = {
      description = "Agent session の資源上限";
      sliceConfig = {
        MemoryMax = percent cfg.agents.memoryMaxPercent;
        MemorySwapMax = percent cfg.agents.memorySwapMaxPercent;
        CPUWeight = cfg.agents.cpuWeight;
        # pressure が続く scope と、swap が尽きかけたときに最も swap を使う scope を止める
        ManagedOOMMemoryPressure = "kill";
        ManagedOOMSwap = "kill";
      };
    };

    # pressure が続く cgroup を kernel の OOM より先に止め、host の凍結を避ける
    systemd.oomd = {
      enable = true;
      enableUserSlices = true;
    };

    systemd.services.dotfiles-agent-reserve-swap = {
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
        ExecStart = "${pkgs.writeShellScript "dotfiles-agent-reserve-swap" (builtins.readFile ./reserve-swap.sh)} ${lib.escapeShellArg reserveSwapFile}";
      };
    };

    # zram-generator は WSL を container と判定して unit 生成を省略するため、
    # 設定と device setup は再利用し、lifecycle だけを専用 service で接続する
    zramSwap.enable = false;
    services.zram-generator = {
      enable = true;
      settings.zram0 = {
        compression-algorithm = zram.algorithm;
        swap-priority = zram.priority;
        zram-size = "${toString cfg.zramMemoryPercent} / 100 * ram";
      };
    };
    systemd.services.dotfiles-zram-swap = {
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
  };
}
