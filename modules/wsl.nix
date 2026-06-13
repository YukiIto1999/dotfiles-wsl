{ config, pkgs, ... }:

let
  # cmd.exe 経由の最小 wslview
  wslview = pkgs.writeShellScriptBin "wslview" ''
    exec /mnt/c/Windows/System32/cmd.exe /c start "" "$1" 2>/dev/null
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
}
