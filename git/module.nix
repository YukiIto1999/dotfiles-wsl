{ config, lib, ... }:

let
  cfg = config.my;

  mkGitHook = name: {
    source = ./assets/hooks + "/${name}";
    executable = true;
  };
in
{
  options.my.git.workIdentity = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "~/projects/business/";
    description = "work 用 git identity を選ぶ gitdir glob。null で無効。";
  };

  # secret を差し込んで identity を組む sops が読む template
  config.my.contract.git.identityTemplate = ./assets/identity.conf;

  config.home-manager.users.${cfg.username} =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      inherit (osConfig) my;
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
          include.path = "${my.homeDir}/.config/git/identity.conf";
        };
        includes = lib.optionals (my.git.workIdentity != null) [
          {
            condition = "gitdir:${my.git.workIdentity}";
            path = "${my.homeDir}/.config/git/work-identity.conf";
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
          config.lib.file.mkOutOfStoreSymlink "${my.dotfilesDir}/git/assets/ignore";
        ".config/git/hooks/pre-commit" = mkGitHook "pre-commit";
        ".config/git/hooks/commit-msg" = mkGitHook "commit-msg";
      };
    };
}
