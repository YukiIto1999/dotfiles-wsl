{ config, lib, ... }:

let
  cfg = config.dotfiles.workstation;
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  minimumNixFreeGiB = cfg.nix.minimumFreeGiB;
  targetNixFreeGiB = cfg.nix.targetFreeGiB;
  maxJobs = cfg.nix.maxJobs;
  buildCores = cfg.nix.cores;
  # 同じ system.slice の journald、udevd、container、MCP front（既定 100）より build を後に回す。
  nixDaemonCpuWeight = 50;
  binaryCaches = import ./assets/nix-caches.nix;
  nixGc = {
    timerName = "nix-gc";
    serviceName = "nix-gc";
    storageReserve = {
      minimumBytes = minimumNixFreeGiB * gibibyte;
      targetBytes = targetNixFreeGiB * gibibyte;
    };
    settings = {
      automatic = true;
      dates = "weekly";
      persistent = true;
      options = "--delete-older-than 14d";
    };
  };
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

  config.dotfiles.workstation.binaryCaches = binaryCaches;
  config.dotfiles.health.observations = {
    "host/nix-daemon" = {
      kind = "systemd-socket";
      manager = "system";
      checkId = "nix-daemon";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "nix-daemon.socket is not operational";
      unit = "nix-daemon.socket";
      loadStates = [ "loaded" ];
      activeStates = [ "active" ];
      results = [ "success" ];
    };
    "host/nix-gc" = {
      kind = "systemd-timer";
      manager = "system";
      checkId = "maintenance/${nixGc.timerName}.timer";
      resourceKey = null;
      timeoutSeconds = observationTimeoutSeconds;
      failureMessage = "${nixGc.timerName}.timer or its service is not operational";
      timer = "${nixGc.timerName}.timer";
      service = "${nixGc.serviceName}.service";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
      activeStates = [ "active" ];
      serviceResults = [ "success" ];
    };
  };

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
    min-free = nixGc.storageReserve.minimumBytes;
    max-free = nixGc.storageReserve.targetBytes;
    max-jobs = maxJobs;
    cores = buildCores;
  };

  # 常時起動でない WSL で取りこぼした GC を次回起動で補完
  config.nix.gc = nixGc.settings;
  # 大規模store走査はAgentのビルドI/Oと競合してVHDを長時間停止させるため、
  # 自動optimiseは実行しない。必要な場合だけ全session停止後の保守で行う。
  config.nix.optimise.automatic = false;

  # crates.io が curl 既定 UA を 403 拒否するため指定する許可 UA
  config.systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";
  config.systemd.services.nix-daemon.serviceConfig.CPUWeight = nixDaemonCpuWeight;
}
