{ config, ... }:

# WSL integration. NixOS-WSL supplies WSLg, interop and the Windows driver mount.
{
  wsl = {
    enable = true;
    defaultUser = config.my.username;
    useWindowsDriver = true;

    # 再起動で失われる binfmt WSLInterop の再登録
    interop.register = true;

    wslConf = {
      boot.systemd = true;
      interop.appendWindowsPath = false;
    };
  };

  environment.localBinInPath = true;
  programs.nix-ld.enable = true;
}
