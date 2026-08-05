{ config, lib, ... }:

let
  cfg = config.dotfiles;

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
    identityTemplate = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      description = "sops template が利用する Git identity source。";
    };
  };

  # secret を差し込んで identity を組む sops が読む template
  config.dotfiles.toolchain.git.identityTemplate = ./assets/identity.conf;

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
          include.path = "${dotfiles.host.homeDir}/.config/git/identity.conf";
        };
        includes = lib.optionals (dotfiles.toolchain.git.workIdentity != null) [
          {
            condition = "gitdir:${dotfiles.toolchain.git.workIdentity}";
            path = "${dotfiles.host.homeDir}/.config/git/work-identity.conf";
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
