{
  config,
  pkgs,
  lib,
  pluginSources,
  ...
}:

let
  cfg = config.dotfiles.host;
  launcherName = "wslview";
  windowsCommand = "/mnt/c/Windows/System32/cmd.exe";
  wslview = pkgs.writeShellScriptBin launcherName ''
    exec ${windowsCommand} /c start "" "$1" 2>/dev/null
  '';
  binaryCaches = import ./assets/nix-caches.nix;
  stabilityContract =
    let
      gibibyte = 1073741824;
      observationTimeoutSeconds = 10;
      zramAlgorithm = "lzo-rle";
      zramMemoryPercent = 25;
      zramPriority = 100;
      minimumSwapGiB = 8;
      maximumJournalGiB = 4;
      windowsDrive = "D:";
      homeManagerServiceName = "home-manager-${cfg.username}";
    in
    rec {
      timeoutSeconds = observationTimeoutSeconds;
      systemGeneration = {
        currentPath = "/run/current-system";
        requiredPath = "/nix/var/nix/profiles/system";
        resolution = "canonical";
      };
      swap = {
        minimumTotalBytes = minimumSwapGiB * gibibyte;
        requireZram = true;
        zramAboveDisk = true;
        zram = {
          algorithm = zramAlgorithm;
          priority = zramPriority;
          size = "${toString zramMemoryPercent} / 100 * ram";
        };
      };
      rootFilesystem = {
        path = "/";
        metric = "used-percent";
        warning = 85;
        failure = 95;
      };
      windows = {
        drive = windowsDrive;
        powershellCommand = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
        metric = "free-percent";
        warning = 15;
        failure = 10;
      };
      journal = {
        storage = "persistent";
        maximumBytes = maximumJournalGiB * gibibyte;
        systemMaxUse = "${toString maximumJournalGiB}G";
        maximumRetention = "30day";
      };
      nixGc = {
        timerName = "nix-gc";
        serviceName = "nix-gc";
        settings = {
          automatic = true;
          dates = "weekly";
          persistent = true;
          options = "--delete-older-than 14d";
        };
      };
      fstrim = {
        timerName = "fstrim";
        serviceName = "fstrim";
        interval = "weekly";
        virtualizationCondition = [
          ""
          "wsl"
        ];
      };
      homeManager = {
        serviceName = homeManagerServiceName;
        unit = "${homeManagerServiceName}.service";
        restart = {
          warningAt = 5;
          failureAt = 20;
        };
      };
      observations =
        let
          common = checkId: resourceKey: failureMessage: {
            inherit checkId resourceKey failureMessage;
            inherit timeoutSeconds;
          };
        in
        {
          "host/system-generation" =
            common "system-generation" null "could not resolve the current system generation"
            // {
              kind = "path-match";
              inherit (systemGeneration) currentPath requiredPath resolution;
            };
          "host/swap" =
            common "resource/swap" "swap"
              "swap must include ${swap.zram.algorithm} zram above any disk swap with at least ${toString minimumSwapGiB} GiB total"
            // {
              kind = "swap-policy";
              inherit (swap) minimumTotalBytes requireZram zramAboveDisk;
              requiredZramAlgorithm = swap.zram.algorithm;
            };
          "host/root-filesystem" =
            common "resource/root-filesystem" "rootFilesystem" "could not observe root filesystem utilization"
            // {
              kind = "filesystem-threshold";
              inherit (rootFilesystem)
                path
                metric
                warning
                failure
                ;
            };
          "host/windows-d-drive" =
            common "resource/windows-d-drive" "windowsDDrive" "could not observe Windows D drive free space"
            // {
              kind = "numeric-command-threshold";
              command = windowsDriveObservation;
              inherit (windows)
                metric
                warning
                failure
                ;
            };
          "host/journald" = common "resource/journald" "journald" "could not observe journald disk usage" // {
            kind = "journal-size";
            inherit (journal) maximumBytes;
          };
          "host/nix-gc" =
            common "maintenance/${nixGc.timerName}.timer" null
              "${nixGc.timerName}.timer or its service is not operational"
            // {
              kind = "systemd-timer";
              timer = "${nixGc.timerName}.timer";
              service = "${nixGc.serviceName}.service";
              unitFileStates = [
                "enabled"
                "enabled-runtime"
              ];
              activeStates = [ "active" ];
              serviceResults = [ "success" ];
            };
          "host/fstrim" =
            common "maintenance/${fstrim.timerName}.timer" null
              "${fstrim.timerName}.timer or its service is not operational"
            // {
              kind = "systemd-timer";
              timer = "${fstrim.timerName}.timer";
              service = "${fstrim.serviceName}.service";
              unitFileStates = [
                "enabled"
                "enabled-runtime"
              ];
              activeStates = [ "active" ];
              serviceResults = [ "success" ];
            };
          "host/home-manager" = common "home-manager" null "${homeManager.unit} is not operational" // {
            kind = "systemd-service";
            inherit (homeManager) unit;
            loadStates = [ "loaded" ];
            activeStates = [ "active" ];
            results = [ "success" ];
          };
          "host/home-manager-restart" =
            common "restart/service/${homeManager.unit}" null
              "could not observe restart count for ${homeManager.unit}"
            // {
              kind = "restart-counter";
              sourceKind = "systemd-service";
              target = homeManager.unit;
              inherit (homeManager.restart) warningAt failureAt;
            };
        };
    };
  windowsDriveObservation = import ./package.nix {
    inherit pkgs lib;
    inherit (stabilityContract.windows) drive powershellCommand;
    inherit (stabilityContract) timeoutSeconds;
  };
  zramGenerator = "${pkgs.zram-generator}/lib/systemd/system-generators/zram-generator";
  zramSetup = pkgs.writeShellScript "dotfiles-zram-setup" ''
    set -euo pipefail

    ${lib.getExe' pkgs.kmod "modprobe"} zram num_devices=1
    test -b /dev/zram0
    ${zramGenerator} --setup-device zram0
    ${lib.getExe' pkgs.util-linux "swapon"} --priority ${toString stabilityContract.swap.zram.priority} /dev/zram0
  '';
  zramTeardown = pkgs.writeShellScript "dotfiles-zram-teardown" ''
    set -euo pipefail

    if ${lib.getExe pkgs.gnugrep} -q '^/dev/zram0[[:space:]]' /proc/swaps; then
      ${lib.getExe' pkgs.util-linux "swapoff"} /dev/zram0
    fi
    if test -e /sys/block/zram0/reset; then
      ${zramGenerator} --reset-device zram0
    fi
  '';
in
{
  options.dotfiles.host = {
    username = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "この host の主 user。WSL の既定 user でもある。";
    };

    homeDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "主 user の home。username から導く。";
    };

    dotfilesDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.homeDir}/dotfiles-wsl";
      description = "out-of-store symlink と script が参照する checkout の絶対パス。";
    };

    binaryCaches = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            substituter = lib.mkOption { type = lib.types.str; };
            publicKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      readOnly = true;
      internal = true;
      description = "Nix が利用する binary cache の型付き contract。";
    };
  };

  config.dotfiles.host = {
    inherit binaryCaches;
    homeDir = "/home/${cfg.username}";
  };
  config.dotfiles.observations = stabilityContract.observations;

  config.system.stateVersion = "25.11";

  # Home Manager の activation は複数 unit の資材を配備する横断の入口

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

  config.environment.localBinInPath = true;
  config.programs.nix-ld.enable = true;

  config.nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = map (cache: cache.substituter) binaryCaches;
    trusted-public-keys = map (cache: cache.publicKey) binaryCaches;
    trusted-users = [
      "root"
      cfg.username
    ];
  };

  # 常時起動でない WSL で取りこぼした GC を次回起動で補完
  config.nix.gc = stabilityContract.nixGc.settings;
  config.nix.optimise.automatic = true;

  # zram-generator は WSL を container と判定して unit 生成を省略するため、
  # 設定と device setup は再利用し、lifecycle だけを専用 service で接続する
  config.zramSwap.enable = false;
  config.services.zram-generator = {
    enable = true;
    settings.zram0 = {
      compression-algorithm = stabilityContract.swap.zram.algorithm;
      swap-priority = stabilityContract.swap.zram.priority;
      zram-size = stabilityContract.swap.zram.size;
    };
  };
  config.systemd.services.dotfiles-zram-swap = {
    description = "Create compressed swap on /dev/zram0 under WSL";
    wantedBy = [ "swap.target" ];
    before = [
      "swap.target"
      "shutdown.target"
    ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = zramSetup;
      ExecStopPost = zramTeardown;
    };
  };

  # 障害履歴を残しつつ、長期稼働時の journal に明示的な上限を設ける
  config.services.journald = {
    storage = stabilityContract.journal.storage;
    extraConfig = ''
      SystemMaxUse=${stabilityContract.journal.systemMaxUse}
      MaxRetentionSec=${stabilityContract.journal.maximumRetention}
    '';
  };

  # util-linux の unit 本体、ExecStart、schedule は再利用し、WSL で失敗する
  # vendor condition だけを drop-in で置き換える
  config.services.fstrim.interval = stabilityContract.fstrim.interval;
  config.systemd.services.${stabilityContract.fstrim.serviceName} = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionVirtualization = stabilityContract.fstrim.virtualizationCondition;
  };
  config.systemd.timers.${stabilityContract.fstrim.timerName} = {
    overrideStrategy = "asDropin";
    unitConfig.ConditionVirtualization = stabilityContract.fstrim.virtualizationCondition;
  };

  # crates.io が curl 既定 UA を 403 拒否するため指定する許可 UA
  config.systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";

  config.fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
    ];
    fontconfig = {
      enable = true;
      defaultFonts = {
        serif = [
          "Noto Serif CJK JP"
          "Noto Serif"
        ];
        sansSerif = [
          "Noto Sans CJK JP"
          "Noto Sans"
        ];
        monospace = [
          "Noto Sans Mono CJK JP"
          "Noto Sans Mono"
        ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  # docker group は containers/module.nix が追加
  config.users.users.${cfg.username} = {
    isNormalUser = true;
    home = cfg.homeDir;
    extraGroups = [ "wheel" ];
  };

  config.environment.systemPackages = [ wslview ];

  config.home-manager.useGlobalPkgs = true;
  config.home-manager.useUserPackages = true;
  config.home-manager.backupFileExtension = "hm-back";
  config.home-manager.extraSpecialArgs = { inherit pluginSources; };

  config.home-manager.users.${cfg.username} = _: {
    home.username = cfg.username;
    home.homeDirectory = cfg.homeDir;
    home.stateVersion = "25.11";

    home.sessionVariables.BROWSER = "wslview";
    home.sessionPath = [ "$HOME/.local/bin" ];

    programs =
      lib.genAttrs
        [
          "gh"
          "bash"
          "fzf"
          "zoxide"
          "bat"
          "eza"
        ]
        (_: {
          enable = true;
        })
      // {
        direnv = {
          enable = true;
          enableBashIntegration = true;
          nix-direnv.enable = true;
        };
      };
  };
}
