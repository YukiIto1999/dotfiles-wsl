{
  dotfiles.capabilities.enabled = [
    "project-memory"
    "security-assessment"
    "code-quality"
  ];
  # 既存の日誌の file 名が Windows のコンピューター名のため host ID の既定値は不可
  dotfiles.agents.journal.machineName = "y-itoh";
  dotfiles.agents.journal.enable = true;
  dotfiles.agents.memoryHarvest.enable = true;
  dotfiles.agents.slice = {
    memoryHighPercent = 65;
    memorySwapMaxPercent = 60;
  };
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
    workload = {
      hostReservePercent = 18;
      memorySwapMaxPercent = 70;
    };
    swap.minimumTotalGiB = 8;
  };
}
