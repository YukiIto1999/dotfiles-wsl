{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  pluginSources,
  ...
}:

let
  agentConfig = hostConfig.dotfiles.agents;
  inherit (agentConfig) clients;
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
  verificationEntry = hostConfig.dotfiles.toolchain.verification.entry;
  runtime = import ../package.nix {
    inherit lib pkgs verificationEntry;
    runtimeContract = runtimePackageContract;
  };
  customSkillRootRuntime = import ../package.nix {
    inherit lib pkgs verificationEntry;
    runtimeContract = runtimePackageContract // {
      skillRoots = [ ".local/share/fixture adapter/procedures" ];
    };
  };
  wrongOwnerStat = pkgs.writeShellScriptBin "stat" ''
    if [[ $# -eq 3 && $1 == -c && $2 == %u \
      && $3 == "/proc/''${DOTFILES_AGENT_TEST_WRONG_OWNER_PID-}" ]]; then
      printf '%s\n' "$(( $(${pkgs.coreutils}/bin/id -u) + 1 ))"
      exit 0
    fi
    exec ${pkgs.coreutils}/bin/stat "$@"
  '';
  gcWithCommand =
    name: command:
    pkgs.writeShellApplication {
      name = "dotfiles-agent-project-cache-gc-${name}-fixture";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gawk
        jq
        util-linux
      ];
      text = ''
        export PATH=${command}/bin:$PATH
        ${runtime.projectCacheGcSource}
      '';
    };
  wrongOwnerGc = gcWithCommand "wrong-owner" wrongOwnerStat;
  # trash の削除を止めて、GC がその間 gc.lock を握っていないことと、kill の後を再現する。
  slowTrashRm = pkgs.writeShellScriptBin "rm" ''
    target=''${!#}
    if [[ $target == */trash/* && -n ''${DOTFILES_AGENT_TEST_RM_READY-} ]]; then
      printf '%s\n' "$$" > "$DOTFILES_AGENT_TEST_RM_READY.tmp"
      ${pkgs.coreutils}/bin/mv -T -- "$DOTFILES_AGENT_TEST_RM_READY.tmp" "$DOTFILES_AGENT_TEST_RM_READY"
      while [[ ! -e $DOTFILES_AGENT_TEST_RM_RELEASE ]]; do
        ${pkgs.coreutils}/bin/sleep 0.05
      done
    fi
    exec ${pkgs.coreutils}/bin/rm "$@"
  '';
  slowRmGc = gcWithCommand "slow-rm" slowTrashRm;
  # GC が回収する unit を選んだ後、Cargo の lock を取る前に、別の Cargo の動きを一度だけ差し込む。
  racingMktemp = pkgs.writeShellScriptBin "mktemp" ''
    action=''${DOTFILES_AGENT_TEST_BEFORE_RECLAIM-}
    if [[ -n $action && ''${!#} == */trash/units.* && ! -e $action.done ]]; then
      : > "$action.done"
      ${pkgs.bash}/bin/bash "$action"
    fi
    exec ${pkgs.coreutils}/bin/mktemp "$@"
  '';
  racingGc = gcWithCommand "racing" racingMktemp;
  # sandbox の file system を変えずに atime を更新しない mount を GC に見せる。
  mountOptionsFindmnt = pkgs.writeShellScriptBin "findmnt" ''
    if [[ -n ''${DOTFILES_AGENT_TEST_MOUNT_OPTIONS-} ]]; then
      printf '%s\n' "$DOTFILES_AGENT_TEST_MOUNT_OPTIONS"
      exit 0
    fi
    exec ${pkgs.util-linux}/bin/findmnt "$@"
  '';
  mountOptionsGc = gcWithCommand "mount-options" mountOptionsFindmnt;
  fakeNix = pkgs.writeShellScript "fake-nix-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
  '';
  # systemd-run --scope は自身を scope へ入れた後に command を exec する。sandbox には user
  # manager がないため、引数を記録して同じ process のまま command を exec する。
  fakeSystemdRun = pkgs.writeShellScript "fake-systemd-run" ''
    printf '%s\0' "$@" > "$SYSTEMD_RUN_CAPTURE"
    printf '%s\n' "$$" > "$SYSTEMD_RUN_CAPTURE.pid"
    if [ "''${SYSTEMD_RUN_FAIL-}" = 1 ]; then
      printf 'Failed to connect to user scope bus\n' >&2
      exit 1
    fi
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
      shift
    done
    [ "$#" -gt 1 ] || exit 2
    shift
    exec "$@"
  '';
  fixtureLauncher = runtime.mkLauncher { systemdRunCommand = fakeSystemdRun; };
  cappedUserSlices = map (name: "${name}.slice") (
    builtins.attrNames (
      lib.filterAttrs (_: slice: slice.sliceConfig ? MemoryMax) hostConfig.systemd.user.slices
    )
  );
  fakeGit = pkgs.writeShellScript "fake-git-command" ''
    printf '%s\0' "$@" > "$ARG_CAPTURE"
  '';
  # shim が add の前後に読む worktree 一覧の間へ、別の session の add が割り込んだ状態を再現する。
  racingGit = pkgs.writeShellScript "racing-git-command" ''
    previous=
    for argument in "$@"; do
      if [ "$previous" = worktree ] && [ "$argument" = add ] && [ -n "''${RACE_WORKTREE-}" ]; then
        ${lib.getExe pkgs.git} -C "$RACE_REPO" worktree add -q --detach "$RACE_WORKTREE"
        break
      fi
      previous=$argument
    done
    exec ${lib.getExe pkgs.git} "$@"
  '';
  fixtureNixBuildShims = runtime.mkNixBuildShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
  };
  fixtureAgentShims = runtime.mkAgentShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
    gitCommand = fakeGit;
  };
  racingAgentShims = runtime.mkAgentShims {
    nixCommand = fakeNix;
    nixBuildCommand = fakeNix;
    gitCommand = racingGit;
  };
  deployedGateHook = "${homeConfig.home.file.".omp/agent/hooks/pre".source}/verification-gate.ts";
  hookUsingGate =
    gate:
    pkgs.runCommandLocal "omp-verification-gate-hook.ts" { } ''
      substitute ${deployedGateHook} $out \
        --replace-fail /run/current-system/sw/bin/dotfiles-agent-gate ${gate}
    '';
  hangingGate = pkgs.writeShellScript "hanging-gate" ''
    ${pkgs.coreutils}/bin/sleep 300 &
    printf '%s\n' "$!" > descendant.pid
    wait
  '';
  wrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeClientNames = builtins.filter (name: clients.${name}.runtimeWrapperMode == "managed") (
    builtins.attrNames clients
  );

  observationTimeoutSeconds = 10;
  homeDir = hostConfig.dotfiles.workstation.homeDir;
  runtimeContractSupport = import ./support/runtime-contract.nix {
    inherit homeDir;
  };
  inherit (runtimeContractSupport) expectedAgentRuntime runtimePackageContract;
  selectAgentObservations = lib.filterAttrs (name: _: lib.hasPrefix "agents/" name);
  agentObservations = selectAgentObservations hostConfig.dotfiles.health.observations;
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
  expectedRuntimeObservations = {
    "agents/roster" = commonAgentObservation "agent-roster" null "agent roster is empty" // {
      kind = "roster";
      members = agentConfig.enabled;
      minimumCount = 1;
      failureOnly = true;
    };
    "agents/maintenance/autoupdate" = timerObservation expectedAgentRuntime.timers.autoupdate.name;
    "agents/maintenance/project-cache-gc" =
      timerObservation expectedAgentRuntime.timers.projectCacheGc.name;
    "agents/slice-placement" =
      commonAgentObservation "agent/slice-placement" "agentSlicePlacement"
        "agent client processes run outside agents.slice"
      // {
        kind = "process-slice";
        executableRoots = [
          "${homeDir}/.local/share/claude/versions"
          "${homeDir}/.local/share/dotfiles/agents/codex/releases"
          "${homeDir}/.local/share/dotfiles/agents/omp/releases"
          "${homeDir}/.local/share/dotfiles/agents/opencode/releases"
        ];
        slice = "agents.slice";
      };
  }
  // lib.mapAttrs' (
    name: client: lib.nameValuePair "agents/client/${name}" (expectedClientObservation name client)
  ) clients;
  # agents root の keyspace は runtime contract、作業日誌、記憶の収穫の timer で閉じる。どれでもない key は stale として落とす
  expectedJournalObservations = lib.optionalAttrs agentConfig.journal.enable {
    "agents/maintenance/journal" = timerObservation "dotfiles-agent-journal";
  };
  expectedHarvestObservations =
    lib.optionalAttrs
      (
        agentConfig.memoryHarvest.enable
        && builtins.elem "project-memory" hostConfig.dotfiles.capabilities.resolved
      )
      {
        "agents/maintenance/memory-harvest" = timerObservation "dotfiles-agent-memory-harvest";
      };
  expectedAgentObservations =
    expectedRuntimeObservations // expectedJournalObservations // expectedHarvestObservations;
  definitionKeysIn =
    suffix:
    lib.unique (
      lib.concatMap (definition: builtins.attrNames definition.value) (
        builtins.filter (
          definition: lib.hasSuffix suffix (toString definition.file)
        ) hostOptions.dotfiles.health.observations.definitionsWithLocations
      )
    );
  agentDefinitionKeys = definitionKeysIn "/agents/module.nix";
  journalDefinitionKeys = definitionKeysIn "/agents/journal/module.nix";
  harvestDefinitionKeys = definitionKeysIn "/agents/memory-harvest/module.nix";
  runtimeConfiguration = configuration: {
    runtime = configuration.dotfiles.agents.runtime;
    services = lib.genAttrs [
      expectedAgentRuntime.timers.autoupdate.name
      expectedAgentRuntime.timers.projectCacheGc.name
    ] (name: configuration.systemd.services.${name} or null);
    timers = lib.genAttrs [
      expectedAgentRuntime.timers.autoupdate.name
      expectedAgentRuntime.timers.projectCacheGc.name
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
          };
        in
        service != null
        && timer != null
        && service.serviceConfig.Type == "oneshot"
        && service.serviceConfig.User == hostConfig.dotfiles.workstation.username
        && timer.wantedBy == [ "timers.target" ]
        && timer.timerConfig == expectedTimerConfig
        && (
          if id == "autoupdate" then
            service.serviceConfig.ExecStart
            == hostConfig.systemd.services.dotfiles-agent-autoupdate.serviceConfig.ExecStart
          else
            service.serviceConfig.ExecStart == lib.getExe runtime.gc
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
      inherit lib pkgs verificationEntry;
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
      inherit lib pkgs verificationEntry;
      runtimeContract = runtimePackageContract // update;
    };
  relativeCacheRootMutationRuntime = runtimeWithRelativeRootMutation {
    cache = runtimePackageContract.cache // {
      relativeCacheRoot = ".cache/dotfiles-wsl-mutated";
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
      }
    ]).config;
