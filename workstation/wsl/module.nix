{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles.workstation;
  inherit (cfg) wsl;
  wslview = import ./package.nix {
    inherit pkgs lib;
    inherit (wsl) powershellCommand;
  };
  windowsConfigTemplate = ''
    [wsl2]
    defaultVhdSize=${toString cfg.storage.vhd.sizeGiB}GB
  ''
  + lib.optionalString (
    wsl.windowsConfig.memoryGiB != null
  ) "memory=${toString wsl.windowsConfig.memoryGiB}GB\n"
  + lib.optionalString (
    wsl.windowsConfig.processors != null
  ) "processors=${toString wsl.windowsConfig.processors}\n"
  + lib.optionalString (
    wsl.windowsConfig.swapGiB != null
  ) "swap=${toString wsl.windowsConfig.swapGiB}GB\n"
  + ''

    [experimental]
    sparseVhd=${lib.boolToString cfg.storage.vhd.sparse}
  '';
  wslConfig = pkgs.writeShellApplication {
    name = "dotfiles-wsl-config";
    text = ''
      if [[ $# == 1 && $1 == --help ]]; then
        printf '%s\n' 'Usage: dotfiles-wsl-config' \
          'Print this host .wslconfig template without changing Windows files or running WSL commands.'
        exit 0
      fi
      if [[ $# != 0 ]]; then
        printf '%s\n' 'Usage: dotfiles-wsl-config' >&2
        exit 2
      fi
      printf '%s' ${lib.escapeShellArg windowsConfigTemplate}
    '';
  };

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
    "uname"
    "uniq"
    "wc"
    "whoami"
  ];
in
{
  options.dotfiles.workstation.wsl = {
    distroName = lib.mkOption {
      type = lib.types.str;
      default = "NixOS";
      description = "Windows に登録した WSL distribution 名";
    };
    powershellCommand = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
      description = "Windows 相互操作に使用する PowerShell executable の絶対 path";
    };
    nameservers = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      # WSL の DNS tunneling の受付。Windows の DNS client へ hvsocket で渡すため NAT の UDP を通らず、Windows と VPN の DNS 設定に従う
      default = [ "10.255.255.254" ];
      description = "systemd-resolved が先頭から使い、応答が無ければ次へ切り替える上流 resolver の一覧";
    };
    extraDrives = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Z]:");
      default = [ ];
      example = [ "G:" ];
      description = "/mnt の drive letter 配下へ追加する非阻害 automount の Windows drive";
    };
    windowsConfig = {
      memoryGiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Windows .wslconfig template の VM memory 上限 GiB null は WSL 既定";
      };
      processors = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Windows .wslconfig template の VM processor 数 null は WSL 既定";
      };
      swapGiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Windows .wslconfig template の disk swap 容量 GiB null は WSL 既定";
      };
    };
  };

  config.assertions = [
    {
      assertion =
        wsl.distroName != "" && !(lib.hasInfix "\n" wsl.distroName) && !(lib.hasInfix "\r" wsl.distroName);
      message = "WSL distroName must be a non-empty single line";
    }
    {
      assertion = builtins.length wsl.extraDrives == builtins.length (lib.unique wsl.extraDrives);
      message = "WSL extraDrives must not contain duplicate drives";
    }
    {
      assertion =
        wsl.windowsConfig.processors == null
        || cfg.nix.maxJobs * cfg.nix.cores <= wsl.windowsConfig.processors;
      message = "Nix maxJobs * cores must not exceed the declared WSL processor count";
    }
  ];

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
      # /etc/resolv.conf は systemd-resolved の stub が持つ
      network.generateResolvConf = false;
    };
  };

  # WSLは各起動要求をsystemd user sessionへ同期する。自動終了後の次回起動でも
  # user managerとruntime directoryを先に確立できるよう、両方を宣言的に維持する。
  config.users.users.${cfg.username}.linger = true;
  config.users.users.root.linger = true;

  config.fileSystems = builtins.listToAttrs (
    map (drive: {
      name = "/mnt/${lib.toLower (lib.substring 0 1 drive)}";
      value = {
        device = drive;
        fsType = "drvfs";
        options = [
          "rw"
          "nofail"
          "x-systemd.automount"
          "x-systemd.mount-timeout=10s"
        ];
      };
    }) wsl.extraDrives
  );

  # WSL の NAT は新しい flow の最初の packet を時々落とし（2026-11-27 の計測で 0.2〜0.8%）、glibc はその度に 5 秒待っていた。
  # nsncd はキャッシュしないので、キャッシュする systemd-resolved を前に置き、上流は NAT を通らない WSL の DNS tunneling を先頭にする
  config.networking.nameservers = wsl.nameservers;
  config.services.resolved = {
    enable = true;
    settings.Resolve = {
      # NAT の内側には応答する相手がいないので、multicast の名前解決は送らない
      LLMNR = false;
      MulticastDNS = false;
    };
  };

  config.environment.systemPackages = [
    wslview
    wslConfig
  ];
}
