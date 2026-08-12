{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  ...
}:

let
  agentConfig = hostConfig.dotfiles.agents;
  inherit (agentConfig) clients;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
  installAgents = hostConfig.dotfiles.commands.installAgents;
  runtime = import ../package.nix {
    inherit lib pkgs;
    runtimeContract = runtimePackageContract;
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
      ${runtime.projectCacheGcSource}
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
      ${runtime.projectCacheGcSource}
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
      ${runtime.projectCacheGcSource}
    '';
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
  runtimeClientNames = builtins.filter (name: clients.${name}.runtimeWrapperMode == "managed") (
    builtins.attrNames clients
  );

  observationTimeoutSeconds = 10;
  homeDir = hostConfig.dotfiles.host.homeDir;
  runtimeContractSupport = import ./support/runtime-contract.nix {
    inherit homeDir;
  };
  inherit (runtimeContractSupport) expectedAgentRuntime runtimePackageContract;
  selectAgentObservations = lib.filterAttrs (name: _: lib.hasPrefix "agents/" name);
  agentObservations = selectAgentObservations hostConfig.dotfiles.observations;
  commonAgentObservation = checkId: resourceKey: failureMessage: {
    inherit checkId resourceKey failureMessage;
    timeoutSeconds = observationTimeoutSeconds;
  };
  releaseFor =
    client:
    if pkgs.stdenv.hostPlatform.isAarch64 then
      client.install.releaseByArch.aarch64
    else
      client.install.releaseByArch.x86_64;
  expectedClientObservation =
    name: client:
    let
      visiblePath = agentConfig.clientExecutables.${name};
      releaseRoot = "${homeDir}/.local/share/dotfiles/agents/${name}";
      release = if client.install.kind == "github-release" then releaseFor client else null;
    in
    commonAgentObservation "agent/${name}" null
      "${client.binary} is unavailable or its version command failed"
    // (
      if release == null then
        {
          kind = "command-version";
          path = visiblePath;
          expectedSource = visiblePath;
          inherit (client) versionArgs;
        }
      else
        {
          kind = "release-tree";
          inherit visiblePath;
          visibleTarget = "../share/dotfiles/agents/${name}/current/${release.entrypoint}";
          currentLink = "${releaseRoot}/current";
          releasesRoot = "${releaseRoot}/releases";
          inherit (release) entrypoint;
          inherit (client.install) requiredPaths;
          inherit (client) versionArgs;
        }
    );
  timerObservation = name: {
    kind = "systemd-timer";
    checkId = "maintenance/${name}.timer";
    resourceKey = null;
    timeoutSeconds = observationTimeoutSeconds;
    failureMessage = "${name}.timer or its service is not operational";
    timer = "${name}.timer";
    service = "${name}.service";
    unitFileStates = [
      "enabled"
      "enabled-runtime"
    ];
    activeStates = [ "active" ];
    serviceResults = [ "success" ];
  };
  expectedAgentObservations = {
    "agents/roster" = commonAgentObservation "agent-roster" null "agent roster is empty" // {
      kind = "roster";
      members = agentConfig.enabled;
      minimumCount = 1;
      failureOnly = true;
    };
    "agents/managed-roots" =
      commonAgentObservation "resource/managed-roots" "managedRoots"
        "could not summarize every managed resource root"
      // {
        kind = "managed-roots";
        paths = with expectedAgentRuntime; [
          cache.buildsRoot
          cache.sharedRoot
          cache.sessionsRoot
          state.resourcesRoot
        ];
        missingAsZero = true;
        oneFileSystem = true;
        cachePolicy = "allocated-bytes";
      };
    "agents/maintenance/project-cache-gc" =
      timerObservation expectedAgentRuntime.timers.projectCacheGc.name;
    "agents/maintenance/resource-reaper" =
      timerObservation expectedAgentRuntime.timers.resourceReaper.name;
  }
  // lib.mapAttrs' (
    name: client: lib.nameValuePair "agents/client/${name}" (expectedClientObservation name client)
  ) clients;
  agentObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/agents/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  agentDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) agentObservationDefinitions
  );
  runtimeConfiguration = configuration: {
    runtime = configuration.dotfiles.agents.runtime;
    services = lib.genAttrs [
      expectedAgentRuntime.timers.autoupdate.name
      expectedAgentRuntime.timers.projectCacheGc.name
      expectedAgentRuntime.timers.resourceReaper.name
    ] (name: configuration.systemd.services.${name} or null);
    timers = lib.genAttrs [
      expectedAgentRuntime.timers.autoupdate.name
      expectedAgentRuntime.timers.projectCacheGc.name
      expectedAgentRuntime.timers.resourceReaper.name
    ] (name: configuration.systemd.timers.${name} or null);
  };
  expectedRuntimeConfiguration = runtimeConfiguration hostConfig;
  timerWiringMatches =
    candidate:
    let
      timerMatches =
        id: timerContract:
        let
          service = candidate.services.${timerContract.name} or null;
          timer = candidate.timers.${timerContract.name} or null;
          expectedTimerConfig = {
            OnCalendar = timerContract.onCalendar;
            Persistent = timerContract.persistent;
          }
          // lib.optionalAttrs (id == "resourceReaper") {
            Unit = "${timerContract.name}.service";
          };
        in
        service != null
        && timer != null
        && service.serviceConfig.Type == "oneshot"
        && service.serviceConfig.User == hostConfig.dotfiles.host.username
        && timer.wantedBy == [ "timers.target" ]
        && timer.timerConfig == expectedTimerConfig
        && (
          if id == "autoupdate" then
            service.serviceConfig.ExecStart == lib.getExe installAgents
          else if id == "projectCacheGc" then
            service.serviceConfig.ExecStart == lib.getExe runtime.gc
          else
            service.serviceConfig.ExecStart == "${lib.getExe runtime.agentResource} reap"
        );
    in
    candidate.runtime == expectedAgentRuntime
    && lib.all (id: timerMatches id expectedAgentRuntime.timers.${id}) (
      builtins.attrNames expectedAgentRuntime.timers
    );
  agentRuntimeContractMatches =
    candidateRuntime: candidateObservations:
    timerWiringMatches candidateRuntime
    && selectAgentObservations candidateObservations == expectedAgentObservations;
  removeManagedRootMutation = agentObservations // {
    "agents/managed-roots" = agentObservations."agents/managed-roots" or { } // {
      paths = builtins.tail (agentObservations."agents/managed-roots".paths or [ ]);
    };
  };
  highBytesMutation = expectedRuntimeConfiguration // {
    runtime = expectedRuntimeConfiguration.runtime // {
      cache = expectedRuntimeConfiguration.runtime.cache // {
        highBytes = 1;
      };
    };
  };
  lowBytesMutation = expectedRuntimeConfiguration // {
    runtime = expectedRuntimeConfiguration.runtime // {
      cache = expectedRuntimeConfiguration.runtime.cache // {
        lowBytes = 1;
      };
    };
  };
  inactiveDaysMutation = expectedRuntimeConfiguration // {
    runtime = expectedRuntimeConfiguration.runtime // {
      cache = expectedRuntimeConfiguration.runtime.cache // {
        inactiveDays = 1;
      };
    };
  };
  runtimeWithCacheMutation =
    cacheMutation:
    import ../package.nix {
      inherit lib pkgs;
      runtimeContract = runtimePackageContract // {
        cache = runtimePackageContract.cache // cacheMutation;
      };
    };
  highBytesMutationRuntime = runtimeWithCacheMutation { highBytes = 1; };
  lowBytesMutationRuntime = runtimeWithCacheMutation { lowBytes = 1; };
  inactiveDaysMutationRuntime = runtimeWithCacheMutation { inactiveDays = 1; };
  runtimeWithRelativeRootMutation =
    update:
    import ../package.nix {
      inherit lib pkgs;
      runtimeContract = runtimePackageContract // update;
    };
  relativeCacheRootMutationRuntime = runtimeWithRelativeRootMutation {
    cache = runtimePackageContract.cache // {
      relativeCacheRoot = ".cache/dotfiles-wsl-mutated";
    };
  };
  relativeStateRootMutationRuntime = runtimeWithRelativeRootMutation {
    state = runtimePackageContract.state // {
      relativeStateRoot = ".local/state/dotfiles-wsl-mutated";
    };
  };
  relativeResourcesRootMutationRuntime = runtimeWithRelativeRootMutation {
    state = runtimePackageContract.state // {
      relativeResourcesRoot = ".local/state/dotfiles-wsl/agent-resources-mutated";
    };
  };
  packageTreeRequiredPathMutation = agentObservations // {
    "agents/client/codex" = agentObservations."agents/client/codex" or { } // {
      requiredPaths =
        builtins.removeAttrs (agentObservations."agents/client/codex".requiredPaths or { })
          [
            "bin/codex-code-mode-host"
          ];
    };
  };
  removeTimerMutation =
    name:
    expectedRuntimeConfiguration
    // {
      timers = builtins.removeAttrs expectedRuntimeConfiguration.timers [ name ];
    };
  changeTimerMutation =
    name:
    expectedRuntimeConfiguration
    // {
      timers = expectedRuntimeConfiguration.timers // {
        ${name} = expectedRuntimeConfiguration.timers.${name} // {
          timerConfig = expectedRuntimeConfiguration.timers.${name}.timerConfig // {
            OnCalendar = "weekly";
          };
        };
      };
    };
  staleAgentObservationMutation = agentObservations // {
    "agents/stale" = expectedAgentObservations."agents/roster";
  };
  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        systemd.services.dotfiles-agent-autoupdate.description = lib.mkForce "description mutation";
        systemd.services.dotfiles-agent-project-cache-gc.description = lib.mkForce "description mutation";
        systemd.services.dotfiles-agent-resource-reaper.description = lib.mkForce "description mutation";
      }
    ]).config;
