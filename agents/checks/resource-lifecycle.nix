{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentConfig = hostConfig.dotfiles.agents;
  runtime = import ../package.nix {
    inherit lib pkgs;
    runtimeContract = runtimePackageContract;
  };
  sevenDayRuntime = import ../package.nix {
    inherit lib pkgs;
    runtimeContract = runtimePackageContract // {
      ledgerRetentionDays = 7;
    };
  };
  countingJq = pkgs.writeShellScriptBin "jq" ''
    counter=''${DOTFILES_AGENT_TEST_JQ_COUNTER:?}
    count=0
    if [[ -f $counter ]]; then
      IFS= read -r count <"$counter"
    fi
    [[ $count =~ ^[0-9]+$ ]] || exit 64
    printf '%s\n' "$((count + 1))" >"$counter"
    exec ${lib.getExe pkgs.jq} "$@"
  '';
  countingAgentResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-counting-jq";
    runtimeInputs = with pkgs; [
      countingJq
      coreutils
      gawk
      git
      util-linux
    ];
    text =
      builtins.replaceStrings
        [
          "@gitCommand@"
          "@ledgerRetentionDays@"
          "@stateRootRelative@"
          "@resourceStateRootRelative@"
        ]
        [
          (lib.escapeShellArg (lib.getExe pkgs.git))
          "30"
          runtimePackageContract.state.relativeStateRoot
          runtimePackageContract.state.relativeResourcesRoot
        ]
        (builtins.readFile ../impl/resource/agent-resource.sh);
  };
  controlledReadlink = pkgs.writeShellScriptBin "readlink" ''
    real_readlink=${pkgs.coreutils}/bin/readlink
    reference=''${!#}
    if [[ -n ''${DOTFILES_AGENT_TEST_PROC_REFERENCE-} \
      && $reference == "$DOTFILES_AGENT_TEST_PROC_REFERENCE" ]]; then
      case ''${DOTFILES_AGENT_TEST_PROC_MODE-} in
      denied) exit 13 ;;
      broken)
        if [[ ''${1-} == -e ]]; then
          exit 1
        fi
        printf '%s\n' /fixture-missing-process-reference
        exit 0
        ;;
      disappearing)
        if [[ ''${1-} != -e ]]; then
          count=0
          if [[ -f ''${DOTFILES_AGENT_TEST_PROC_COUNTER-} ]]; then
            read -r count <"$DOTFILES_AGENT_TEST_PROC_COUNTER"
          fi
          count=$((count + 1))
          printf '%s\n' "$count" >"$DOTFILES_AGENT_TEST_PROC_COUNTER"
          if ((count > 1)); then
            exit 1
          fi
        fi
        ;;
      esac
    fi
    exec "$real_readlink" "$@"
  '';
  controlledProcStat = pkgs.writeShellScriptBin "stat" ''
    if [[ $# -eq 4 && $1 == -c && $2 == %u && $3 == -- \
      && $4 == "/proc/''${DOTFILES_AGENT_TEST_PROC_OWNER_PID-}" ]]; then
      case ''${DOTFILES_AGENT_TEST_PROC_OWNER_MODE-} in
      denied) exit 13 ;;
      foreign)
        printf '%s\n' "$(( $(${pkgs.coreutils}/bin/id -u) + 1 ))"
        exit 0
        ;;
      esac
    fi
    exec ${pkgs.coreutils}/bin/stat "$@"
  '';
  controlledProcResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-proc-fixture";
    runtimeInputs = with pkgs; [
      controlledReadlink
      controlledProcStat
      coreutils
      gawk
      git
      jq
      util-linux
    ];
    text =
      builtins.replaceStrings
        [
          "@gitCommand@"
          "@ledgerRetentionDays@"
          "@stateRootRelative@"
          "@resourceStateRootRelative@"
        ]
        [
          (lib.escapeShellArg (lib.getExe pkgs.git))
          "30"
          runtimePackageContract.state.relativeStateRoot
          runtimePackageContract.state.relativeResourcesRoot
        ]
        (builtins.readFile ../impl/resource/agent-resource.sh);
  };
  controlledPruneRm = pkgs.writeShellScriptBin "rm" ''
    real_rm=${pkgs.coreutils}/bin/rm
    target=''${!#}
    expected="$HOME/${runtimePackageContract.state.relativeResourcesRoot}/sessions/''${DOTFILES_AGENT_TEST_PRUNE_SESSION-}.json"
    if [[ -n ''${DOTFILES_AGENT_TEST_PRUNE_LOCK-} \
      && $target == "$DOTFILES_AGENT_TEST_PRUNE_LOCK" \
      && ''${DOTFILES_AGENT_TEST_PRUNE_MODE-} == pause-lock-before ]]; then
      : >"$DOTFILES_AGENT_TEST_PRUNE_MARKER"
      while [[ ! -e $DOTFILES_AGENT_TEST_PRUNE_RELEASE ]]; do
        sleep 0.01
      done
      exec "$real_rm" "$@"
    fi
    if [[ -n ''${DOTFILES_AGENT_TEST_PRUNE_SESSION-} && $target == "$expected" ]]; then
      case ''${DOTFILES_AGENT_TEST_PRUNE_MODE-} in
      crash-after)
        "$real_rm" "$@"
        : >"$DOTFILES_AGENT_TEST_PRUNE_MARKER"
        kill -KILL "$PPID"
        exit 137
        ;;
      fail-once)
        if [[ ! -e $DOTFILES_AGENT_TEST_PRUNE_MARKER ]]; then
          : >"$DOTFILES_AGENT_TEST_PRUNE_MARKER"
          exit 75
        fi
        ;;
      esac
    fi
    exec "$real_rm" "$@"
  '';
  controlledPruneResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-prune-fixture";
    runtimeInputs = with pkgs; [
      controlledPruneRm
      coreutils
      gawk
      git
      jq
      util-linux
    ];
    text =
      builtins.replaceStrings
        [
          "@gitCommand@"
          "@ledgerRetentionDays@"
          "@stateRootRelative@"
          "@resourceStateRootRelative@"
        ]
        [
          (lib.escapeShellArg (lib.getExe pkgs.git))
          "30"
          runtimePackageContract.state.relativeStateRoot
          runtimePackageContract.state.relativeResourcesRoot
        ]
        (builtins.readFile ../impl/resource/agent-resource.sh);
  };
  overflowResource = runtime.mkAgentResource {
    name = "dotfiles-agent-resource-overflow-fixture";
    gitCommand = lib.getExe pkgs.git;
    retentionDays = 9223372036854775807;
  };
  raceGit = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-race-git";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      real_git=${lib.escapeShellArg (lib.getExe pkgs.git)}
      if [[ ''${1-} == worktree && ''${2-} == add ]]; then
        if [[ ''${DOTFILES_AGENT_TEST_FAIL_WORKTREE_ADD-} == 1 ]]; then
          exit 73
        fi
        if [[ -n ''${DOTFILES_AGENT_TEST_ADD_BEFORE_READY-} \
          && -n ''${DOTFILES_AGENT_TEST_ADD_BEFORE_RELEASE-} ]]; then
          printf '%s\n' "$BASHPID" >"$DOTFILES_AGENT_TEST_ADD_BEFORE_READY"
          while [[ ! -e $DOTFILES_AGENT_TEST_ADD_BEFORE_RELEASE ]]; do
            sleep 0.01
          done
        fi
        set +e
        "$real_git" "$@"
        status=$?
        set -e
        if ((status == 0)) && [[ -n ''${DOTFILES_AGENT_TEST_ADD_READY-} \
          && -n ''${DOTFILES_AGENT_TEST_ADD_RELEASE-} ]]; then
          printf '%s\n' "$BASHPID" >"$DOTFILES_AGENT_TEST_ADD_READY"
          while [[ ! -e $DOTFILES_AGENT_TEST_ADD_RELEASE ]]; do
            sleep 0.01
          done
        fi
        exit "$status"
      fi
      exec "$real_git" "$@"
    '';
  };
  raceAgentResource = runtime.mkAgentResource {
    name = "dotfiles-agent-resource-race";
    gitCommand = lib.getExe raceGit;
  };
  raceAgentWorktree = runtime.mkAgentWorktree {
    name = "dotfiles-agent-worktree-race";
    gitCommand = lib.getExe raceGit;
    resourceCommand = lib.getExe raceAgentResource;
  };
  addingPauseResource = pkgs.writeShellApplication {
    name = "dotfiles-agent-resource-adding-pause";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      real_resource=${lib.escapeShellArg (lib.getExe runtime.agentResource)}
      if [[ ''${1-} == record-worktree-add-identity \
        && ''${DOTFILES_AGENT_TEST_FAIL_ADD_IDENTITY-} == 1 ]]; then
        exit 71
      fi
      if [[ ''${1-} == record-worktree-add-identity \
        && -n ''${DOTFILES_AGENT_TEST_ADD_IDENTITY_READY-} \
        && -n ''${DOTFILES_AGENT_TEST_ADD_IDENTITY_RELEASE-} ]]; then
        set +e
        "$real_resource" "$@"
        status=$?
        set -e
        if ((status == 0)); then
          printf '%s\n' "$PPID" >"$DOTFILES_AGENT_TEST_ADD_IDENTITY_READY"
          while [[ ! -e $DOTFILES_AGENT_TEST_ADD_IDENTITY_RELEASE ]]; do
            sleep 0.01
          done
        fi
        exit "$status"
      fi
      exec "$real_resource" "$@"
    '';
  };
  addingPauseWorktree = runtime.mkAgentWorktree {
    name = "dotfiles-agent-worktree-adding-pause";
    gitCommand = lib.getExe pkgs.git;
    resourceCommand = lib.getExe addingPauseResource;
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
      if [[ ''${DOTFILES_AGENT_TEST_FAIL_GUESS_REMOTE_CONFIG-} == 1 \
        && ''${1-} == config && ''${2-} == --type=bool \
        && ''${3-} == --get && ''${4-} == worktree.guessRemote ]]; then
        exit 74
      fi
      if [[ -n ''${DOTFILES_AGENT_TEST_FAIL_REMOTE_REF_SCAN_STATUS-} \
        && ''${1-} == for-each-ref && ''${2-} == '--format=%(refname)' \
        && ''${3-} == refs/remotes/*/* ]]; then
        exit "$DOTFILES_AGENT_TEST_FAIL_REMOTE_REF_SCAN_STATUS"
      fi
      if [[ ''${1-} == -C \
        && ''${2-} == "''${DOTFILES_AGENT_TEST_FAIL_HEAD_PATH-}" \
        && ''${3-} == rev-parse && ''${4-} == --verify \
        && ''${5-} == 'HEAD^{commit}' ]]; then
        exit 74
      fi
      if [[ ''${1-} == -C \
        && ''${2-} == "''${DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_PATH-}" \
        && ''${3-} == rev-parse && ''${5-} == --git-common-dir \
        && -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_SAFE-} \
        && -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_MARKER-} \
        && ! -e ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_MARKER} ]]; then
        set +e
        common_dir=$(${lib.escapeShellArg (lib.getExe pkgs.git)} "$@")
        status=$?
        set -e
        if ((status == 0)); then
          ${lib.escapeShellArg (lib.getExe pkgs.git)} --git-dir="$common_dir" \
            worktree remove -- "$DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_PATH"
          ${lib.escapeShellArg (lib.getExe pkgs.git)} --git-dir="$common_dir" \
            worktree move -- "$DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_SAFE" \
            "$DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_PATH"
          : >"$DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_MARKER"
          printf '%s\n' "$common_dir"
        fi
        exit "$status"
      fi
      if [[ ''${1-} == -C \
        && ''${2-} == */.dotfiles-agent-quarantine.*/worktree \
        && ''${3-} == rev-parse && ''${4-} == --verify \
        && ''${5-} == 'HEAD^{commit}' \
        && -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_SAFE-} \
        && -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_MARKER-} \
        && ! -e ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_MARKER} ]]; then
        set +e
        head=$(${lib.escapeShellArg (lib.getExe pkgs.git)} "$@")
        status=$?
        set -e
        if ((status == 0)); then
          common_dir=$(${lib.escapeShellArg (lib.getExe pkgs.git)} -C "''${2}" \
            rev-parse --path-format=absolute --git-common-dir)
          ${lib.escapeShellArg (lib.getExe pkgs.git)} --git-dir="$common_dir" \
            worktree move -- "''${2}" "$DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_SAFE"
          ${lib.escapeShellArg (lib.getExe pkgs.git)} --git-dir="$common_dir" \
            worktree add --detach "''${2}" HEAD >/dev/null
          : >"$DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_MARKER"
          printf '%s\n' "$head"
        fi
        exit "$status"
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == move ]] \
        && { [[ -n ''${DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE-} \
          && ! -e ''${DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE} ]] \
          || [[ -n ''${DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_READY-} \
            && -n ''${DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_RELEASE-} ]] \
          || [[ -n ''${DOTFILES_AGENT_TEST_KILL_AFTER_MOVE-} \
            && ! -e ''${DOTFILES_AGENT_TEST_KILL_AFTER_MOVE} ]] \
          || [[ -n ''${DOTFILES_AGENT_TEST_TERM_AFTER_MOVE-} \
            && ! -e ''${DOTFILES_AGENT_TEST_TERM_AFTER_MOVE} ]] \
          || [[ -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_SAFE-} \
            && -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_MARKER-} \
            && ! -e ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_MARKER} ]]; }; then
        set +e
        ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
        status=$?
        set -e
        if ((status == 0)); then
          if [[ -n ''${DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE-} ]]; then
            : >"$DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE"
            printf 'late mutation\n' >"''${6}/late-untracked"
          fi
          if [[ -n ''${DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_READY-} ]]; then
            printf '%s\n' "''${6}" >"$DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_READY"
            while [[ ! -e $DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_RELEASE ]]; do
              sleep 0.01
            done
          fi
          if [[ -n ''${DOTFILES_AGENT_TEST_KILL_AFTER_MOVE-} ]]; then
            printf '%s\n' "''${6}" >"$DOTFILES_AGENT_TEST_KILL_AFTER_MOVE"
            kill -KILL "''${DOTFILES_AGENT_TEST_TRANSACTION_PARENT_PID:-$PPID}"
          fi
          if [[ -n ''${DOTFILES_AGENT_TEST_TERM_AFTER_MOVE-} ]]; then
            printf '%s\n' "''${6}" >"$DOTFILES_AGENT_TEST_TERM_AFTER_MOVE"
            kill -TERM "''${DOTFILES_AGENT_TEST_TRANSACTION_PARENT_PID:-$PPID}"
          fi
          if [[ -n ''${DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_SAFE-} ]]; then
            ${lib.escapeShellArg (lib.getExe pkgs.git)} "$1" worktree move -- \
              "''${6}" "$DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_SAFE"
            ${lib.escapeShellArg (lib.getExe pkgs.git)} "$1" worktree add --detach \
              "''${6}" HEAD
            : >"$DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_MARKER"
          fi
        fi
        exit "$status"
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == remove \
        && -n ''${DOTFILES_AGENT_TEST_BEFORE_REMOVE_READY-} \
        && -n ''${DOTFILES_AGENT_TEST_BEFORE_REMOVE_RELEASE-} ]]; then
        printf '%s\n' "''${5}" >"$DOTFILES_AGENT_TEST_BEFORE_REMOVE_READY"
        while [[ ! -e $DOTFILES_AGENT_TEST_BEFORE_REMOVE_RELEASE ]]; do
          sleep 0.01
        done
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == remove \
        && -n ''${DOTFILES_AGENT_TEST_BLOCK_REMOVE_READY-} \
        && -n ''${DOTFILES_AGENT_TEST_BLOCK_REMOVE_RELEASE-} ]]; then
        printf '%s\n' "$BASHPID" >"$DOTFILES_AGENT_TEST_BLOCK_REMOVE_READY"
        while [[ ! -e $DOTFILES_AGENT_TEST_BLOCK_REMOVE_RELEASE ]]; do
          sleep 0.01
        done
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == remove \
        && -n ''${DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_MARKER-} \
        && -n ''${DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_PARENT_PID-} ]]; then
        set +e
        ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
        status=$?
        set -e
        if ((status == 0)); then
          printf '%s\n' "''${5}" >"$DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_MARKER"
          kill -KILL "$DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_PARENT_PID"
        fi
        exit "$status"
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == remove \
        && -n ''${DOTFILES_AGENT_TEST_FAIL_REMOVE_ONCE-} \
        && ! -e $DOTFILES_AGENT_TEST_FAIL_REMOVE_ONCE ]]; then
        : >"$DOTFILES_AGENT_TEST_FAIL_REMOVE_ONCE"
        exit 1
      fi
      if [[ ''${1-} == --git-dir=* && ''${2-} == worktree && ''${3-} == remove \
        && -n ''${DOTFILES_AGENT_TEST_BLOCK_ROOT_AFTER_REMOVE_MARKER-} \
        && ! -e ''${DOTFILES_AGENT_TEST_BLOCK_ROOT_AFTER_REMOVE_MARKER} ]]; then
        set +e
        ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
        status=$?
        set -e
        if ((status == 0)); then
          quarantine_root=$(${pkgs.coreutils}/bin/dirname -- "''${5}")
          blocker="$quarantine_root/fixture-blocker"
          : >"$blocker"
          printf '%s\n' "$blocker" >"$DOTFILES_AGENT_TEST_BLOCK_ROOT_AFTER_REMOVE_MARKER"
        fi
        exit "$status"
      fi
      exec ${lib.escapeShellArg (lib.getExe pkgs.git)} "$@"
    '';
  };
  auditAgentResource = runtime.mkAgentResource {
    name = "dotfiles-agent-resource-audit";
    gitCommand = lib.getExe auditGit;
  };
  auditAgentWorktree = runtime.mkAgentWorktree {
    name = "dotfiles-agent-worktree-audit";
    gitCommand = lib.getExe auditGit;
    resourceCommand = lib.getExe runtime.agentResource;
  };
  homeDir = hostConfig.dotfiles.workstation.homeDir;
  runtimeContractSupport = import ./support/runtime-contract.nix {
    inherit homeDir;
  };
  inherit (runtimeContractSupport) runtimePackageContract;
