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
  config.nix.gc = {
    automatic = true;
    dates = "weekly";
    persistent = true;
    options = "--delete-older-than 14d";
  };
  config.nix.optimise.automatic = true;

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
