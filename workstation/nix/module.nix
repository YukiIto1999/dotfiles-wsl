{ config, lib, ... }:

let
  cfg = config.dotfiles.workstation;
  gibibyte = 1073741824;
  # 同じ support slice の他の service（既定 100）より build を後に回す。
  nixDaemonCpuWeight = 50;
  binaryCaches = import ./assets/nix-caches.nix;
in
{
  options.dotfiles.workstation.nix = {
    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "nix-daemon の同時 build 数";
    };
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "各 Nix build に渡す CPU core 数";
    };
    minimumFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Nix 自動 GC を開始する store 空き容量 GiB";
    };
    targetFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Nix 自動 GC の目標 store 空き容量 GiB";
    };
  };

  config.assertions = [
    {
      assertion = cfg.nix.minimumFreeGiB < cfg.nix.targetFreeGiB;
      message = "Nix minimumFreeGiB must be below targetFreeGiB";
    }
    {
      assertion = cfg.nix.targetFreeGiB < cfg.storage.vhd.sizeGiB;
      message = "Nix targetFreeGiB must be below the declared root VHD capacity";
    }
  ];

  config.programs.nix-ld.enable = true;
  config.nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = map (cache: cache.substituter) binaryCaches;
    trusted-public-keys = map (cache: cache.publicKey) binaryCaches;
    trusted-users = [
      "root"
      cfg.username
    ];
    min-free = cfg.nix.minimumFreeGiB * gibibyte;
    max-free = cfg.nix.targetFreeGiB * gibibyte;
    max-jobs = cfg.nix.maxJobs;
    inherit (cfg.nix) cores;
  };

  # 常時起動でない WSL で取りこぼした GC を次回起動で補完
  config.nix.gc = {
    automatic = true;
    dates = "weekly";
    persistent = true;
    options = "--delete-older-than 14d";
  };
  # 大規模store走査はAgentのビルドI/Oと競合してVHDを長時間停止させるため、
  # 自動optimiseは実行しない。必要な場合だけ全session停止後の保守で行う。
  config.nix.optimise.automatic = false;

  # crates.io が curl 既定 UA を 403 拒否するため指定する許可 UA
  config.systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";
  # build は nix-daemon の cgroup で動くため、user.slice の中へ置かないと上限の外で memory を使う
  config.systemd.services.nix-daemon.serviceConfig = {
    Slice = config.dotfiles.workstation.memory.supportSlice;
    CPUWeight = nixDaemonCpuWeight;
  };
}
