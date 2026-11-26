{ config, lib, ... }:

let
  cfg = config.dotfiles.workstation;
  containersSlice = "${lib.removeSuffix ".slice" cfg.memory.supportSlice}-containers.slice";
  reservedSpace = "10GB";
  unsharedMaxUsedSpace = "30GB";
in
{
  users.users.${cfg.username}.extraGroups = [ "docker" ];

  # live-restore が無いため、daemon.json と docker.service の変更は switch で dockerd を再起動し、
  # 動いている project の container を止める。設定を変えるときは停止を計画して適用する
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      # 古い build cache から順に、共有されない cache と全体の上限まで BuildKit の cache を回収する
      builder.gc = {
        enabled = true;
        policy = [
          {
            keepDuration = "1440h";
            inherit reservedSpace;
            maxUsedSpace = unsharedMaxUsedSpace;
          }
          {
            inherit reservedSpace;
            maxUsedSpace = unsharedMaxUsedSpace;
          }
          {
            all = true;
            inherit reservedSpace;
            maxUsedSpace = "100GB";
          }
        ];
      };
      # docker の既定の system.slice は基盤の service と同じ上限なしの配置になるため既定のままは不可
      cgroup-parent = containersSlice;
    };
  };
  virtualisation.oci-containers.backend = "docker";

  # project が起動する container の上限。宣言した backend は supportSlice の側に置く。
  # MemoryHigh を置かない理由は workstation/memory/module.nix と同じ
  systemd.slices.${lib.removeSuffix ".slice" containersSlice} = {
    description = "Docker containers outside the declared backends";
    sliceConfig = {
      MemoryMax = "10%";
      MemorySwapMax = "10%";
      CPUWeight = 50;
    };
  };
}
