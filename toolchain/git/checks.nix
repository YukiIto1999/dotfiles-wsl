{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  gitConfig = hostConfig.dotfiles.toolchain.git;
  missingCommand =
    name:
    pkgs.writeShellApplication {
      inherit name;
      text = "exit 127";
    };
  agentResource = gitConfig.agentResource or (missingCommand "dotfiles-agent-resource");
  agentWorktree = gitConfig.agentWorktree or (missingCommand "dotfiles-agent-worktree");
  substituteCommandVars = import ../../commands/impl/substitute-command-vars.nix;
  raceGit = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-race-git";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      real_git=${lib.escapeShellArg (lib.getExe pkgs.git)}
      if [[ ''${1-} == worktree && ''${2-} == add ]]; then
        set +e
        "$real_git" "$@"
        status=$?
        set -e
        if ((status == 0)) && [[ -n ''${DOTFILES_AGENT_TEST_ADD_READY-} \
          && -n ''${DOTFILES_AGENT_TEST_ADD_RELEASE-} ]]; then
          : >"$DOTFILES_AGENT_TEST_ADD_READY"
          while [[ ! -e $DOTFILES_AGENT_TEST_ADD_RELEASE ]]; do
            sleep 0.01
          done
        fi
        exit "$status"
      fi
      exec "$real_git" "$@"
    '';
  };
  raceAgentResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-race";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      git
      jq
      util-linux
    ];
    text = substituteCommandVars {
      gitCommand = lib.escapeShellArg (lib.getExe raceGit);
    } (builtins.readFile ./impl/agent-resource.sh);
  };
  raceAgentWorktree = pkgs.writeShellApplication {
    name = "dotfiles-agent-worktree-race";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      util-linux
    ];
    text = substituteCommandVars {
      gitCommand = lib.escapeShellArg (lib.getExe raceGit);
      resourceCommand = lib.escapeShellArg (lib.getExe raceAgentResource);
    } (builtins.readFile ./impl/agent-worktree.sh);
  };
  auditGit = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-audit-git";
    text = ''
      if [[ -n ''${DOTFILES_AGENT_TEST_GIT_LOG-} ]]; then
        {
          printf 'git'
          printf '\t%s' "$@"
          printf '\n'
        } >>"$DOTFILES_AGENT_TEST_GIT_LOG"
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == move \
        && -n ''${DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE-} \
        && ! -e ''${DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE} ]]; then
        set +e
        ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
        status=$?
        set -e
        if ((status == 0)); then
          : >"$DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE"
          printf 'late mutation\n' >"''${6}/late-untracked"
        fi
        exit "$status"
      fi
      exec ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
    '';
  };
  auditAgentResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-audit";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      git
      jq
      util-linux
    ];
    text = substituteCommandVars {
      gitCommand = lib.escapeShellArg (lib.getExe auditGit);
    } (builtins.readFile ./impl/agent-resource.sh);
  };
in
{
  agent-resource-contract =
    let
      reaper = hostConfig.systemd.services.dotfiles-agent-resource-reaper or null;
      timer = hostConfig.systemd.timers.dotfiles-agent-resource-reaper or null;
    in
    assert lib.assertMsg (
      gitConfig.stateRoot or null == "~/.local/state/dotfiles-wsl/agent-resources"
    ) "agent resource state root changed";
    assert lib.assertMsg (
      gitConfig ? agentResource && gitConfig ? agentWorktree
    ) "agent resource commands are missing";
    assert lib.assertMsg (
      lib.elem agentResource hostConfig.environment.systemPackages
      && lib.elem agentWorktree hostConfig.environment.systemPackages
    ) "agent resource commands must be on PATH";
    assert lib.assertMsg (reaper != null && timer != null) "agent resource reaper units are missing";
    assert lib.assertMsg (
      reaper.serviceConfig.Type == "oneshot"
    ) "agent resource reaper must be oneshot";
    assert lib.assertMsg (
      reaper.serviceConfig.User == hostConfig.dotfiles.host.username
    ) "agent resource reaper must run as the desktop user";
    assert lib.assertMsg (
      reaper.serviceConfig.ExecStart == "${lib.getExe agentResource} reap"
    ) "agent resource reaper command changed";
    assert lib.assertMsg (timer.wantedBy == [ "timers.target" ]) "agent resource timer is disabled";
    assert lib.assertMsg (
      timer.timerConfig == {
        OnCalendar = "hourly";
        Persistent = true;
        Unit = "dotfiles-agent-resource-reaper.service";
      }
    ) "agent resource timer must run hourly and persist missed runs";
    pkgs.runCommandLocal "check-agent-resource-contract" { } "touch $out";

  agent-resource-behavior =
    pkgs.runCommandLocal "check-agent-resource-behavior"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          git
          gnugrep
          jq
          util-linux
        ];
      }
      ''
        export RESOURCE=${lib.getExe agentResource}
        export WORKTREE=${lib.getExe agentWorktree}
        export REAL_GIT=${lib.getExe pkgs.git}
        export RACE_RESOURCE=${lib.getExe raceAgentResource}
        export RACE_WORKTREE=${lib.getExe raceAgentWorktree}
        export AUDIT_RESOURCE=${lib.getExe auditAgentResource}
        export TEST_BASH=${lib.getExe pkgs.bash}
        ${lib.getExe pkgs.bash} ${./impl/tests/agent-resources.sh}
        touch $out
      '';
}