in
{
  agent-runtime-contract =
    assert
      builtins.attrNames agentConfig.packages == [
        "agentmemoryHooks"
        "apm"
        "projectCacheGc"
        "verification"
      ];
    assert agentConfig.packages.agentmemoryHooks == hostConfig.dotfiles.agents.agentmemory.hooks;
    assert agentConfig.packages.projectCacheGc == runtime.gc;
    assert agentConfig.packages.verification == runtime.verify;
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
    assert lib.assertMsg (
      builtins.attrNames agentObservations == builtins.attrNames expectedAgentObservations
      && agentObservations == expectedAgentObservations
    ) "agent runtime observation registry is incomplete";
    assert lib.assertMsg (
      agentDefinitionKeys == builtins.attrNames expectedAgentObservations
    ) "agent observations must be defined by the agents owner";
    assert lib.assertMsg
      (agentRuntimeContractMatches expectedRuntimeConfiguration hostConfig.dotfiles.observations)
      "agent runtime contract is not wired to observations, packages, services, or timers";
    assert lib.assertMsg (
      !agentRuntimeContractMatches expectedRuntimeConfiguration removeManagedRootMutation
    ) "agent runtime contract accepted a missing managed root";
    assert lib.assertMsg (
      !agentRuntimeContractMatches highBytesMutation hostConfig.dotfiles.observations
      && !agentRuntimeContractMatches lowBytesMutation hostConfig.dotfiles.observations
      && !agentRuntimeContractMatches inactiveDaysMutation hostConfig.dotfiles.observations
      && runtime.gc != highBytesMutationRuntime.gc
      && runtime.gc != lowBytesMutationRuntime.gc
      && runtime.gc != inactiveDaysMutationRuntime.gc
    ) "agent runtime contract accepted a changed cache policy";
    assert lib.assertMsg (
      !agentRuntimeContractMatches expectedRuntimeConfiguration packageTreeRequiredPathMutation
    ) "agent runtime contract accepted a missing package-tree required path";
    assert lib.assertMsg (lib.all
      (
        timer:
        !agentRuntimeContractMatches (removeTimerMutation timer.name) hostConfig.dotfiles.observations
        && !agentRuntimeContractMatches (changeTimerMutation timer.name) hostConfig.dotfiles.observations
      )
      (builtins.attrValues expectedAgentRuntime.timers)
    ) "agent runtime contract accepted a missing or changed timer";
    assert lib.assertMsg (
      selectAgentObservations descriptionVariantConfig.dotfiles.observations == expectedAgentObservations
    ) "agent observation keys depend on service descriptions";
    assert lib.assertMsg (
      !agentRuntimeContractMatches expectedRuntimeConfiguration staleAgentObservationMutation
    ) "agent runtime contract accepted a stale agent observation";
    assert lib.assertMsg (
      runtime.launcher != relativeCacheRootMutationRuntime.launcher
      && runtime.gc != relativeCacheRootMutationRuntime.gc
      && runtime.verify != relativeCacheRootMutationRuntime.verify
    ) "agent runtime packages ignored a relative cache root mutation";
    assert lib.assertMsg (
      runtime.agentResource != relativeStateRootMutationRuntime.agentResource
      && runtime.agentWorktree != relativeStateRootMutationRuntime.agentWorktree
    ) "agent resource packages ignored a relative state root mutation";
    assert lib.assertMsg (
      runtime.agentResource != relativeResourcesRootMutationRuntime.agentResource
      && runtime.agentWorktree != relativeResourcesRootMutationRuntime.agentWorktree
    ) "agent resource packages ignored a relative resources root mutation";
    pkgs.runCommandLocal "check-agent-runtime-contract"
      {
        nativeBuildInputs = [ pkgs.gnugrep ];
      }
      ''
        set -euo pipefail
        ${lib.concatMapStrings (name: ''
          wrapper=${homeConfig.home.file."${wrapperDirectory}/${clients.${name}.binary}".source}
          grep -Fq ${lib.escapeShellArg agentConfig.clientExecutables.${name}} "$wrapper"
          grep -Fq ${lib.escapeShellArg (lib.getExe runtime.launcher)} "$wrapper"
        '') runtimeClientNames}
        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe runtime.launcher}
        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe runtime.gc}
        grep -Fq '68719476736' ${lib.getExe runtime.gc}
        grep -Fq '51539607552' ${lib.getExe runtime.gc}
        grep -Fq 'inactive_before=$((now - 30 * 24 * 60 * 60))' ${lib.getExe runtime.gc}
        grep -Fq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"' ${lib.getExe runtime.agentResource}
        grep -Fq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"' ${lib.getExe runtime.agentWorktree}
        grep -Fq 'verification_root="$HOME/.cache/dotfiles-wsl/verification"' ${lib.getExe runtime.verify}

        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl-mutated"' ${lib.getExe relativeCacheRootMutationRuntime.launcher}
        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl-mutated"' ${lib.getExe relativeCacheRootMutationRuntime.gc}
        grep -Fq 'verification_root="$HOME/.cache/dotfiles-wsl-mutated/verification"' ${lib.getExe relativeCacheRootMutationRuntime.verify}
        ! grep -Fxq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe relativeCacheRootMutationRuntime.launcher}
        ! grep -Fxq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe relativeCacheRootMutationRuntime.gc}
        ! grep -Fxq 'verification_root="$HOME/.cache/dotfiles-wsl/verification"' ${lib.getExe relativeCacheRootMutationRuntime.verify}

        grep -Fq 'ensure_directory "$HOME/.local/state/dotfiles-wsl-mutated" true' ${lib.getExe relativeStateRootMutationRuntime.agentResource}
        grep -Fq 'ensure_directory "$HOME/.local/state/dotfiles-wsl-mutated" true' ${lib.getExe relativeStateRootMutationRuntime.agentWorktree}
        ! grep -Fxq 'ensure_directory "$HOME/.local/state/dotfiles-wsl" true' ${lib.getExe relativeStateRootMutationRuntime.agentResource}
        ! grep -Fxq 'ensure_directory "$HOME/.local/state/dotfiles-wsl" true' ${lib.getExe relativeStateRootMutationRuntime.agentWorktree}

        grep -Fq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources-mutated"' ${lib.getExe relativeResourcesRootMutationRuntime.agentResource}
        grep -Fq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources-mutated"' ${lib.getExe relativeResourcesRootMutationRuntime.agentWorktree}
        ! grep -Fxq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"' ${lib.getExe relativeResourcesRootMutationRuntime.agentResource}
        ! grep -Fxq 'state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"' ${lib.getExe relativeResourcesRootMutationRuntime.agentWorktree}
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
          pkgs.util-linux
        ];
        LAUNCHER = lib.getExe runtime.launcher;
        AGENT_SHIM_DIR = runtime.agentShims;
        GIT_SHIM_DIR = fixtureAgentShims;
      }
      ''
        bash ${../fixtures/runtime/launcher.sh}
        bash ${../fixtures/runtime/git-shim.sh}
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
        bash ${../fixtures/runtime/nix-build-shims.sh}
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
        bash ${../fixtures/runtime/project-cache-gc.sh}
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
        bash ${../fixtures/runtime/verify.sh}
        touch $out
      '';
}
