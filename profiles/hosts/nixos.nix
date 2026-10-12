{
  dotfiles.capabilities.enabled = [
    "project-memory"
  ];
  # 既存の日誌の file 名が Windows のコンピューター名のため host ID の既定値は不可
  dotfiles.agents.journal.machineName = "y-itoh";
  dotfiles.agents.journal.enable = true;
  dotfiles.agents.memoryHarvest.enable = true;
  dotfiles.workstation = {
    wsl = {
      nameservers = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      extraDrives = [ "G:" ];
      windowsConfig = {
        memoryGiB = 40;
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
    swap.minimumTotalGiB = 8;
  };
}
