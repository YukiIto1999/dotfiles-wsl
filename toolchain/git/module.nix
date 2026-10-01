{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  homeRelativePath = lib.types.addCheck lib.types.str (
    value:
    value != ""
    && builtins.match "[^[:cntrl:]]*" value != null
    && !lib.hasPrefix "/" value
    && !lib.hasSuffix "/" value
    && builtins.all (segment: segment != "" && segment != "." && segment != "..") (
      lib.splitString "/" value
    )
  );

  hooks = import ./package.nix {
    inherit lib pkgs;
    verificationEntry = cfg.toolchain.verification.entry;
    # T2 の時間予算は architecture-standard の段の定義に合わせる
    pushBudgetSeconds = 15 * 60;
  };

  credentialTokenFile = pkgs.writeShellApplication {
    name = "git-credential-token-file";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./assets/credential-token-file;
  };
  # gh の helper は active user の token しか返さない。primary 以外の account が担当する
  # owner は URL の path で切り分け、その account の token file を返す helper に替える
  ownerCredentials = lib.concatMapAttrs (
    account: owners:
    lib.genAttrs (map (owner: "https://github.com/${owner}") owners) (_: {
      helper = [
        ""
        "${lib.getExe credentialTokenFile} ${
          lib.escapeShellArg config.sops.secrets."accounts/${account}/token".path
        }"
      ];
    })
  ) cfg.identity.github.owners;
in
{
  options.dotfiles.toolchain.git = {
    workIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/projects/business/";
      description = "work 用 git identity を選ぶ gitdir glob。null で無効。";
    };
    identity = {
      template = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        internal = true;
        description = "sops template が利用する Git identity source。";
      };
      destinations = {
        default = lib.mkOption {
          type = homeRelativePath;
          readOnly = true;
          internal = true;
          description = "default Git identity の home-relative path。";
        };
        work = lib.mkOption {
          type = homeRelativePath;
          readOnly = true;
          internal = true;
          description = "work Git identity の home-relative path。";
        };
      };
    };
  };

  # Git 構文と生成先は consumer である toolchain/git が一度だけ決める。
  config.dotfiles.toolchain.git.identity = {
    template = ./assets/identity.conf;
    destinations = {
      default = ".config/git/identity.conf";
      work = ".config/git/work-identity.conf";
    };
  };

  config.home-manager.users.${cfg.workstation.username} =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      inherit (osConfig) dotfiles;
    in
    {
      programs.git = {
        enable = true;
        settings = {
          init.defaultBranch = "main";
          pull.rebase = false;
          core.excludesFile = "~/.config/git/ignore";
          # 全 repository の hook をここの dispatcher が受け、信頼した repository の `.githooks/` へつなぐ。
          # repository が hooksPath を上書きすると、dotfiles の検査ごと外れる
          core.hooksPath = "~/.config/git/hooks";
          merge.conflictstyle = "diff3";
          include.path = "${dotfiles.workstation.homeDir}/${dotfiles.toolchain.git.identity.destinations.default}";
          # git は URL に一致した section の helper を file の順に積み、空の値でそれまでを捨てる。
          # subsection は名前順に並ぶので、owner の section は host 全体の gh の section より後に来る
          credential = ownerCredentials;
        };
        includes = lib.optionals (dotfiles.toolchain.git.workIdentity != null) [
          {
            condition = "gitdir:${dotfiles.toolchain.git.workIdentity}";
            path = "${dotfiles.workstation.homeDir}/${dotfiles.toolchain.git.identity.destinations.work}";
          }
        ];
      };

      programs.delta = {
        enable = true;
        enableGitIntegration = true;
        options = {
          navigate = true;
          side-by-side = true;
        };
      };

      home.file = {
        ".config/git/ignore".source =
          config.lib.file.mkOutOfStoreSymlink "${dotfiles.workstation.dotfilesDir}/toolchain/git/assets/ignore";
      }
      // lib.mapAttrs' (
        name: hook:
        lib.nameValuePair ".config/git/hooks/${name}" {
          source = lib.getExe hook;
          executable = true;
        }
      ) hooks;
    };
}
