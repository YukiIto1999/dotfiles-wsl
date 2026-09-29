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
      network.generateResolvConf = false;
    };
  };

  # WSLは各起動要求をsystemd user sessionへ同期する。自動終了後の次回起動でも
  # user managerとruntime directoryを先に確立できるよう、両方を宣言的に維持する。
  config.users.users.${cfg.username}.linger = true;
  config.users.users.root.linger = true;

  # モデルを退避した Windows の G: は、Google Drive が未起動でも WSL の起動を妨げないよう
  # 初回アクセス時にだけ mount する。モデル cache の symlink はこの安定した mount point を参照する。
  config.fileSystems."/mnt/g" = {
    device = "G:";
    fsType = "drvfs";
    options = [
      "rw"
      "nofail"
      "x-systemd.automount"
      "x-systemd.mount-timeout=10s"
    ];
  };

  # WSL が生成する resolv.conf は NAT DNS proxy 10.255.255.254 だけを指すが、この proxy は A も AAAA も
  # 応答しない時間帯があり、nix の fetch が名前解決に失敗する。生成を止めて公開 resolver を固定する。
  config.networking.nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  config.environment.systemPackages = [ wslview ];
}