in
{
  agent-runtime-contract =
    assert
      builtins.attrNames agentConfig.packages == [
        "projectCacheGc"
        "projectMemoryHooks"
        "verification"
        "verificationGate"
      ];
    assert
      agentConfig.packages.projectMemoryHooks
      == hostConfig.dotfiles.capabilities.project-memory.clientIntegrations.hooks;
    assert agentConfig.packages.projectCacheGc == runtime.gc;
    assert agentConfig.packages.verification == runtime.verify;
    assert agentConfig.packages.verificationGate == runtime.gate;
    assert builtins.head homeConfig.home.sessionPath == "$HOME/${wrapperDirectory}";
    assert lib.elem "$HOME/.local/bin" homeConfig.home.sessionPath;
    assert
      runtimeClientNames == [
        "claude"
        "codex"
        "omp"
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
      agentDefinitionKeys == builtins.attrNames expectedRuntimeObservations
    ) "agent observations must be defined by the agents owner";
    assert lib.assertMsg (
      journalDefinitionKeys == builtins.attrNames expectedJournalObservations
    ) "the journal observation must be defined by the journal unit";
    assert lib.assertMsg (
      harvestDefinitionKeys == builtins.attrNames expectedHarvestObservations
    ) "the memory harvest observation must be defined by the memory harvest unit";
    assert lib.assertMsg
      (agentRuntimeContractMatches expectedRuntimeConfiguration hostConfig.dotfiles.health.observations)
      "agent runtime contract is not wired to observations, packages, services, or timers";
    assert lib.assertMsg (
      !agentRuntimeContractMatches highBytesMutation hostConfig.dotfiles.health.observations
      && !agentRuntimeContractMatches lowBytesMutation hostConfig.dotfiles.health.observations
      && !agentRuntimeContractMatches inactiveDaysMutation hostConfig.dotfiles.health.observations
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
        !agentRuntimeContractMatches (removeTimerMutation timer.name) hostConfig.dotfiles.health.observations
        && !agentRuntimeContractMatches (changeTimerMutation timer.name) hostConfig.dotfiles.health.observations
      )
      (builtins.attrValues expectedAgentRuntime.timers)
    ) "agent runtime contract accepted a missing or changed timer";
    assert lib.assertMsg (
      selectAgentObservations descriptionVariantConfig.dotfiles.health.observations
      == expectedAgentObservations
    ) "agent observation keys depend on service descriptions";
    assert lib.assertMsg (
      !agentRuntimeContractMatches expectedRuntimeConfiguration staleAgentObservationMutation
    ) "agent runtime contract accepted a stale agent observation";
    assert lib.assertMsg (
      runtime.launcher != relativeCacheRootMutationRuntime.launcher
      && runtime.gc != relativeCacheRootMutationRuntime.gc
      && runtime.verify != relativeCacheRootMutationRuntime.verify
    ) "agent runtime packages ignored a relative cache root mutation";
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
        grep -Fq 'verification_root="$HOME/.cache/dotfiles-wsl/verification"' ${lib.getExe runtime.verify}

        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl-mutated"' ${lib.getExe relativeCacheRootMutationRuntime.launcher}
        grep -Fq 'cache_root="$HOME/.cache/dotfiles-wsl-mutated"' ${lib.getExe relativeCacheRootMutationRuntime.gc}
        grep -Fq 'verification_root="$HOME/.cache/dotfiles-wsl-mutated/verification"' ${lib.getExe relativeCacheRootMutationRuntime.verify}
        ! grep -Fxq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe relativeCacheRootMutationRuntime.launcher}
        ! grep -Fxq 'cache_root="$HOME/.cache/dotfiles-wsl"' ${lib.getExe relativeCacheRootMutationRuntime.gc}
        ! grep -Fxq 'verification_root="$HOME/.cache/dotfiles-wsl/verification"' ${lib.getExe relativeCacheRootMutationRuntime.verify}
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
        LAUNCHER = lib.getExe fixtureLauncher;
        CAPPED_SLICES = lib.concatStringsSep " " cappedUserSlices;
        AGENT_SHIM_DIR = runtime.agentShims;
        GIT_SHIM_DIR = fixtureAgentShims;
        RACING_GIT_SHIM_DIR = racingAgentShims;
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
      == hostConfig.dotfiles.workstation.username;
    assert hostConfig.systemd.services.dotfiles-agent-project-cache-gc.serviceConfig.Type == "oneshot";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.OnCalendar == "daily";
    assert hostConfig.systemd.timers.dotfiles-agent-project-cache-gc.timerConfig.Persistent;
    pkgs.runCommandLocal "check-agent-project-cache-gc"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
          pkgs.rustc
          pkgs.stdenv.cc
          pkgs.util-linux
        ];
        GC = lib.getExe runtime.gc;
        SLOW_RM_GC = lib.getExe slowRmGc;
        RACING_GC = lib.getExe racingGc;
        MOUNT_OPTIONS_GC = lib.getExe mountOptionsGc;
        WRONG_OWNER_GC = lib.getExe wrongOwnerGc;
        LAUNCHER = lib.getExe fixtureLauncher;
      }
      ''
        bash ${../fixtures/runtime/project-cache-gc.sh}
        bash ${../fixtures/runtime/project-cache-gc-cargo.sh}
        touch $out
      '';

  agent-skill-read-gate =
    pkgs.runCommandLocal "check-agent-skill-read-gate"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.nodejs
          pkgs.jq
        ];
        GATE = lib.getExe runtime.gate;
        CUSTOM_SKILL_ROOT_GATE = lib.getExe customSkillRootRuntime.gate;
        CODEBASE_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.codebase-design;
        UI_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.ui-design;
        DOMAIN_MODELING_SOURCE = hostConfig.dotfiles.agents.shared.skills.domain-modeling;
        COVERAGE_CHECKER = "${pluginSources.architecture-standard}/skills/standard-conformance/scripts/check-coverage.mjs";
      }
      ''
        bash ${../fixtures/runtime/verify.sh} --skills-only
        touch $out
      '';

  agent-omp-verification-gate-hook =
    pkgs.runCommandLocal "check-agent-omp-verification-gate-hook"
      {
        nativeBuildInputs = [ pkgs.bun ];
        GATE_HOOK = hookUsingGate (lib.getExe runtime.gate);
        HANGING_GATE_HOOK = hookUsingGate hangingGate;
      }
      ''
        export HOME=$PWD/home
        mkdir -p "$HOME"
        cp ${../fixtures/runtime/verification-gate.test.ts} verification-gate.test.ts
        bun test ./verification-gate.test.ts
        touch $out
      '';

  agent-verification-cache =
    assert lib.count (package: package == runtime.verify) hostConfig.environment.systemPackages == 1;
    assert lib.count (package: package == runtime.gate) hostConfig.environment.systemPackages == 1;
    pkgs.runCommandLocal "check-agent-verification-cache"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.git
          pkgs.gnused
          pkgs.jq
          pkgs.nodejs
        ];
        VERIFY = lib.getExe runtime.verify;
        GATE = lib.getExe runtime.gate;
        CUSTOM_SKILL_ROOT_GATE = lib.getExe customSkillRootRuntime.gate;
        CODEBASE_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.codebase-design;
        UI_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.ui-design;
        DOMAIN_MODELING_SOURCE = hostConfig.dotfiles.agents.shared.skills.domain-modeling;
        COVERAGE_CHECKER = "${pluginSources.architecture-standard}/skills/standard-conformance/scripts/check-coverage.mjs";
      }
      ''
        bash ${../fixtures/runtime/verify.sh}
        touch $out
      '';
}
