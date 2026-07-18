{ config, pkgs, ... }:

let
  launcherName = "wslview";
  windowsCommand = "/mnt/c/Windows/System32/cmd.exe";
  wslview = pkgs.writeShellScriptBin launcherName ''
    exec ${windowsCommand} /c start "" "$1" 2>/dev/null
  '';
in
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
  environment.systemPackages = [ wslview ];
  programs.nix-ld.enable = true;

  my.doctor.wslInterop = {
    inherit launcherName windowsCommand;
    launcherPath = "/run/current-system/sw/bin/${launcherName}";
    launcherSource = "${wslview}/bin/${launcherName}";
  };
}
