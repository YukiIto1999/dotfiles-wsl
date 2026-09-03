{ config, ... }:

let
  cfg = config.dotfiles.workstation;
  gibibyte = 1073741824;
  observationTimeoutSeconds = 10;
  minimumNixFreeGiB = 160;
  targetNixFreeGiB = 256;
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
  config.dotfiles.workstation.binaryCaches = binaryCaches;
  config.dotfiles.health.observations = {
    "host/nix-daemon" = {
      kind = "systemd-socket";
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
  };

  # 常時起動でない WSL で取りこぼした GC を次回起動で補完
  config.nix.gc = nixGc.settings;
  config.nix.optimise.automatic = true;

  # crates.io が curl 既定 UA を 403 拒否するため指定する許可 UA
  config.systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";
}
