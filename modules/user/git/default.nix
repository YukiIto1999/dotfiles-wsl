{ config, ... }:

let
  cfg = config.my;

  mkGitHook = name: {
    source     = ./hooks + "/${name}";
    executable = true;
  };
in
{
  home-manager.users.${cfg.username} = { config, lib, osConfig, ... }:
    let
      inherit (osConfig) my;
    in
    {
      programs.git = {
        enable = true;
        settings = {
          init.defaultBranch  = "main";
          pull.rebase         = false;
          core.excludesFile   = "~/.config/git/ignore";
          core.hooksPath      = "~/.config/git/hooks";
          merge.conflictstyle = "diff3";
          include.path        = "${my.homeDir}/.config/git/identity.conf";
        };
        includes = lib.optionals (my.workIdentity != null) [
          {
            condition = "gitdir:${my.workIdentity}";
            path      = "${my.homeDir}/.config/git/work-identity.conf";
          }
        ];
      };

      programs.delta = {
        enable               = true;
        enableGitIntegration = true;
        options = {
          navigate     = true;
          side-by-side = true;
        };
      };

      home.file = {
        ".config/git/ignore".source    = config.lib.file.mkOutOfStoreSymlink "${my.dotfilesDir}/modules/user/git/ignore";
        ".config/git/hooks/pre-commit" = mkGitHook "pre-commit";
        ".config/git/hooks/commit-msg" = mkGitHook "commit-msg";
      };
    };
}
