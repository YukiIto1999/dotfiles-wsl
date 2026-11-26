{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation.storage;
in
{
  options.dotfiles.workstation.storage = {
    vhd = {
      sizeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 256;
        description = "Windows 準備で使用する root VHD 容量 GiB";
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

  # 障害履歴を残しつつ、長期稼働時の journal に明示的な上限を設ける
  config.services.journald = {
    storage = "persistent";
    extraConfig = ''
      SystemMaxUse=${toString cfg.journal.maximumGiB}G
      MaxRetentionSec=30day
    '';
  };

  config.services.fstrim.enable = false;
  # WSL では systemd-remount-fs が省略されるため同 unit での root 再 mount は不可
  config.wsl.wslConf.boot.command = "${lib.getExe' pkgs.util-linux "mount"} -o remount,nodiscard /";
}
