{
  dotfiles.capabilities.enabled = [
    "project-memory"
    "web-content"
    "web-discovery"
  ];
  # 既存の日誌の file 名が Windows のコンピューター名のため host ID の既定値は不可
  dotfiles.agents.journal.machineName = "y-itoh";
}