in
{
  agent-resource-contract =
    let
      inherit (agentConfig) agentResource;
      inherit (agentConfig) agentWorktree;
      resourceSource = builtins.readFile ../impl/resource/agent-resource.sh;
      worktreeSource = builtins.readFile ../impl/resource/agent-worktree.sh;
      commandName =
        package:
        let
          mainProgram = package.meta.mainProgram or null;
        in
        if mainProgram == null then lib.getName package else mainProgram;
      commandOwnership =
        command: packages:
        let
          name = commandName command;
          owners = builtins.filter (package: commandName package == name) packages;
        in
        {
          inherit name;
          count = builtins.length owners;
          paths = map toString owners;
        };
      commandOwnershipDiagnostic =
        expected: ownership:
        "expected=${toString expected} command=${ownership.name} "
        + "count=${toString ownership.count} paths=${builtins.toJSON ownership.paths}";
      ownershipMatchesExpectedPackage =
        expected: ownership: ownership.count == 1 && ownership.paths == [ (toString expected) ];
      replacePackage =
        expected: replacement:
        map (
          package: if package == expected then replacement else package
        ) hostConfig.environment.systemPackages;
      duplicateAgentResource = pkgs.writeShellApplication {
        name = "dotfiles-agent-resource";
        text = "exit 0";
      };
      replacementAgentWorktree = pkgs.writeShellApplication {
        name = "dotfiles-agent-worktree";
        text = "exit 0";
      };
      duplicateResourcePackages = hostConfig.environment.systemPackages ++ [ duplicateAgentResource ];
      replacementResourcePackages = replacePackage agentResource duplicateAgentResource;
      replacementWorktreePackages = replacePackage agentWorktree replacementAgentWorktree;
      resourceOwnership = commandOwnership agentResource hostConfig.environment.systemPackages;
      worktreeOwnership = commandOwnership agentWorktree hostConfig.environment.systemPackages;
      duplicateResourceOwnership = commandOwnership agentResource duplicateResourcePackages;
      replacementResourceOwnership = commandOwnership agentResource replacementResourcePackages;
      replacementWorktreeOwnership = commandOwnership agentWorktree replacementWorktreePackages;
      expectedDuplicateResourceOwnerPaths = map toString [
        agentResource
        duplicateAgentResource
      ];
      expectedDuplicateResourceDiagnostic =
        "expected=${toString agentResource} command=dotfiles-agent-resource count=2 "
        + "paths=${builtins.toJSON expectedDuplicateResourceOwnerPaths}";
      expectedReplacementResourceDiagnostic =
        "expected=${toString agentResource} command=dotfiles-agent-resource count=1 "
        + "paths=${builtins.toJSON [ (toString duplicateAgentResource) ]}";
      expectedReplacementWorktreeDiagnostic =
        "expected=${toString agentWorktree} command=dotfiles-agent-worktree count=1 "
        + "paths=${builtins.toJSON [ (toString replacementAgentWorktree) ]}";
      reaper = hostConfig.systemd.services.dotfiles-agent-resource-reaper or null;
      expectedReaperEnvironment = "HOME=${hostConfig.dotfiles.workstation.homeDir}";
      reaperServiceConfigValid =
        serviceConfig:
        serviceConfig.Type == "oneshot"
        && serviceConfig.User == hostConfig.dotfiles.workstation.username
        && (serviceConfig.Environment or null) == expectedReaperEnvironment
        && (serviceConfig.UMask or null) == "0077"
        && serviceConfig.ExecStart == "${lib.getExe runtime.agentResource} reap";
      reaperEnvironmentMutations = [
        (builtins.removeAttrs reaper.serviceConfig [ "Environment" ])
        (reaper.serviceConfig // { Environment = "HOME=/tmp"; })
      ];
      reaperUMaskMutations = [
        (builtins.removeAttrs reaper.serviceConfig [ "UMask" ])
        (reaper.serviceConfig // { UMask = "0022"; })
      ];
      timer = hostConfig.systemd.timers.dotfiles-agent-resource-reaper or null;
    in
    assert lib.assertMsg (
      agentConfig.stateRoot == "~/.local/state/dotfiles-wsl/agent-resources"
    ) "agent resource state root changed";
    assert lib.assertMsg (
      agentConfig.runtime.ledgerRetentionDays == 30
      && sevenDayRuntime.agentResource != runtime.agentResource
    ) "agent resource ledger retention policy is not typed or package-wired";
    assert lib.assertMsg (
      agentResource == runtime.agentResource
      && agentWorktree == runtime.agentWorktree
      && hostConfig.dotfiles.platform.cli.commands.agentResource == runtime.agentResource
      && hostConfig.dotfiles.platform.cli.commands.agentWorktree == runtime.agentWorktree
    ) "agent resource commands are missing";
    assert lib.assertMsg (
      lib.hasInfix "mutation_lock_file=\"$locks_root/.worktree-mutation.lock\"" resourceSource
      && lib.hasInfix "mutation_lock=\"$locks_root/.worktree-mutation.lock\"" worktreeSource
      && lib.hasInfix "DOTFILES_AGENT_MUTATION_LOCK_FD=7" worktreeSource
      && lib.hasInfix "flock -x 7" resourceSource
      && lib.hasInfix "flock -x 7" worktreeSource
      && lib.hasInfix "exec 8>&- 9>&-" resourceSource
      && lib.hasInfix "exec 8>&- 9>&-" worktreeSource
      && lib.hasInfix "git_status=$?" resourceSource
      && lib.hasInfix "git_status=$?" worktreeSource
    ) "agent resource commands do not share the managed worktree mutation lock";
    assert lib.assertMsg (
      lib.hasInfix ".status == \"adding\"" resourceSource
      && lib.hasInfix "\"$resource_command\" begin-worktree-add" worktreeSource
    ) "agent worktree creation transaction phase is missing";
    assert lib.assertMsg (lib.hasInfix ".status == \"removing\"" resourceSource)
      "agent resource removal transaction phase is missing";
    assert lib.assertMsg (ownershipMatchesExpectedPackage agentResource resourceOwnership) (
      "agent resource command must be owned exactly once by the expected package: "
      + commandOwnershipDiagnostic agentResource resourceOwnership
    );
    assert lib.assertMsg (ownershipMatchesExpectedPackage agentWorktree worktreeOwnership) (
      "agent worktree command must be owned exactly once by the expected package: "
      + commandOwnershipDiagnostic agentWorktree worktreeOwnership
    );
    assert lib.assertMsg (
      duplicateResourceOwnership.count != 1
    ) "agent resource ownership contract accepted a duplicate executable basename";
    assert lib.assertMsg (
      duplicateResourceOwnership == {
        name = "dotfiles-agent-resource";
        count = 2;
        paths = expectedDuplicateResourceOwnerPaths;
      }
    ) "agent resource duplicate fixture owner paths changed";
    assert lib.assertMsg (
      commandOwnershipDiagnostic agentResource duplicateResourceOwnership
      == expectedDuplicateResourceDiagnostic
    ) "agent resource duplicate fixture diagnostic changed";
    assert lib.assertMsg (
      replacementResourceOwnership == {
        name = "dotfiles-agent-resource";
        count = 1;
        paths = [ (toString duplicateAgentResource) ];
      }
      &&
        replacementWorktreeOwnership == {
          name = "dotfiles-agent-worktree";
          count = 1;
          paths = [ (toString replacementAgentWorktree) ];
        }
    ) "agent command replacement fixtures no longer reproduce count-only ownership";
    assert lib.assertMsg (
      !ownershipMatchesExpectedPackage agentResource replacementResourceOwnership
      && !ownershipMatchesExpectedPackage agentWorktree replacementWorktreeOwnership
    ) "agent command ownership contract accepted a different package with the same basename";
    assert lib.assertMsg (
      commandOwnershipDiagnostic agentResource replacementResourceOwnership
      == expectedReplacementResourceDiagnostic
      &&
        commandOwnershipDiagnostic agentWorktree replacementWorktreeOwnership
        == expectedReplacementWorktreeDiagnostic
    ) "agent command replacement fixture diagnostic changed";
    assert lib.assertMsg (reaper != null && timer != null) "agent resource reaper units are missing";
    assert lib.assertMsg (
      reaper.serviceConfig.Type == "oneshot"
    ) "agent resource reaper must be oneshot";
    assert lib.assertMsg (
      reaper.serviceConfig.User == hostConfig.dotfiles.workstation.username
    ) "agent resource reaper must run as the desktop user";
    assert lib.assertMsg (
      (reaper.serviceConfig.Environment or null) == expectedReaperEnvironment
    ) "agent resource reaper HOME changed";
    assert lib.assertMsg (
      (reaper.serviceConfig.UMask or null) == "0077"
    ) "agent resource reaper UMask changed";
    assert lib.assertMsg (
      reaper.serviceConfig.ExecStart == "${lib.getExe runtime.agentResource} reap"
    ) "agent resource reaper command changed";
    assert lib.assertMsg (builtins.all (
      serviceConfig: !reaperServiceConfigValid serviceConfig
    ) reaperEnvironmentMutations) "agent resource reaper contract accepted a missing or changed HOME";
    assert lib.assertMsg (builtins.all (
      serviceConfig: !reaperServiceConfigValid serviceConfig
    ) reaperUMaskMutations) "agent resource reaper contract accepted a missing or changed UMask";
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
        export RESOURCE=${lib.getExe runtime.agentResource}
        export WORKTREE=${lib.getExe runtime.agentWorktree}
        export REAL_GIT=${lib.getExe pkgs.git}
        export RACE_RESOURCE=${lib.getExe raceAgentResource}
        export RACE_WORKTREE=${lib.getExe raceAgentWorktree}
        export ADDING_PAUSE_WORKTREE=${lib.getExe addingPauseWorktree}
        export AUDIT_RESOURCE=${lib.getExe auditAgentResource}
        export AUDIT_WORKTREE=${lib.getExe auditAgentWorktree}
        export CONTROLLED_PROC_RESOURCE=${lib.getExe controlledProcResource}
        export CONTROLLED_PRUNE_RESOURCE=${lib.getExe controlledPruneResource}
        export COUNTING_RESOURCE=${lib.getExe countingAgentResource}
        export OVERFLOW_RESOURCE=${lib.getExe overflowResource}
        export SEVEN_DAY_RESOURCE=${lib.getExe sevenDayRuntime.agentResource}
        export TEST_BASH=${lib.getExe pkgs.bash}
        ${lib.getExe pkgs.bash} ${../fixtures/resource/agent-resources.sh}
        touch $out
      '';
}
