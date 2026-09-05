{
  config,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  launcherName = "wslview";
  windowsCommand = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
  wslview = pkgs.writeShellScriptBin launcherName ''
    if [ "$#" -eq 0 ]; then
      exit 0
    fi
    target=$1
    escaped="''${target//\'/\'\'}"
    exec ${windowsCommand} -NoProfile -Command "Start-Process '$escaped'"
  '';

  # Orca などの外部ツールが非ログインシェルで呼び出す標準 POSIX / coreutils コマンド
  coreutilsBins = [
    "base64"
    "basename"
    "cat"
    "chmod"
    "cp"
    "cut"
    "date"
    "dirname"
    "env"
    "false"
    "head"
    "id"
    "ln"
    "ls"
    "mkdir"
    "mktemp"
    "mv"
    "printenv"
    "pwd"
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "sleep"
    "sort"
    "tail"
    "tee"
    "test"
    "touch"
    "tr"
    "true"
    "uname"
    "uniq"
    "wc"
    "whoami"
  ];
in
{
  config.wsl = {
    enable = true;
    defaultUser = cfg.username;
    useWindowsDriver = true;

    # 再起動で失われる binfmt WSLInterop の再登録
    interop.register = true;

    # 非ログイン bash でも coreutils / POSIX コマンドが /bin で探索できるようにリンク
    extraBin =
      (map (name: {
        inherit name;
        src = "${pkgs.coreutils}/bin/${name}";
      }) coreutilsBins)
      ++ [
        {
          name = "grep";
          src = "${pkgs.gnugrep}/bin/grep";
        }
        {
          name = "find";
          src = "${pkgs.findutils}/bin/find";
        }
        {
          name = "xargs";
          src = "${pkgs.findutils}/bin/xargs";
        }
        {
          name = "sed";
          src = "${pkgs.gnused}/bin/sed";
        }
        {
          name = "awk";
          src = "${pkgs.gawk}/bin/awk";
        }
      ];

    wslConf = {
      boot.systemd = true;
      interop.appendWindowsPath = false;
    };
  };

  config.environment.systemPackages = [ wslview ];
}
