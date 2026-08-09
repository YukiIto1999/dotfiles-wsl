{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../../commands/impl/mk-command.nix { inherit config lib pkgs; };

  mkGitHook = name: {
    source = ./assets/hooks + "/${name}";
    executable = true;
  };

  agentResource = mkCommand {
    name = "dotfiles-agent-resource";
    src = ./impl/agent-resource.sh;
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      git
      jq
      util-linux
    ];
    vars.gitCommand = lib.escapeShellArg (lib.getExe pkgs.git);
  };

  agentWorktree = mkCommand {
    name = "dotfiles-agent-worktree";
    src = ./impl/agent-worktree.sh;
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      util-linux
    ];
    vars = {
      gitCommand = lib.escapeShellArg (lib.getExe pkgs.git);
      resourceCommand = lib.escapeShellArg (lib.getExe agentResource);
    };
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
    stateRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "agent が所有する session と linked worktree ledger の state root。";
    };
    agentResource = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "agent session resource ledger と reaper の command package。";
    };
    agentWorktree = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "linked worktree を生成して ownership ledger へ登録する command package。";
    };
  };

  # secret を差し込んで identity を組む sops が読む template
  config.dotfiles.toolchain.git.identityTemplate = ./assets/identity.conf;
  config.dotfiles.toolchain.git.stateRoot = "~/.local/state/dotfiles-wsl/agent-resources";
  config.dotfiles.toolchain.git.agentResource = agentResource;
  config.dotfiles.toolchain.git.agentWorktree = agentWorktree;

  config.dotfiles.commands = { inherit agentResource agentWorktree; };

  config.systemd.services.dotfiles-agent-resource-reaper = {
    description = "Reap inactive agent-owned linked worktrees";
    serviceConfig = {
      Type = "oneshot";
      User = cfg.host.username;
      Environment = "HOME=${cfg.host.homeDir}";
      UMask = "0077";
      ExecStart = "${lib.getExe agentResource} reap";
    };
  };

  config.systemd.timers.dotfiles-agent-resource-reaper = {
    description = "Hourly agent resource ownership reaper";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      Unit = "dotfiles-agent-resource-reaper.service";
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
