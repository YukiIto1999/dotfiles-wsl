{
  config,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  launcherName = "wslview";
  windowsCommand = "/mnt/c/Windows/System32/cmd.exe";
  wslview = pkgs.writeShellScriptBin launcherName ''
    exec ${windowsCommand} /c start "" "$1" 2>/dev/null
  '';
in
{
  config.wsl = {
    enable = true;
    defaultUser = cfg.username;
    useWindowsDriver = true;

    # 再起動で失われる binfmt WSLInterop の再登録
    interop.register = true;

    wslConf = {
      boot.systemd = true;
      interop.appendWindowsPath = false;
    };
  };

  config.environment.systemPackages = [ wslview ];
}
