{
  dotfiles = {
    toolchain.git.workIdentity = "~/projects/business/";

    knowledge = {
      journal = {
        enable = true;
        # 既存の日誌の file 名が Windows のコンピューター名のため host ID の既定値は不可
        machineName = "y-itoh";
      };
      harvest.enable = true;
    };

    workstation = {
      wsl = {
        nameservers = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        extraDrives = [ "G:" ];
        windowsConfig = {
          memoryGiB = 48;
          processors = 12;
          swapGiB = 16;
        };
      };
      storage = {
        vhd.sizeGiB = 800;
        journal.maximumGiB = 4;
      };
      nix = {
        maxJobs = 4;
        cores = 3;
        minimumFreeGiB = 32;
        targetFreeGiB = 64;
      };
      memory.user = {
        hostReservePercent = 18;
        swapMaxPercent = 70;
      };
    };
  };
}
