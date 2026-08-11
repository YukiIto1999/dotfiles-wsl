{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  variantConfig,
  self,
  ...
}:

let
  expected = builtins.fromJSON (builtins.readFile ./fixtures/client-contract.json);
  agentConfig = hostConfig.dotfiles.agents;
  clients = agentConfig.clients;
  variantClients = variantConfig.dotfiles.agents.clients;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
  artifacts = hostConfig.dotfiles.artifacts;
  artifactSource = id: artifacts.${id}.source;
  gatewayUrl = hostConfig.dotfiles.mcp.gateway.url;
  gatewayPort = hostConfig.dotfiles.mcp.gateway.port;
  variantGatewayUrl = variantConfig.dotfiles.mcp.gateway.url;
  roster = hostConfig.dotfiles.toolchain.lsp;
  installAgents = hostConfig.dotfiles.commands.installAgents;
  installAgentsExe = lib.getExe installAgents;
  runtime = import ./package.nix {
    inherit lib pkgs;
    ledgerRetentionDays = agentConfig.runtime.ledgerRetentionDays;
  };
  sevenDayRuntime = import ./package.nix {
    inherit lib pkgs;
    ledgerRetentionDays = 7;
  };
  wrongOwnerStat = pkgs.writeShellScriptBin "stat" ''
    if [[ $# -eq 3 && $1 == -c && $2 == %u \
      && $3 == "/proc/''${DOTFILES_AGENT_TEST_WRONG_OWNER_PID-}" ]]; then
      printf '%s\n' "$(( $(${pkgs.coreutils}/bin/id -u) + 1 ))"
      exit 0
    fi
    exec ${pkgs.coreutils}/bin/stat "$@"
  '';
  wrongOwnerGc = pkgs.writeShellApplication {
    name = "dotfiles-agent-project-cache-gc-wrong-owner-fixture";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    text = ''
      export PATH=${wrongOwnerStat}/bin:$PATH
      ${lib.getExe pkgs.bash} ${./impl/runtime/project-cache-gc.sh}
    '';
  };
  gcMutationMv = pkgs.writeShellScriptBin "mv" ''
    real_mv=${pkgs.coreutils}/bin/mv
    if [[ $# -eq 4 && $1 == -T && $2 == -- \
      && $4 == */.gc-quarantine.*/session \
      && -n ''${DOTFILES_AGENT_TEST_GC_MUTATION_MODE-} ]]; then
      set +e
      "$real_mv" "$@"
      status=$?
      set -e
      if ((status == 0)); then
        case $DOTFILES_AGENT_TEST_GC_MUTATION_MODE in
        live-owner)
          ${lib.getExe pkgs.jq} \
            --argjson owner_pid "$DOTFILES_AGENT_TEST_GC_LIVE_PID" \
            --arg owner_start_time "$DOTFILES_AGENT_TEST_GC_LIVE_START_TIME" \
            '.owner_pid = $owner_pid | .owner_start_time = $owner_start_time' \
            "$4/metadata.json" >"$4/metadata.tmp"
          ;;
        *)
          ${lib.getExe pkgs.jq} --arg project_id "$DOTFILES_AGENT_TEST_GC_MUTATION_PROJECT_ID" \
            '.project_id = $project_id' "$4/metadata.json" >"$4/metadata.tmp"
          ;;
        esac
        ${pkgs.coreutils}/bin/chmod 600 "$4/metadata.tmp"
        "$real_mv" -T -- "$4/metadata.tmp" "$4/metadata.json"
        if [[ $DOTFILES_AGENT_TEST_GC_MUTATION_MODE == block-restore ]]; then
          ${pkgs.coreutils}/bin/mkdir -m 700 -- "$3"
        fi
        : >"$DOTFILES_AGENT_TEST_GC_MUTATION_MARKER"
      fi
      exit "$status"
    fi
    exec "$real_mv" "$@"
  '';
  mutationGc = pkgs.writeShellApplication {
    name = "dotfiles-agent-project-cache-gc-mutation-fixture";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    text = ''
      export PATH=${gcMutationMv}/bin:$PATH
      ${lib.getExe pkgs.bash} ${./impl/runtime/project-cache-gc.sh}
    '';
  };
  gcRaceRmdir = pkgs.writeShellScriptBin "rmdir" ''
    target=''${!#}
    if [[ $target == */.gc-quarantine.* \
      && -n ''${DOTFILES_AGENT_TEST_GC_RMDIR_RACE_MARKER-} \
      && ! -e ''${DOTFILES_AGENT_TEST_GC_RMDIR_RACE_MARKER} ]]; then
      : >"$target/fixture-blocker"
      : >"$DOTFILES_AGENT_TEST_GC_RMDIR_RACE_MARKER"
    fi
    exec ${pkgs.coreutils}/bin/rmdir "$@"
  '';
  rmdirRaceGc = pkgs.writeShellApplication {
    name = "dotfiles-agent-project-cache-gc-rmdir-race-fixture";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      util-linux
    ];
    text = ''
      export PATH=${gcRaceRmdir}/bin:$PATH
      ${lib.getExe pkgs.bash} ${./impl/runtime/project-cache-gc.sh}
    '';
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
        ]
        [
          (lib.escapeShellArg (lib.getExe pkgs.git))
          "30"
        ]
        (builtins.readFile ./impl/resource/agent-resource.sh);
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
  fakeNix = pkgs.writeShellScript "fake-nix-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
  '';
  fakeGit = pkgs.writeShellScript "fake-git-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
    pwd -P > "$PWD_CAPTURE"
    for argument in "$@"; do
      if [ "$argument" = dotfiles-agent-managed-worktree ]; then
        exec ${lib.getExe pkgs.git} "$@"
      fi
    done
  '';
  fakeAgentWorktree = pkgs.writeShellScript "fake-agent-worktree-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
    pwd -P > "$PWD_CAPTURE"
    ${lib.getExe pkgs.git} config --get advice.detachedHead > "$CONFIG_CAPTURE" || true
  '';
  fixtureNixBuildShims = runtime.mkNixBuildShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
  };
  fixtureAgentShims = runtime.mkAgentShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
    gitCommand = fakeGit;
    worktreeCommand = fakeAgentWorktree;
  };
  wrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeClientNames = builtins.filter (name: name != "antigravity" && clients.${name}.binary != "") (
    builtins.attrNames clients
  );

  projectManagedFile =
    file:
    builtins.removeAttrs file [
      "seedMigrationCommand"
      "source"
    ]
    // lib.optionalAttrs (file.seedMigrationCommand != null) {
      seedMigrationCommand = lib.getName file.seedMigrationCommand;
    };
  projectClient = client: {
    inherit (client)
      binary
      capabilityManagedFiles
      rulesDestination
      skillsDestination
      versionArgs
      ;
    definitions = {
      mode = client.definitionMode;
      destination = client.definitionsDestination;
      format = client.definitionFormat;
      names = builtins.attrNames client.definitions;
    };
    capabilities = {
      lsp = client.lspMode;
      telemetry = client.telemetryMode;
      agentmemory = client.agentmemoryMode;
    };
    gateway = {
      inherit (client.gatewayConfig) format managedFile;
    };
    managedFiles = lib.mapAttrs (_: projectManagedFile) client.managedFiles;
    install = client.install;
  };
  actualContract = lib.mapAttrs (_: projectClient) clients;

  clientOptions = builtins.removeAttrs (
    hostOptions.dotfiles.agents.clients.type.nestedTypes.elemType.getSubOptions
    [ ]
  ) [ "_module" ];
  managedFileOptions = builtins.removeAttrs (
    clientOptions.managedFiles.type.nestedTypes.elemType.getSubOptions
    [ ]
  ) [ "_module" ];
  capabilityManagedFileOptions = builtins.removeAttrs (
    clientOptions.capabilityManagedFiles.type.getSubOptions
    [ ]
  ) [ "_module" ];
  optionMetadata = {
    enabled = {
      type = hostOptions.dotfiles.agents.enabled.type.name;
      elementType = hostOptions.dotfiles.agents.enabled.type.nestedTypes.elemType.name;
      hasDefault = hostOptions.dotfiles.agents.enabled ? default;
    };
    runtime.ledgerRetentionDays = {
      type = hostOptions.dotfiles.agents.runtime.ledgerRetentionDays.type.name;
      default = hostOptions.dotfiles.agents.runtime.ledgerRetentionDays.default;
    };
    shared = lib.mapAttrs (_: option: {
      type = option.type.name;
      internal = option.internal or false;
      readOnly = option.readOnly or false;
    }) hostOptions.dotfiles.agents.shared;
    clients = {
      type = hostOptions.dotfiles.agents.clients.type.name;
      elementType = hostOptions.dotfiles.agents.clients.type.nestedTypes.elemType.name;
      internal = hostOptions.dotfiles.agents.clients.internal or false;
      hasDefault = hostOptions.dotfiles.agents.clients ? default;
    };
    client = lib.mapAttrs (_: option: option.type.name) clientOptions;
    managedFile = lib.mapAttrs (_: option: option.type.name) managedFileOptions;
    capabilityManagedFile = lib.mapAttrs (_: option: option.type.name) capabilityManagedFileOptions;
  };
  expectedOptionMetadata = {
    enabled = {
      type = "listOf";
      elementType = "str";
      hasDefault = false;
    };
    runtime.ledgerRetentionDays = {
      type = "positiveInt";
      default = 30;
    };
    shared = {
      rules = {
        type = "path";
        internal = true;
        readOnly = true;
      };
      skills = {
        type = "attrsOf";
        internal = true;
        readOnly = true;
      };
      definitions = {
        type = "attrsOf";
        internal = true;
        readOnly = true;
      };
    };
    clients = {
      type = "attrsOf";
      elementType = "submodule";
      internal = true;
      hasDefault = true;
    };
    client = {
      agentmemoryMode = "enum";
      binary = "str";
      capabilityManagedFiles = "submodule";
      definitionFormat = "nullOr";
      definitionMode = "enum";
      definitions = "attrsOf";
      definitionsDestination = "nullOr";
      gatewayConfig = "submodule";
      install = "either";
      lspMode = "enum";
      managedFiles = "attrsOf";
      rulesDestination = "str";
      skillsDestination = "str";
      telemetryMode = "enum";
      versionArgs = "listOf";
    };
    managedFile = {
      deployment = "enum";
      destination = "str";
      format = "enum";
      seedMigrationCommand = "nullOr";
      source = "path";
    };
    capabilityManagedFile = {
      agentmemory = "nullOr";
      lsp = "nullOr";
      telemetry = "nullOr";
    };
  };

  fixtureSource = ./shared/AGENTS.md;
  fixtureSeedMigrationCommand = pkgs.writeShellScriptBin "dotfiles-migrate-codex-config" "exit 0";
  agentContract = import ./impl/contract.nix { inherit lib; };
  fixtureDefinitions = lib.genAttrs expected.clients.claude.definitions.names (_: fixtureSource);
  candidateClients = lib.mapAttrs (_: client: {
    inherit (client)
      binary
      capabilityManagedFiles
      rulesDestination
      skillsDestination
      versionArgs
      install
      ;
    definitionMode = client.definitions.mode;
    definitionsDestination = client.definitions.destination;
    definitionFormat = client.definitions.format;
    definitions = lib.genAttrs client.definitions.names (_: fixtureSource);
    gatewayConfig = client.gateway // {
      source = fixtureSource;
    };
    managedFiles = lib.mapAttrs (
      _: file:
      builtins.removeAttrs file [ "seedMigrationCommand" ]
      // {
        source = fixtureSource;
      }
      // lib.optionalAttrs (file ? seedMigrationCommand) {
        seedMigrationCommand = fixtureSeedMigrationCommand;
      }
    ) client.managedFiles;
    lspMode = client.capabilities.lsp;
    telemetryMode = client.capabilities.telemetry;
    agentmemoryMode = client.capabilities.agentmemory;
  }) expected.clients;
  baseCandidate = {
    enabled = expected.required;
    inherit (agentConfig) runtime;
    shared = {
      rules = fixtureSource;
      skills.fixture = fixtureSource;
      definitions = fixtureDefinitions;
    };
    clients = candidateClients;
  };

  evalContract =
    candidate:
    lib.evalModules {
      modules = [
        ({ config, ... }: {
          options.dotfiles.agents = agentContract.options;
          options.assertions = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  assertion = lib.mkOption { type = lib.types.bool; };
                  message = lib.mkOption { type = lib.types.str; };
                };
              }
            );
            default = [ ];
          };
          config.dotfiles.agents = candidate;
          config.assertions = agentContract.assertionsFor config.dotfiles.agents;
        })
      ];
    };
  contractIsValid =
    candidate:
    let
      attempted = builtins.tryEval (
        let
          evaluated = evalContract candidate;
          evaluatedContract = builtins.removeAttrs evaluated.config.dotfiles.agents [
            "agentResource"
            "agentWorktree"
            "stateRoot"
          ];
          contractWithoutPackages = evaluatedContract // {
            clients = lib.mapAttrs (
              _: client:
              client
              // {
                managedFiles = lib.mapAttrs (
                  _: file: builtins.removeAttrs file [ "seedMigrationCommand" ]
                ) client.managedFiles;
              }
            ) evaluatedContract.clients;
          };
        in
        builtins.deepSeq contractWithoutPackages (
          builtins.all (assertion: assertion.assertion) evaluated.config.assertions
        )
      );
    in
    attempted.success && attempted.value;
  failedContractMessages =
    candidate:
    map (entry: entry.message) (
      builtins.filter (entry: !entry.assertion) (evalContract candidate).config.assertions
    );
  requiredStringChecksFor =
    candidate: agentContract.requiredStringChecksFor (evalContract candidate).config.dotfiles.agents;
  mutateClient =
    name: update:
    baseCandidate
    // {
      clients = baseCandidate.clients // {
        ${name} = baseCandidate.clients.${name} // update;
      };
    };
  mutateManagedDestination =
    clientName: fileId: destination:
    mutateClient clientName {
      managedFiles = baseCandidate.clients.${clientName}.managedFiles // {
        ${fileId} = baseCandidate.clients.${clientName}.managedFiles.${fileId} // {
          inherit destination;
        };
      };
    };
  emptyBinaryCandidate = mutateClient "claude" { binary = ""; };
  emptyInstallScriptUrlCandidate = mutateClient "claude" {
    install = baseCandidate.clients.claude.install // {
      scriptUrl = "";
    };
  };
  emptyInstallRepoCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      repo = "";
    };
  };
  emptyInstallAarch64AssetCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        aarch64 = baseCandidate.clients.codex.install.releaseByArch.aarch64 // {
          asset = "";
        };
      };
    };
  };
  emptyInstallX86AssetCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
          asset = "";
        };
      };
    };
  };
  emptyInstallEntrypointCandidate = mutateClient "codex" {
    install = baseCandidate.clients.codex.install // {
      releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
        x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
          entrypoint = "";
        };
      };
    };
  };
  packageTreeInstall = baseCandidate.clients.codex.install // {
    layout = "package-tree";
    releaseByArch = lib.mapAttrs (_: release: release // { entrypoint = "bin/codex"; }) (
      baseCandidate.clients.codex.install.releaseByArch
    );
    requiredPaths = {
      bin = {
        kind = "directory";
        executable = false;
      };
      "bin/codex" = {
        kind = "file";
        executable = true;
      };
    };
  };
  invalidInstallEntrypointCandidate =
    entrypoint:
    mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
          x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
            inherit entrypoint;
          };
        };
      };
    };
  invalidRequiredPathCandidate =
    path:
    mutateClient "codex" {
      install = packageTreeInstall // {
        requiredPaths = packageTreeInstall.requiredPaths // {
          ${path} = {
            kind = "file";
            executable = false;
          };
        };
      };
    };
  requiredInstallNegativeEvalCaseNames = [
    "entrypoint-current-segment"
    "entrypoint-empty-segment"
    "invalid-kind"
    "legacy-asset-by-arch"
    "legacy-binary-in-archive"
    "required-path-current-segment"
    "required-path-empty-segment"
  ];
  installNegativeEvalCases = {
    entrypoint-current-segment = invalidInstallEntrypointCandidate "bin/./codex";
    entrypoint-empty-segment = invalidInstallEntrypointCandidate "bin//codex";
    invalid-kind = mutateClient "claude" {
      install = baseCandidate.clients.claude.install // {
        kind = "invalid-kind";
      };
    };
    legacy-asset-by-arch = mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        assetByArch = {
          x86_64 = "legacy-x86_64.tar.gz";
          aarch64 = "legacy-aarch64.tar.gz";
        };
      };
    };
    legacy-binary-in-archive = mutateClient "codex" {
      install = baseCandidate.clients.codex.install // {
        binaryInArchive = "codex";
      };
    };
    required-path-current-segment = invalidRequiredPathCandidate "bin/./share";
    required-path-empty-segment = invalidRequiredPathCandidate "bin//share";
  };
  unexpectedlyValidInstallNegativeEvalCases = builtins.attrNames (
    lib.filterAttrs (_: candidate: contractIsValid candidate) installNegativeEvalCases
  );
  invalidInstallEntrypointCandidates = map invalidInstallEntrypointCandidate [
    ""
    "/codex"
    "../codex"
    "bin/../codex"
    "bin//codex"
    "bin/./codex"
  ];
  invalidRequiredPathCandidates = map invalidRequiredPathCandidate [
    ""
    "/share/codex"
    "../share/codex"
    "share/../codex"
    "bin//share"
    "bin/./share"
  ];
  nonSeedMigrationCandidate = mutateClient "opencode" {
    managedFiles = baseCandidate.clients.opencode.managedFiles // {
      config = baseCandidate.clients.opencode.managedFiles.config // {
        seedMigrationCommand = fixtureSeedMigrationCommand;
      };
    };
  };
  invalidRulesDestinationCandidate = mutateClient "claude" {
    rulesDestination = "../AGENTS.md";
  };
  invalidSkillsDestinationCandidate = mutateClient "claude" {
    skillsDestination = ".claude//skills";
  };
  invalidDefinitionsDestinationCandidate = mutateClient "claude" {
    definitionsDestination = "/tmp/agents";
  };
  invalidMultipleSharedDestinationsCandidate = mutateClient "claude" {
    rulesDestination = "../AGENTS.md";
    skillsDestination = ".claude//skills";
  };

  losslessVersionArgs = [
    "trailing\n"
    "\n"
    "embedded\nline"
    "  spaced  "
    "pipe|value"
  ];
  losslessInstallManifest = builtins.toJSON [
    {
      name = "lossless-fixture";
      binary = "argv-capture";
      versionArgs = losslessVersionArgs;
      install = {
        kind = "installer-script";
        updateOwner = "upstream-installer";
        layout = "upstream-managed";
        scriptUrl = "https://example.invalid/install.sh";
      };
    }
  ];
  losslessInstallAgents = pkgs.writeShellApplication {
    name = "check-lossless-install-agents";
    runtimeInputs = with pkgs; [
      bash
      curl
      jq
      gnutar
      gzip
      coreutils
    ];
    text =
      builtins.replaceStrings
        [
          "@installManifest@"
          "@versionArgsDecoder@"
        ]
        [
          losslessInstallManifest
          (builtins.readFile ./impl/version-args.sh)
        ]
        (builtins.readFile ./impl/install-agents.sh);
  };
  losslessInstallAgentsExe = lib.getExe losslessInstallAgents;

  fixtureMigrateCodexConfig = pkgs.writeShellScript "fixture-migrate-codex-config" (
    builtins.replaceStrings
      [
        "@chmodCommand@"
        "@idCommand@"
        "@jqCommand@"
        "@mktempCommand@"
        "@mvCommand@"
        "@remarshalCommand@"
        "@rmCommand@"
        "@statCommand@"
      ]
      [
        "${pkgs.coreutils}/bin/chmod"
        "${pkgs.coreutils}/bin/id"
        (lib.getExe pkgs.jq)
        ''"$FIXTURE_MKTEMP"''
        "${pkgs.coreutils}/bin/mv"
        ''"$FIXTURE_REMARSHAL"''
        "${pkgs.coreutils}/bin/rm"
        ''"$FIXTURE_STAT"''
      ]
      (builtins.readFile ./codex/impl/migrate-config.sh)
  );

  expectedInstallManifest = map (name: {
    inherit name;
    inherit (expected.clients.${name}) binary versionArgs install;
  }) expected.required;
  agentmemoryHookCommand = name: "/run/current-system/sw/bin/agentmemory-hook-${name}";
  expectedHook =
    {
      name,
      matcher ? null,
      extra ? { },
    }:
    [
      (
        {
          hooks = [
            (
              {
                type = "command";
                command = agentmemoryHookCommand name;
              }
              // extra
            )
          ];
        }
        // lib.optionalAttrs (matcher != null) { inherit matcher; }
      )
    ];
  expectedClaudeHooks = {
    SessionStart = expectedHook { name = "session-start"; };
    UserPromptSubmit = expectedHook { name = "prompt-submit"; };
    PreToolUse = expectedHook {
      name = "pre-tool-use";
      matcher = "Edit|Write|Read|Glob|Grep";
    };
    PostToolUse = expectedHook { name = "post-tool-use"; };
    PostToolUseFailure = expectedHook { name = "post-tool-failure"; };
    PreCompact = expectedHook { name = "pre-compact"; };
    SubagentStart = expectedHook { name = "subagent-start"; };
    SubagentStop = expectedHook { name = "subagent-stop"; };
    Notification = expectedHook { name = "notification"; };
    TaskCompleted = expectedHook { name = "task-completed"; };
    Stop = expectedHook { name = "stop"; };
    SessionEnd = expectedHook { name = "session-end"; };
  };
  expectedCodexHooks = {
    SessionStart = expectedHook {
      name = "session-start";
      extra.statusMessage = "agentmemory: loading session context";
    };
    UserPromptSubmit = expectedHook { name = "prompt-submit"; };
    PreToolUse = expectedHook {
      name = "pre-tool-use";
      matcher = "Edit|Write|Read|Glob|Grep";
    };
    PostToolUse = expectedHook { name = "post-tool-use"; };
    PreCompact = expectedHook { name = "pre-compact"; };
    Stop = expectedHook { name = "stop"; };
  };

  managedRows = lib.concatMap (
    clientName:
    lib.mapAttrsToList (id: file: {
      inherit clientName id file;
    }) clients.${clientName}.managedFiles
  ) (builtins.attrNames clients);
  normalizeSource =
    source:
    if builtins.typeOf source == "path" then
      builtins.path {
        path = source;
        name = builtins.baseNameOf (toString source);
      }
    else
      source;
  managedDeploymentMatches =
    row:
    let
      artifact = artifacts."agents/${row.clientName}/${row.id}";
      target = row.file.destination;
      deployedSource = normalizeSource row.file.source;
    in
    artifact.source == deployedSource
    && (
      if row.file.deployment == "system" then
        hostConfig.environment.etc.${target}.source == deployedSource
        && artifact.deployedAt == "/etc/${target}"
      else if row.file.deployment == "home" then
        homeConfig.home.file.${target}.source == deployedSource
        && artifact.deployedAt == "${hostConfig.dotfiles.host.homeDir}/${target}"
      else
        artifact.deployedAt == null
    );

  sharedDeploymentMatches = lib.all (
    clientName:
    let
      client = clients.${clientName};
      homePrefix = hostConfig.dotfiles.host.homeDir;
      rulesArtifact = artifacts."agents/${clientName}/rules";
      rulesMatch =
        rulesArtifact.source == normalizeSource hostConfig.dotfiles.agents.shared.rules
        && rulesArtifact.format == "markdown"
        && rulesArtifact.deployedAt == "${homePrefix}/${client.rulesDestination}";
      skillsMatch = lib.all (
        name:
        let
          artifact = artifacts."agents/${clientName}/skills/${name}";
        in
        artifact.source == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
        && artifact.format == "directory"
        && artifact.deployedAt == "${homePrefix}/${client.skillsDestination}/${name}"
      ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills);
      definitionsMatch = lib.all (
        name:
        let
          suffix = if client.definitionFormat == "toml" then "toml" else "md";
          artifact = artifacts."agents/${clientName}/definitions/${name}";
          expectedFormat = if client.definitionFormat == "toml" then "toml" else "markdown";
        in
        homeConfig.home.file."${client.definitionsDestination}/${name}.${suffix}".source
        == normalizeSource client.definitions.${name}
        && artifact.source == normalizeSource client.definitions.${name}
        && artifact.format == expectedFormat
        && artifact.deployedAt == "${homePrefix}/${client.definitionsDestination}/${name}.${suffix}"
      ) (builtins.attrNames client.definitions);
    in
    homeConfig.home.file.${client.rulesDestination}.source
    == normalizeSource hostConfig.dotfiles.agents.shared.rules
    && lib.all (
      name:
      homeConfig.home.file."${client.skillsDestination}/${name}".source
      == normalizeSource hostConfig.dotfiles.agents.shared.skills.${name}
    ) (builtins.attrNames hostConfig.dotfiles.agents.shared.skills)
    && rulesMatch
    && skillsMatch
    && definitionsMatch
  ) (builtins.attrNames clients);

  expectedArtifactIds = lib.sort builtins.lessThan (
    lib.concatMap (
      clientName:
      let
        client = clients.${clientName};
      in
      [ "agents/${clientName}/rules" ]
      ++ map (name: "agents/${clientName}/skills/${name}") (
        builtins.attrNames hostConfig.dotfiles.agents.shared.skills
      )
      ++ map (name: "agents/${clientName}/definitions/${name}") (builtins.attrNames client.definitions)
      ++ map (id: "agents/${clientName}/${id}") (
        builtins.attrNames expected.clients.${clientName}.managedFiles
      )
    ) expected.required
  );
  actualAgentArtifactIds = lib.sort builtins.lessThan (
    builtins.filter (lib.hasPrefix "agents/") (builtins.attrNames artifacts)
  );

  seedActivation = homeConfig.home.activation.seedAgentConfigs.data;
  fixtureSeedActivation =
    builtins.replaceStrings [ hostConfig.dotfiles.host.homeDir ] [ "$fixture/home" ]
      seedActivation;
  fixtureSeedActivationScript = pkgs.writeShellScript "fixture-seed-agent-configs" fixtureSeedActivation;
  fixtureGenericSeedMigration = pkgs.writeShellScriptBin "fixture-generic-seed-migration" ''
    printf '%s\0' "$@" > "$MIGRATION_CAPTURE"
  '';
  codexSeedMigrationExe = lib.getExe clients.codex.managedFiles.user.seedMigrationCommand;
  fixtureGenericSeedActivation =
    builtins.replaceStrings
      [ codexSeedMigrationExe ]
      [
        (lib.getExe fixtureGenericSeedMigration)
      ]
      fixtureSeedActivation;
  managedRowsWithSeedMigration = builtins.filter (
    row: row.file.seedMigrationCommand != null
  ) managedRows;

  sharedDefinitionSources = builtins.attrValues hostConfig.dotfiles.agents.shared.definitions;
  claudeDefinitionSources = builtins.attrValues clients.claude.definitions;
  codexDefinitionSources = builtins.attrValues clients.codex.definitions;
  opencodeDefinitionSources = builtins.attrValues clients.opencode.definitions;
