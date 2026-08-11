{
  config,
  lib,
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

  mkGitHook = name: {
    source = ./assets/hooks + "/${name}";
    executable = true;
  };
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

  config.home-manager.users.${cfg.host.username} =
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
          core.hooksPath = "~/.config/git/hooks";
          merge.conflictstyle = "diff3";
          include.path = "${dotfiles.host.homeDir}/${dotfiles.toolchain.git.identity.destinations.default}";
        };
        includes = lib.optionals (dotfiles.toolchain.git.workIdentity != null) [
          {
            condition = "gitdir:${dotfiles.toolchain.git.workIdentity}";
            path = "${dotfiles.host.homeDir}/${dotfiles.toolchain.git.identity.destinations.work}";
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
          config.lib.file.mkOutOfStoreSymlink "${dotfiles.host.dotfilesDir}/toolchain/git/assets/ignore";
        ".config/git/hooks/pre-commit" = mkGitHook "pre-commit";
        ".config/git/hooks/commit-msg" = mkGitHook "commit-msg";
      };
    };
}
