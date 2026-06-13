{ lib, osConfig, dotfilesAbs, symlink, ... }:

let
  inherit (osConfig) my;

  mkGitHook = name: {
    source     = ./nixos/.config/git/hooks + "/${name}";
    executable = true;
  };
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
    ".config/git/ignore".source    = symlink "${dotfilesAbs}/home/nixos/.config/git/ignore";
    ".config/git/hooks/pre-commit" = mkGitHook "pre-commit";
    ".config/git/hooks/commit-msg" = mkGitHook "commit-msg";
  };
}