in
{
  agent-client-roster =
    assert expected.required != [ ];
    assert clients != { };
    assert lib.sort builtins.lessThan hostConfig.dotfiles.agents.enabled == expected.required;
    assert lib.sort builtins.lessThan (builtins.attrNames clients) == expected.required;
    assert variantConfig.dotfiles.agents.enabled == expected.required;
    assert lib.sort builtins.lessThan (builtins.attrNames variantClients) == expected.required;
    assert actualContract == expected.clients;
    assert optionMetadata == expectedOptionMetadata;
    assert contractIsValid baseCandidate;
    assert !contractIsValid (baseCandidate // { clients = { }; });
    assert builtins.all (valid: valid) (builtins.attrValues (requiredStringChecksFor baseCandidate));
    assert !contractIsValid (baseCandidate // { enabled = [ "claude" ]; });
    assert !contractIsValid (mutateClient "claude" { definitionFormat = "toml"; });
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          definitionsDestination = ".gemini/agents";
          definitionFormat = "frontmatter-markdown";
          definitions.fixture = fixtureSource;
        }
      );
    assert !contractIsValid (mutateClient "codex" { definitionFormat = null; });
    assert
      !contractIsValid (
        mutateClient "opencode" {
          managedFiles = builtins.removeAttrs baseCandidate.clients.opencode.managedFiles [ "config" ];
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          managedFiles = baseCandidate.clients.codex.managedFiles // {
            user = baseCandidate.clients.codex.managedFiles.user // {
              destination = baseCandidate.clients.claude.managedFiles.user-settings.destination;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          managedFiles = baseCandidate.clients.codex.managedFiles // {
            user = baseCandidate.clients.codex.managedFiles.user // {
              destination = baseCandidate.clients.opencode.managedFiles.config.destination;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateManagedDestination "codex" "user" ".config/opencode/../opencode/opencode.json"
      );
    assert !contractIsValid (mutateManagedDestination "antigravity" "mcp" "/tmp/antigravity.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config//opencode.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config/./opencode.json");
    assert !contractIsValid (mutateManagedDestination "opencode" "config" ".config/../opencode.json");
    assert !contractIsValid (mutateManagedDestination "codex" "user" "../outside-home.toml");
    assert !contractIsValid (mutateManagedDestination "codex" "system" "../outside-etc.toml");
    assert !contractIsValid invalidRulesDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/rulesDestination (../AGENTS.md)"
      (failedContractMessages invalidRulesDestinationCandidate);
    assert !contractIsValid invalidSkillsDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/skillsDestination (.claude//skills)"
      (failedContractMessages invalidSkillsDestinationCandidate);
    assert !contractIsValid invalidDefinitionsDestinationCandidate;
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/definitionsDestination (/tmp/agents)"
      (failedContractMessages invalidDefinitionsDestinationCandidate);
    assert builtins.elem
      "agent shared destinations must be canonical home-relative paths: claude/rulesDestination (../AGENTS.md), claude/skillsDestination (.claude//skills)"
      (failedContractMessages invalidMultipleSharedDestinationsCandidate);
    assert !contractIsValid (mutateClient "antigravity" { lspMode = "supported"; });
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          capabilityManagedFiles.lsp = "mcp";
        }
      );
    assert
      !contractIsValid (
        mutateClient "opencode" {
          managedFiles = builtins.removeAttrs baseCandidate.clients.opencode.managedFiles [
            "agentmemory-plugin"
          ];
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          capabilityManagedFiles.agentmemory = null;
        }
      );
    assert !contractIsValid emptyBinaryCandidate;
    assert builtins.elem "agent required semantic strings must be non-empty: binaries (claude)" (
      failedContractMessages emptyBinaryCandidate
    );
    assert !contractIsValid (mutateClient "codex" { versionArgs = [ ]; });
    assert !contractIsValid (mutateClient "codex" { versionArgs = [ "" ]; });
    assert !contractIsValid (mutateClient "claude" { rulesDestination = ""; });
    assert !contractIsValid (mutateClient "claude" { skillsDestination = ""; });
    assert !contractIsValid (mutateClient "claude" { definitionsDestination = ""; });
    assert
      !contractIsValid (
        mutateClient "claude" {
          definitions = baseCandidate.clients.claude.definitions // {
            "" = fixtureSource;
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "antigravity" {
          managedFiles.mcp = baseCandidate.clients.antigravity.managedFiles.mcp // {
            destination = "";
          };
        }
      );
    assert
      !(requiredStringChecksFor (
        mutateClient "antigravity" {
          gatewayConfig = baseCandidate.clients.antigravity.gatewayConfig // {
            managedFile = "";
          };
        }
      )).gatewayManagedFileReferences;
    assert
      !(requiredStringChecksFor (
        mutateClient "claude" {
          capabilityManagedFiles = baseCandidate.clients.claude.capabilityManagedFiles // {
            lsp = "";
          };
        }
      )).capabilityManagedFileReferences;
    assert
      !(requiredStringChecksFor (
        mutateClient "antigravity" {
          managedFiles = baseCandidate.clients.antigravity.managedFiles // {
            "" = {
              source = fixtureSource;
              format = "json";
              deployment = "home";
              destination = ".gemini/antigravity-cli/empty-id.json";
            };
          };
        }
      )).managedFileIds;
    assert
      !(requiredStringChecksFor (
        baseCandidate // { enabled = [ "" ] ++ builtins.tail baseCandidate.enabled; }
      )).enabledIds;
    assert
      !(requiredStringChecksFor (
        baseCandidate
        // {
          clients = baseCandidate.clients // {
            "" = baseCandidate.clients.antigravity;
          };
        }
      )).clientIds;
    assert
      !contractIsValid (
        baseCandidate
        // {
          shared = baseCandidate.shared // {
            skills = baseCandidate.shared.skills // {
              "" = fixtureSource;
            };
          };
        }
      );
    assert
      !contractIsValid (
        baseCandidate
        // {
          shared = baseCandidate.shared // {
            definitions = baseCandidate.shared.definitions // {
              "" = fixtureSource;
            };
          };
        }
      );
    assert !contractIsValid emptyInstallScriptUrlCandidate;
    assert lib.any (lib.hasInfix "installScriptUrls (claude)") (
      failedContractMessages emptyInstallScriptUrlCandidate
    );
    assert !contractIsValid emptyInstallRepoCandidate;
    assert lib.any (lib.hasInfix "installRepositories (codex)") (
      failedContractMessages emptyInstallRepoCandidate
    );
    assert !contractIsValid emptyInstallAarch64AssetCandidate;
    assert lib.any (lib.hasInfix "installAssetsAarch64 (codex)") (
      failedContractMessages emptyInstallAarch64AssetCandidate
    );
    assert !contractIsValid emptyInstallX86AssetCandidate;
    assert lib.any (lib.hasInfix "installAssetsX86_64 (codex)") (
      failedContractMessages emptyInstallX86AssetCandidate
    );
    assert !contractIsValid emptyInstallEntrypointCandidate;
    assert lib.any (lib.hasInfix "installEntrypointsX86_64 (codex)") (
      failedContractMessages emptyInstallEntrypointCandidate
    );
    assert lib.assertMsg (
      builtins.attrNames installNegativeEvalCases == requiredInstallNegativeEvalCaseNames
    ) "agent install negative eval regression cases must be explicit and complete";
    assert lib.assertMsg (unexpectedlyValidInstallNegativeEvalCases == [ ]) (
      "invalid agent install evaluation succeeded: "
      + lib.concatStringsSep ", " unexpectedlyValidInstallNegativeEvalCases
    );
    assert builtins.all (candidate: !contractIsValid candidate) invalidInstallEntrypointCandidates;
    assert builtins.all (candidate: !contractIsValid candidate) invalidRequiredPathCandidates;
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            updateOwner = "dotfiles";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            releaseByArch = baseCandidate.clients.codex.install.releaseByArch // {
              x86_64 = baseCandidate.clients.codex.install.releaseByArch.x86_64 // {
                unexpected = "untyped";
              };
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths."bin/codex" = packageTreeInstall.requiredPaths."bin/codex" // {
              unexpected = "untyped";
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            layout = "single-binary";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            updateOwner = "upstream-installer";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            layout = "upstream-managed";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            layout = "package-tree";
            requiredPaths = { };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths = {
              "bin/other" = {
                kind = "file";
                executable = true;
              };
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = packageTreeInstall // {
            requiredPaths."bin/codex" = {
              kind = "directory";
              executable = false;
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = baseCandidate.clients.codex.install // {
            requiredPaths.codex = {
              kind = "file";
              executable = true;
            };
          };
        }
      );
    assert !contractIsValid nonSeedMigrationCandidate;
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            repo = "invalid/extra";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          install = baseCandidate.clients.claude.install // {
            unexpected = "untyped";
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "codex" {
          install = {
            kind = "github-release";
            repo = "openai/codex";
            updateOwner = "dotfiles";
            layout = "single-binary";
            releaseByArch.x86_64 = {
              asset = "only-one-architecture.tar.gz";
              entrypoint = "codex";
            };
          };
        }
      );
    assert
      !contractIsValid (
        mutateClient "claude" {
          managedFiles.managed-settings = baseCandidate.clients.claude.managedFiles.managed-settings // {
            owner = "untyped";
          };
        }
      );
    pkgs.runCommandLocal "check-agent-client-roster" { } "touch $out";

  agent-config-migration =
    assert map (row: "${row.clientName}/${row.id}") managedRowsWithSeedMigration == [ "codex/user" ];
    assert fixtureGenericSeedActivation != fixtureSeedActivation;
    pkgs.runCommandLocal "check-agent-config-migration"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.ripgrep
        ];
      }
      ''
        set -euo pipefail

        if rg -n 'clientName[[:space:]]*==[[:space:]]*"codex"|clients\.codex|migrateCodexConfig' \
          ${self}/agents/module.nix; then
          echo "root agent module contains a Codex-specific branch" >&2
          exit 1
        fi

        fixture=$PWD/generic-seed-migration
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' 'sandbox_mode = "workspace-write"' \
          > "$fixture/home/.codex/config.toml"
        export MIGRATION_CAPTURE=$fixture/migration-argv
        ${fixtureGenericSeedActivation}

        mapfile -d $'\0' -t migrationArgs < "$MIGRATION_CAPTURE"
        test "''${#migrationArgs[@]}" -eq 2
        test "''${migrationArgs[0]}" = "$fixture/home/.codex/config.toml"
        test "''${migrationArgs[1]}" = "$fixture/home"

        touch $out
      '';

  agent-artifact-contract =
    assert variantConfig.dotfiles.mcp.gateway.port != gatewayPort;
    assert lib.count (package: package == installAgents) hostConfig.environment.systemPackages == 1;
    assert builtins.all managedDeploymentMatches managedRows;
    assert sharedDeploymentMatches;
    assert expectedArtifactIds == actualAgentArtifactIds;
    assert clients.claude.gatewayConfig.source == clients.claude.managedFiles.managed-mcp.source;
    assert clients.antigravity.gatewayConfig.source == clients.antigravity.managedFiles.mcp.source;
    assert clients.codex.gatewayConfig.source != clients.codex.managedFiles.system.source;
    assert clients.opencode.gatewayConfig.source != clients.opencode.managedFiles.config.source;
    assert lib.any (
      definition:
      lib.hasInfix "/agents/module.nix" (toString definition.file)
      && lib.elem hostConfig.dotfiles.containers.agentmemory.clients.hooks definition.value
    ) hostOptions.environment.systemPackages.definitionsWithLocations;
    assert
      clients.opencode.managedFiles.agentmemory-plugin.source
      == hostConfig.dotfiles.containers.agentmemory.clients.opencodePlugin;
    assert !(builtins.hasAttr "containers/agentmemory/opencode-capture" artifacts);
    assert lib.all (
      definition:
      lib.hasInfix "/agents/" (toString definition.file)
      && !lib.hasInfix "/containers/" (toString definition.file)
    ) hostOptions.dotfiles.agents.clients.definitionsWithLocations;
    pkgs.runCommandLocal "check-agent-artifact-contract"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.remarshal
          pkgs.ripgrep
          pkgs.taplo
        ];
        codexDefinitionSources = lib.concatStringsSep " " (map toString codexDefinitionSources);
      }
      ''
        set -euo pipefail

        ${installAgentsExe} --print-manifest > install-manifest.json
        jq --sort-keys . install-manifest.json > actual-install-manifest.json
        printf '%s' ${lib.escapeShellArg (builtins.toJSON expectedInstallManifest)} \
          | jq --sort-keys . > expected-install-manifest.json
        diff --unified expected-install-manifest.json actual-install-manifest.json
        if grep -Fq 'read -r -a args' ${installAgentsExe} || grep -Fq "IFS='|'" ${installAgentsExe}; then
          echo "installer loses argument boundaries" >&2
          exit 1
        fi
        grep -Fq 'decode_version_args() {' ${installAgentsExe}
        grep -Fq 'run_version_check() {' ${installAgentsExe}
        if rg -n 'source .*version-args\.sh|/(nix/store|home)/[^ ]*version-args\.sh' ${installAgentsExe}; then
          echo "generated installer references an external versionArgs decoder" >&2
          exit 1
        fi

        cat > fake-version <<'SCRIPT'
        #!${pkgs.runtimeShell}
        printf '%s\0' "$@" > "$ARG_CAPTURE"
        SCRIPT
        chmod +x fake-version
        export ARG_CAPTURE=$PWD/version-args
        source ${./impl/version-args.sh}
        # contract は空 argv を拒否する。decoder 単体では lossless transport の上位集合として空文字も保持する。
        run_version_check "$PWD/fake-version" ${
          lib.escapeShellArg (builtins.toJSON (losslessVersionArgs ++ [ "" ]))
        }
        mapfile -d $'\0' -t captured < "$ARG_CAPTURE"
        test "''${#captured[@]}" -eq 6
        test "''${captured[0]}" = $'trailing\n'
        test "''${captured[1]}" = $'\n'
        test "''${captured[2]}" = $'embedded\nline'
        test "''${captured[3]}" = '  spaced  '
        test "''${captured[4]}" = 'pipe|value'
        test -z "''${captured[5]}"

        fixtureHome=$PWD/installer-home
        mkdir -p "$fixtureHome/.local/bin"
        cat > "$fixtureHome/.local/bin/curl" <<'SCRIPT'
        #!${pkgs.runtimeShell}
        exit 0
        SCRIPT
        cat > "$fixtureHome/.local/bin/argv-capture" <<'SCRIPT'
        #!${pkgs.runtimeShell}
        printf '%s\0' "$@" > "$ARG_CAPTURE"
        SCRIPT
        chmod +x "$fixtureHome/.local/bin/curl" "$fixtureHome/.local/bin/argv-capture"
        export HOME=$fixtureHome
        export ARG_CAPTURE=$PWD/generated-installer-version-args
        ${losslessInstallAgentsExe}
        mapfile -d $'\0' -t generatedCaptured < "$ARG_CAPTURE"
        test "''${#generatedCaptured[@]}" -eq 5
        test "''${generatedCaptured[0]}" = $'trailing\n'
        test "''${generatedCaptured[1]}" = $'\n'
        test "''${generatedCaptured[2]}" = $'embedded\nline'
        test "''${generatedCaptured[3]}" = '  spaced  '
        test "''${generatedCaptured[4]}" = 'pipe|value'

        claudeCapabilities=${
          clients.claude.managedFiles.${clients.claude.capabilityManagedFiles.agentmemory}.source
        }
        test "$claudeCapabilities" = ${
          clients.claude.managedFiles.${clients.claude.capabilityManagedFiles.telemetry}.source
        }
        jq --exit-status \
          --arg endpoint ${lib.escapeShellArg hostConfig.dotfiles.telemetry.endpoint} \
          --arg protocol ${lib.escapeShellArg hostConfig.dotfiles.telemetry.protocol} \
          --argjson hooks ${lib.escapeShellArg (builtins.toJSON expectedClaudeHooks)} '
          .env.CLAUDE_CODE_ENABLE_TELEMETRY == "1" and
          .env.OTEL_METRICS_EXPORTER == "otlp" and
          .env.OTEL_LOGS_EXPORTER == "otlp" and
          .env.OTEL_EXPORTER_OTLP_ENDPOINT == $endpoint and
          .env.OTEL_EXPORTER_OTLP_PROTOCOL == $protocol and
          .hooks == $hooks
        ' "$claudeCapabilities" > /dev/null

        codexCapabilities=${
          clients.codex.managedFiles.${clients.codex.capabilityManagedFiles.agentmemory}.source
        }
        remarshal -if toml -of json "$codexCapabilities" \
          | jq --exit-status \
            --argjson hooks ${lib.escapeShellArg (builtins.toJSON expectedCodexHooks)} '
            .hooks == $hooks
          ' > /dev/null

        grep -Fq 'skill の runtime drift は検査しない' ${self}/agents/shared/AGENTS.md
        grep -Fq 'managed file の runtime drift は検査しない' ${self}/docs/architecture/ai-tooling.md

        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcpServers: {gateway: {type: "http", url: $expected}}}' \
          ${clients.claude.gatewayConfig.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcpServers: {gateway: {serverUrl: $expected}}}' \
          ${clients.antigravity.gatewayConfig.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '. == {mcp: {gateway: {type: "remote", url: $expected}}}' \
          ${clients.opencode.gatewayConfig.source} > /dev/null
        remarshal -if toml -of json ${clients.codex.gatewayConfig.source} \
          | jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
            '. == {mcp_servers: {gateway: {url: $expected}}}' > /dev/null

        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl} \
          '.mcp == {gateway: {type: "remote", url: $expected}}' \
          ${artifactSource "agents/opencode/config"} > /dev/null
        codex_mcp_matches() {
          local expected=$1
          jq --exit-status --arg expected "$expected" \
            '.mcp_servers == {gateway: {url: $expected}}'
        }
        remarshal -if toml -of json ${artifactSource "agents/codex/system"} > codex-system.json
        codex_mcp_matches ${lib.escapeShellArg gatewayUrl} < codex-system.json > /dev/null
        jq --exit-status \
          --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.cache/dotfiles-wsl"} \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/state/dotfiles-wsl"} '
          .permissions.dev.filesystem == {($cacheRoot): "write", ($stateRoot): "write"} and
          .permissions["agent-read-only"] == {
            extends: ":read-only",
            filesystem: {($cacheRoot): "write", ($stateRoot): "write"}
          } and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' codex-system.json > /dev/null
        remarshal -if toml -of json ${artifactSource "agents/codex/project"} > codex-project.json
        jq --exit-status \
          --arg cacheRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.cache/dotfiles-wsl"} \
          --arg stateRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/state/dotfiles-wsl"} \
          --arg gitRoot ${lib.escapeShellArg "${hostConfig.dotfiles.host.dotfilesDir}/.git"} '
          .permissions.dev.filesystem == {($gitRoot): "write"} and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' codex-project.json > /dev/null
        remarshal -if toml -of json \
          ${clients.codex.managedFiles.user.source} > codex-user-seed.json
        grep -Fq '"@homeDir@/workspace"' ${self}/agents/codex/assets/config.toml
        grep -Fq '"@homeDir@/projects"' ${self}/agents/codex/assets/config.toml
        if rg -n '/home/nixos/(workspace|projects)' ${self}/agents/codex/assets/config.toml; then
          echo "Codex seed hard-codes the host home directory" >&2
          exit 1
        fi
        jq --exit-status \
          --arg homeDir ${lib.escapeShellArg hostConfig.dotfiles.host.homeDir} '
          .default_permissions == "dev" and
          .permissions.dev.description == "workspace general profile" and
          .permissions.dev.extends == ":workspace" and
          .permissions.dev.filesystem == {
            ":workspace_roots": {".": "write", ".git": "write"},
            ($homeDir + "/workspace"): "write",
            ($homeDir + "/projects"): "write"
          } and
          .permissions.dev.network == {enabled: true} and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' codex-user-seed.json > /dev/null
        for definition in $codexDefinitionSources; do
          remarshal -if toml -of json "$definition" > codex-definition.json
          jq --exit-status '
            (has("sandbox_mode") | not) and
            (has("sandbox_workspace_write") | not) and
            if (.name | IN("architect", "explorer", "planner", "reviewer", "security"))
            then
              .default_permissions == "agent-read-only" and
              (has("permissions") | not)
            else
              (has("default_permissions") | not) and
              (has("permissions") | not)
            end
          ' codex-definition.json > /dev/null
        done
        jq '.mcp_servers.extra = {url: "https://unexpected.invalid/mcp"}' \
          codex-system.json > codex-system-extra-server.json
        if codex_mcp_matches ${lib.escapeShellArg gatewayUrl} \
          < codex-system-extra-server.json > /dev/null; then
          echo "Codex system config accepted an undeclared MCP server" >&2
          exit 1
        fi

        jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
          '.mcpServers.gateway.url == $expected and (.mcpServers | keys) == ["gateway"]' \
          ${variantClients.claude.managedFiles.managed-mcp.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
          '.mcpServers.gateway.serverUrl == $expected and (.mcpServers | keys) == ["gateway"]' \
          ${variantClients.antigravity.managedFiles.mcp.source} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg variantGatewayUrl} \
          '.mcp.gateway.url == $expected and (.mcp | keys) == ["gateway"]' \
          ${variantClients.opencode.managedFiles.config.source} > /dev/null
        remarshal -if toml -of json ${variantClients.codex.managedFiles.system.source} \
          > codex-system-variant.json
        codex_mcp_matches ${lib.escapeShellArg variantGatewayUrl} \
          < codex-system-variant.json > /dev/null

        fixture=$PWD/seed-symlink-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
        ln -s nowhere "$fixture/home/.codex/config.toml"
        if (${fixtureSeedActivation}); then
          echo "Codex seed activation accepted a symlink" >&2
          exit 1
        fi
        grep -Fxq keep-regular "$fixture/home/.claude/settings.json"
        test -L "$fixture/home/.codex/config.toml"

        fixture=$PWD/seed-symlink-parent-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/actual-codex"
        printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
        cat > "$fixture/home/actual-codex/config.toml" <<'TOML'
        sandbox_mode = "workspace-write"
        TOML
        ln -s actual-codex "$fixture/home/.codex"
        if (${fixtureSeedActivation}); then
          echo "Codex seed activation accepted a symlink parent" >&2
          exit 1
        fi
        grep -Fq 'sandbox_mode = "workspace-write"' \
          "$fixture/home/actual-codex/config.toml"

        cat > fake-stat <<'SCRIPT'
        #!${pkgs.runtimeShell}
        set -euo pipefail
        result=$(${pkgs.coreutils}/bin/stat "$@")
        path=''${!#}
        if [ "''${FIXTURE_STAT_WRONG_OWNER_PATH:-}" = "$path" ] \
          && [ "$1" = -c ] && [ "$2" = '%u:%d:%i' ]; then
          owner=''${result%%:*}
          printf '%s:%s\n' "$((owner + 1))" "''${result#*:}"
        else
          printf '%s\n' "$result"
        fi
        SCRIPT
        chmod +x fake-stat
        export FIXTURE_STAT=$PWD/fake-stat

        mapfile -t migration_exes < <(
          rg --only-matching \
            '/nix/store/[a-z0-9]+-dotfiles-migrate-codex-config/bin/dotfiles-migrate-codex-config' \
            ${fixtureSeedActivationScript} | sort -u
        )
        test "''${#migration_exes[@]}" -eq 1
        sed "s|''${migration_exes[0]}|${fixtureMigrateCodexConfig}|g" \
          ${fixtureSeedActivationScript} > fixture-owner-seed-activation
        chmod +x fixture-owner-seed-activation

        fixture=$PWD/seed-parent-owner-fixture
        export fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' 'sandbox_mode = "workspace-write"' \
          > "$fixture/home/.codex/config.toml"
        before=$(sha256sum "$fixture/home/.codex/config.toml")
        export FIXTURE_STAT_WRONG_OWNER_PATH=$fixture/home/.codex
        if ./fixture-owner-seed-activation; then
          echo "Codex seed activation accepted another owner for the target directory" >&2
          exit 1
        fi
        test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"

        fixture=$PWD/seed-target-owner-fixture
        export fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' 'sandbox_mode = "workspace-write"' \
          > "$fixture/home/.codex/config.toml"
        before=$(sha256sum "$fixture/home/.codex/config.toml")
        export FIXTURE_STAT_WRONG_OWNER_PATH=$fixture/home/.codex/config.toml
        if ./fixture-owner-seed-activation; then
          echo "Codex seed activation accepted another owner for the target" >&2
          exit 1
        fi
        test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"
        unset FIXTURE_STAT_WRONG_OWNER_PATH

        cat > fake-mktemp <<'SCRIPT'
        #!${pkgs.runtimeShell}
        set -euo pipefail
        count=0
        if [ -f "$FIXTURE_MKTEMP_COUNT" ]; then
          count=$(<"$FIXTURE_MKTEMP_COUNT")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$FIXTURE_MKTEMP_COUNT"
        if [ "''${FIXTURE_MKTEMP_FAIL_SECOND:-0}" = 1 ] && [ "$count" -eq 2 ]; then
          exit 1
        fi
        path=$(${pkgs.coreutils}/bin/mktemp "$@")
        if [ "$count" -eq 1 ]; then
          printf '%s\n' "$path" > "$FIXTURE_FIRST_TEMP"
        fi
        printf '%s\n' "$path"
        SCRIPT
        chmod +x fake-mktemp

        cat > fake-remarshal <<'SCRIPT'
        #!${pkgs.runtimeShell}
        set -euo pipefail
        count=0
        if [ -f "$FIXTURE_REMARSHAL_COUNT" ]; then
          count=$(<"$FIXTURE_REMARSHAL_COUNT")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$FIXTURE_REMARSHAL_COUNT"
        ${lib.getExe pkgs.remarshal} "$@"
        if [ "''${FIXTURE_REPLACE_TARGET_ON_THIRD:-0}" = 1 ] && [ "$count" -eq 3 ]; then
          ${pkgs.coreutils}/bin/mv -T \
            "$FIXTURE_REPLACEMENT_SOURCE" "$FIXTURE_REPLACE_TARGET"
        fi
        SCRIPT
        chmod +x fake-remarshal

        fixture=$PWD/migration-cleanup-fixture
        mkdir -p "$fixture/home/.codex"
        printf '%s\n' 'sandbox_mode = "workspace-write"' \
          > "$fixture/home/.codex/config.toml"
        export FIXTURE_MKTEMP=$PWD/fake-mktemp
        export FIXTURE_REMARSHAL=$PWD/fake-remarshal
        export FIXTURE_MKTEMP_COUNT=$fixture/mktemp-count
        export FIXTURE_FIRST_TEMP=$fixture/first-temp
        export FIXTURE_REMARSHAL_COUNT=$fixture/remarshal-count
        export FIXTURE_MKTEMP_FAIL_SECOND=1
        if ${fixtureMigrateCodexConfig} \
          "$fixture/home/.codex/config.toml" "$fixture/home"; then
          echo "Codex migration accepted a failed second mktemp" >&2
          exit 1
        fi
        first_temp=$(<"$FIXTURE_FIRST_TEMP")
        test ! -e "$first_temp"

        fixture=$PWD/migration-race-fixture
        mkdir -p "$fixture/home/.codex"
        printf '%s\n' 'sandbox_mode = "workspace-write"' \
          > "$fixture/home/.codex/config.toml"
        printf '%s\n' 'replacement = true' > "$fixture/replacement.toml"
        : > "$fixture/mktemp-count"
        : > "$fixture/remarshal-count"
        printf '0\n' > "$fixture/mktemp-count"
        printf '0\n' > "$fixture/remarshal-count"
        export FIXTURE_MKTEMP_COUNT=$fixture/mktemp-count
        export FIXTURE_FIRST_TEMP=$fixture/first-temp
        export FIXTURE_REMARSHAL_COUNT=$fixture/remarshal-count
        export FIXTURE_MKTEMP_FAIL_SECOND=0
        export FIXTURE_REPLACE_TARGET_ON_THIRD=1
        export FIXTURE_REPLACE_TARGET=$fixture/home/.codex/config.toml
        export FIXTURE_REPLACEMENT_SOURCE=$fixture/replacement.toml
        if ${fixtureMigrateCodexConfig} \
          "$fixture/home/.codex/config.toml" "$fixture/home"; then
          echo "Codex migration published over a replaced target" >&2
          exit 1
        fi
        grep -Fxq 'replacement = true' "$fixture/home/.codex/config.toml"
        unset FIXTURE_REPLACE_TARGET_ON_THIRD FIXTURE_REPLACE_TARGET \
          FIXTURE_REPLACEMENT_SOURCE

        fixture=$PWD/seed-legacy-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf '%s\n' keep-regular > "$fixture/home/.claude/settings.json"
        cat > "$fixture/home/.codex/config.toml" <<'TOML'
        model = "fixture-model"
        sandbox_mode = "workspace-write"
        custom_unknown = "preserved"

        [sandbox_workspace_write]
        network_access = true

        [custom_table]
        answer = 42
        TOML
        ${fixtureSeedActivation}
        remarshal -if toml -of json "$fixture/home/.codex/config.toml" > migrated.json
        jq --exit-status \
          --arg homeDir "$fixture/home" '
          .model == "fixture-model" and
          .custom_unknown == "preserved" and
          .custom_table == {answer: 42} and
          .default_permissions == "dev" and
          .permissions.dev.extends == ":workspace" and
          .permissions.dev.filesystem == {
            ":workspace_roots": {".": "write", ".git": "write"},
            ($homeDir + "/workspace"): "write",
            ($homeDir + "/projects"): "write"
          } and
          .permissions.dev.network == {enabled: true} and
          (has("sandbox_mode") | not) and
          (has("sandbox_workspace_write") | not)
        ' migrated.json > /dev/null
        test "$(stat -c %a "$fixture/home/.codex/config.toml")" = 600

        fixture=$PWD/seed-current-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        cp ${clients.codex.managedFiles.user.source} "$fixture/home/.codex/config.toml"
        before=$(sha256sum "$fixture/home/.codex/config.toml")
        ${fixtureSeedActivation}
        test "$(sha256sum "$fixture/home/.codex/config.toml")" = "$before"

        fixture=$PWD/seed-invalid-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        printf 'not = [valid\n' > "$fixture/home/.codex/config.toml"
        if (${fixtureSeedActivation}); then
          echo "Codex seed activation accepted invalid TOML" >&2
          exit 1
        fi

        fixture=$PWD/seed-nonregular-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex/config.toml"
        if (${fixtureSeedActivation}); then
          echo "Codex seed activation accepted a non-regular file" >&2
          exit 1
        fi

        fixture=$PWD/seed-missing-fixture
        mkdir -p "$fixture/home/.claude" "$fixture/home/.codex"
        mkdir "$fixture/home/.claude/settings.json"
        ${fixtureSeedActivation}
        test -d "$fixture/home/.claude/settings.json"
        test -s "$fixture/home/.codex/config.toml"

        rmdir "$fixture/home/.claude/settings.json"
        ${fixtureSeedActivation}
        test -s "$fixture/home/.claude/settings.json"

        test ! -e ${self}/clis
        legacy_root=clis
        legacy_role=cli
        legacy_option=m
        legacy_option+='y\.'
        legacy_pattern="$legacy_option''${legacy_root}|dotfiles-install-''${legacy_root}|dotfiles-''${legacy_role}-autoupdate|''${legacy_root}/assets|''${legacy_root}/(antigravity|claude|codex|opencode)"
        if rg -n "$legacy_pattern" ${self}; then
          echo "legacy clis path or runtime identity remains" >&2
          exit 1
        fi
        if rg -n "$legacy_option"'agents|agents/(antigravity|claude|codex|opencode)' ${self}/containers; then
          echo "container backend declares or depends on agent configuration" >&2
          exit 1
        fi

        touch $out
      '';

  agent-definition-rendering =
    assert clients.claude.definitions == hostConfig.dotfiles.agents.shared.definitions;
    assert clients.antigravity.definitions == { };
    assert sharedDefinitionSources != [ ];
    assert codexDefinitionSources != [ ];
    assert opencodeDefinitionSources != [ ];
    assert lib.all (source: lib.hasPrefix builtins.storeDir (toString source)) (
      builtins.attrValues hostConfig.dotfiles.agents.shared.skills
    );
    pkgs.runCommandLocal "check-agent-definition-rendering"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.glibc.bin
          pkgs.gnugrep
          pkgs.jq
          pkgs.remarshal
          pkgs.yq
        ];
        rulesSource = hostConfig.dotfiles.agents.shared.rules;
        sharedSources = sharedDefinitionSources;
        claudeSources = claudeDefinitionSources;
        codexSources = codexDefinitionSources;
        opencodeSources = opencodeDefinitionSources;
      }
      ''
        set -euo pipefail

        test -s "$rulesSource"
        iconv -f UTF-8 -t UTF-8 "$rulesSource" > /dev/null
        grep -Eq '^#{1,6}[[:space:]]+[^[:space:]]' "$rulesSource"

        check_frontmatter() {
          local source=$1 closing
          test "$(head -n 1 "$source")" = '---'
          closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$source")
          test -n "$closing"
          sed -n "2,$((closing - 1))p" "$source" > frontmatter.yaml
          tail -n "+$((closing + 1))" "$source" > body.md
          yq '.' frontmatter.yaml > /dev/null
          grep -Eq '[^[:space:]]' body.md
        }

        for source in $sharedSources; do
          check_frontmatter "$source"
        done
        for source in $opencodeSources; do
          check_frontmatter "$source"
        done
        for source in $codexSources; do
          remarshal -if toml -of json "$source" > definition.json
          jq --exit-status '.developer_instructions | length > 0' definition.json > /dev/null
        done

        paste \
          <(printf '%s\n' $sharedSources) \
          <(printf '%s\n' $claudeSources) \
          | while IFS=$'\t' read -r shared claude; do
              cmp "$shared" "$claude"
            done

        touch $out
      '';

  lsp-registration =
    pkgs.runCommandLocal "check-lsp-registration"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.coreutils
        ];
      }
      ''
        set -euo pipefail

        managedSettings=${artifactSource "agents/claude/managed-settings"}
        marketplace=$(jq -r '.extraKnownMarketplaces.dotfiles.source.path' "$managedSettings")
        claudeLsp="$marketplace/lsp/.lsp.json"

        jq --sort-keys 'keys' "$claudeLsp" > claude-names.json
        jq --sort-keys '.lsp | keys' ${artifactSource "agents/opencode/config"} > opencode-names.json
        printf '%s' ${lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster))} \
          | jq --sort-keys '.' > expected-names.json
        diff --unified expected-names.json claude-names.json
        diff --unified expected-names.json opencode-names.json

        ${lib.concatMapStrings (name: ''
          jq --exit-status \
            --arg command ${lib.escapeShellArg roster.${name}.command} \
            --argjson args ${lib.escapeShellArg (builtins.toJSON roster.${name}.args)} \
            --argjson extensions ${lib.escapeShellArg (builtins.toJSON roster.${name}.extensions)} \
            --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
            .["${name}"].command == $command and
            (.["${name}"].args // []) == $args and
            .["${name}"].extensionToLanguage == $extensions and
            (.["${name}"].initializationOptions // {}) == $options
          ' "$claudeLsp" > /dev/null

          jq --exit-status \
            --argjson command ${
              lib.escapeShellArg (builtins.toJSON ([ roster.${name}.command ] ++ roster.${name}.args))
            } \
            --argjson extensions ${
              lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster.${name}.extensions))
            } \
            --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
            .lsp["${name}"].command == $command and
            (.lsp["${name}"].extensions | sort) == ($extensions | sort) and
            (.lsp["${name}"].initialization // {}) == $options
          ' ${artifactSource "agents/opencode/config"} > /dev/null
        '') (builtins.attrNames roster)}

        jq -r '.[].extensionToLanguage | keys[]' "$claudeLsp" | sort > extensions
        test "$(sort -u extensions | wc -l)" = "$(wc -l < extensions)"

        jq --exit-status '
          .extraKnownMarketplaces.dotfiles.source.source == "directory" and
          .enabledPlugins["lsp@dotfiles"] == true
        ' "$managedSettings" > /dev/null
        jq --exit-status '
          .name == "dotfiles" and
          (.plugins | length) == 1 and
          .plugins[0].name == "lsp" and
          .plugins[0].source == "./lsp" and
          (.plugins[0].version | length) > 0
        ' "$marketplace/.claude-plugin/marketplace.json" > /dev/null
        touch $out
      '';

  agent-runtime-contract =
    assert builtins.head homeConfig.home.sessionPath == "$HOME/${wrapperDirectory}";
    assert lib.elem "$HOME/.local/bin" homeConfig.home.sessionPath;
    assert
      runtimeClientNames == [
        "claude"
        "codex"
        "opencode"
      ];
    assert builtins.all (
      name:
      let
        target = "${wrapperDirectory}/${clients.${name}.binary}";
      in
      builtins.hasAttr target homeConfig.home.file && homeConfig.home.file.${target}.executable
    ) runtimeClientNames;
    assert !(builtins.hasAttr "${wrapperDirectory}/${clients.antigravity.binary}" homeConfig.home.file);
    pkgs.runCommandLocal "check-agent-runtime-contract" { } ''
      set -euo pipefail
      ${lib.concatMapStrings (name: ''
        wrapper=${homeConfig.home.file."${wrapperDirectory}/${clients.${name}.binary}".source}
        grep -Fq ${lib.escapeShellArg "${hostConfig.dotfiles.host.homeDir}/.local/bin/${clients.${name}.binary}"} "$wrapper"
        grep -Fq ${lib.escapeShellArg (lib.getExe runtime.launcher)} "$wrapper"
      '') runtimeClientNames}
      touch $out
    '';

  agent-runtime-behavior =
    pkgs.runCommandLocal "check-agent-runtime-behavior"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnused
          pkgs.jq
        ];
        LAUNCHER = lib.getExe runtime.launcher;
        AGENT_SHIM_DIR = runtime.agentShims;
        GIT_SHIM_DIR = fixtureAgentShims;
      }
      ''
        bash ${./fixtures/runtime/launcher.sh}
        bash ${./fixtures/runtime/git-shim.sh}
        touch $out
      '';

  agent-nix-build-shims =
    pkgs.runCommandLocal "check-agent-nix-build-shims"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
        ];
        SHIM_DIR = fixtureNixBuildShims;
      }
      ''
        bash ${./fixtures/runtime/nix-build-shims.sh}
        touch $out
      '';

  agent-project-cache-gc =
    assert lib.count (package: package == runtime.gc) hostConfig.environment.systemPackages == 1;
    assert
      hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.ExecStart
      == lib.getExe runtime.gc;
    assert
      hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.User
      == hostConfig.dotfiles.host.username;
    assert hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.Type == "oneshot";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.OnCalendar == "daily";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.Persistent;
    pkgs.runCommandLocal "check-agent-project-cache-gc"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        GC = lib.getExe runtime.gc;
        MUTATION_GC = lib.getExe mutationGc;
        RMDIR_RACE_GC = lib.getExe rmdirRaceGc;
        WRONG_OWNER_GC = lib.getExe wrongOwnerGc;
      }
      ''
        bash ${./fixtures/runtime/project-cache-gc.sh}
        touch $out
      '';

  agent-verification-cache =
    assert lib.count (package: package == runtime.verify) hostConfig.environment.systemPackages == 1;
    pkgs.runCommandLocal "check-agent-verification-cache"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.git
          pkgs.gnused
        ];
        VERIFY = lib.getExe runtime.verify;
      }
      ''
        bash ${./fixtures/runtime/verify.sh}
        touch $out
      '';

  agent-resource-contract =
    let
      agentResource = agentConfig.agentResource;
      agentWorktree = agentConfig.agentWorktree;
      resourceSource = builtins.readFile ./impl/resource/agent-resource.sh;
      worktreeSource = builtins.readFile ./impl/resource/agent-worktree.sh;
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
        map (package: if package == expected then replacement else package) (
          hostConfig.environment.systemPackages
        );
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
      expectedReaperEnvironment = "HOME=${hostConfig.dotfiles.host.homeDir}";
      reaperServiceConfigValid =
        serviceConfig:
        serviceConfig.Type == "oneshot"
        && serviceConfig.User == hostConfig.dotfiles.host.username
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
      && hostConfig.dotfiles.commands.agentResource == runtime.agentResource
      && hostConfig.dotfiles.commands.agentWorktree == runtime.agentWorktree
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
      reaper.serviceConfig.User == hostConfig.dotfiles.host.username
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
        export OVERFLOW_RESOURCE=${lib.getExe overflowResource}
        export SEVEN_DAY_RESOURCE=${lib.getExe sevenDayRuntime.agentResource}
        export TEST_BASH=${lib.getExe pkgs.bash}
        ${lib.getExe pkgs.bash} ${./fixtures/resource/agent-resources.sh}
        touch $out
      '';
}
