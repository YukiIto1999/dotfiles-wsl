{ config, ... }:

let
  binaryCaches = import ./nix-caches.nix;
in
{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = map (cache: cache.substituter) binaryCaches;
    trusted-public-keys = map (cache: cache.publicKey) binaryCaches;
    trusted-users = [
      "root"
      config.my.username
    ];
  };

  # 常時起動でない WSL で取りこぼした GC を次回起動で補完
  nix.gc = {
    automatic = true;
    dates = "weekly";
    persistent = true;
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  # crates.io が curl 既定 UA を 403 拒否するため指定する許可 UA
  systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";
}
