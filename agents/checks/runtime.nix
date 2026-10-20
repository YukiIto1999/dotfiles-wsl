{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        hostOptions,
        mkProbeSystem,
        normalMachineModule,
        ...
      }:
      let
        agentConfig = hostConfig.dotfiles.agents;
        inherit (agentConfig) clients;
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        verificationEntry = hostConfig.dotfiles.toolchain.verification.entry;
        executionPolicy = hostConfig.dotfiles.toolchain.execution.policy;
        supervise = hostConfig.dotfiles.platform.supervise.package;
        runtimeArgs = {
          inherit
            lib
            pkgs
            verificationEntry
            executionPolicy
            supervise
            ;
        };
        runtime = import ../package.nix (runtimeArgs // { runtimeContract = runtimePackageContract; });
        stallingCommand =
          name:
          pkgs.writeShellScriptBin name ''
            control=''${DOTFILES_AGENT_TEST_STALL-}
            utility= when= pattern=
            if [[ -n $control && -f $control ]]; then
              read -r utility when pattern < "$control"
            fi
            target=''${!#}
            stall() {
              if [[ $utility == ${name} && $when == "$1" && $target == $pattern ]]; then
                printf '%s %s %s\n' "$utility" "$when" "$target" >> "$control.ready"
                while [[ ! -e $control.release ]]; do
                  ${pkgs.coreutils}/bin/sleep 0.05
                done
              fi
            }
            stall before
            ${pkgs.coreutils}/bin/${name} "$@"
            status=$?
            stall after
            exit "$status"
          '';
        stallingShims = pkgs.symlinkJoin {
          name = "dotfiles-agent-stalling-shims";
          paths = map stallingCommand [
            "mv"
            "rm"
          ];
        };
        stallingVerify = runtime.mkVerify { commandShims = stallingShims; };
        # 入口解決の超過だけを再現するため宣言の読取まで遅らせる実装は不可
        slowResolutionEntry = pkgs.writeShellApplication {
          name = "slow-resolution-verification-entry";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            case " $* " in
            *" --budget "*|*" --snapshot "*) ;;
            *) sleep 3 ;;
            esac
            exec ${lib.getExe verificationEntry} "$@"
          '';
        };
        slowResolutionRuntime = import ../package.nix (
          runtimeArgs
          // {
            verificationEntry = slowResolutionEntry;
            runtimeContract = runtimePackageContract;
          }
        );
        customSkillRootRuntime = import ../package.nix (
          runtimeArgs
          // {
            runtimeContract = runtimePackageContract // {
              skillRoots = [ ".local/share/fixture adapter/procedures" ];
            };
          }
        );
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
        # 同じ実装へ sandbox の代替 command だけを渡し、launcher と wrapper が実際の経路で動く。
        fixtureRuntime = import ../package.nix (
          runtimeArgs
          // {
            runtimeContract = runtimePackageContract;
            systemdRunCommand = fakeSystemdRun;
            systemctlCommand = fakeSystemctl;
            nixStoreCommand = fakeNixStore;
          }
        );
        fixtureLauncher = fixtureRuntime.launcher;
        stallingLauncher = fixtureRuntime.mkLauncher { commandShims = stallingShims; };
        # nix-store --realise --add-root LINK --indirect は LINK を object への symlink にする。保護の失敗と、
        # root を取った後に profile が動く更新は環境変数で選ぶ。
        fakeNixStore = pkgs.writeShellScript "fake-nix-store" ''
          [ -z "''${NIX_STORE_LOG-}" ] || printf '%s\n' "$*" >> "$NIX_STORE_LOG"
          link= object=
          while [ "$#" -gt 0 ]; do
            case $1 in
              --realise | --indirect) shift ;;
              --add-root)
                link=$2
                shift 2
                ;;
              --option) shift 3 ;;
              *)
                object=$1
                shift
                ;;
            esac
          done
          if [ -n "''${FAKE_NIX_STORE_FAIL-}" ] && [[ $object == *"$FAKE_NIX_STORE_FAIL" ]]; then
            echo "error: path '$object' is not valid" >&2
            exit 1
          fi
          [ -e "$object" ] || {
            echo "error: path '$object' is not valid" >&2
            exit 1
          }
          ${pkgs.coreutils}/bin/ln -s "$object" "$link"
          if [ -n "''${FAKE_PROFILE_SWITCH-}" ] && [[ $object == *"$FAKE_PROFILE_SWITCH_OBJECT" ]]; then
            ${pkgs.coreutils}/bin/ln -sfn "$FAKE_PROFILE_SWITCH_TO" "$FAKE_PROFILE_SWITCH"
          fi
        '';
        # scope の cgroup に残った process を kill する要求。効果は環境変数で選ぶ。
        fakeSystemctl = pkgs.writeShellScript "fake-systemctl" ''
          [ -z "''${SYSTEMCTL_LOG-}" ] || printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
          if [ "''${FAKE_SYSTEMCTL_EFFECTIVE-}" = 1 ]; then
            uid=$(${pkgs.coreutils}/bin/id -u)
            : > "$DOTFILES_AGENT_CGROUP_ROOT/user.slice/user-$uid.slice/user@$uid.service/agents.slice/''${!#}/cgroup.procs"
          fi
        '';
        fakeAgent = pkgs.writeShellScript "fake-agent" (
          builtins.readFile ../fixtures/runtime/fake-agent.sh
        );
        fakeAgentNext = pkgs.writeShellScript "fake-agent-next" (
          builtins.readFile ../fixtures/runtime/fake-agent.sh + "\n# next generation\n"
        );
        dependencyA = pkgs.coreutils;
        dependencyB = lib.getBin pkgs.jq;
        fixtureWrapper = fixtureRuntime.mkWrapper {
          client = "fixture-client";
          binary = "fixture-agent";
          targetExecutable = "${fakeAgent}";
          executionDependencies = [
            dependencyA
            dependencyB
          ];
        };
        # 実行依存の再計算や手書きの一覧は配備と検査がずれるため不可
        moduleSessionWrapper = fixtureRuntime.mkWrapper {
          client = "omp";
          binary = clients.omp.binary;
          targetExecutable = "${fakeAgent}";
          executionDependencies = agentConfig.clientExecutionDependencies.omp;
        };
        # 手書きの参照一覧は実際の closure とずれるため不可
        moduleSessionWrapperClosure = pkgs.closureInfo { rootPaths = [ moduleSessionWrapper ]; };
        wrapperRejected =
          arguments:
          !(builtins.tryEval (builtins.deepSeq (runtime.mkWrapper arguments).drvPath true)).success;
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
        fixtureGitShim = runtime.mkGitShim { gitCommand = fakeGit; };
        racingGitShim = runtime.mkGitShim { gitCommand = racingGit; };
        deployedGateHook = "${homeConfig.home.file.".omp/agent/hooks/pre".source}/verification-gate.ts";
        hookUsingGate =
          gate:
          pkgs.runCommandLocal "omp-verification-gate-hook.ts" { } ''
            substitute ${deployedGateHook} $out \
              --replace-fail ${lib.getExe runtime.gate} ${gate}
          '';
        hangingGate = pkgs.writeShellScript "hanging-gate" ''
          ${pkgs.coreutils}/bin/sleep 300 &
          printf '%s\n' "$!" > descendant.pid
          wait
        '';
        recordingGate = pkgs.writeShellScript "next-generation-gate" ''
          printf '%s\n' "$*" >> "$HOME/next-generation-gate.calls"
          ${pkgs.coreutils}/bin/cat > /dev/null
        '';

        observationTimeoutSeconds = 10;
        homeDir = hostConfig.dotfiles.workstation.homeDir;
        runtimeContractSupport = import ./support/runtime-contract.nix { inherit homeDir; };
        inherit (runtimeContractSupport) expectedAgentRuntime runtimePackageContract;
        selectAgentObservations = lib.filterAttrs (name: _: lib.hasPrefix "agents/" name);
        agentObservations = selectAgentObservations hostConfig.dotfiles.health.observations;
        commonAgentObservation = checkId: resourceKey: failureMessage: {
          inherit checkId resourceKey failureMessage;
          timeoutSeconds = observationTimeoutSeconds;
        };
        expectedClientObservation =
          name: client:
          commonAgentObservation "agent/${name}" null
            "${client.binary} is unavailable or its version command failed"
          // {
            kind = "command-version";
            path = agentConfig.clientExecutables.${name};
            expectedSource = agentConfig.clientExecutables.${name};
            inherit (client) versionArgs;
          };
        timerObservation = name: {
          kind = "systemd-timer";
          manager = "system";
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
              # 供給 profile の実体は /nix/store/<32 文字の hash>-<package>-<version> にある
              executableRoots = map (package: "/nix/store/????????????????????????????????-${package}-*") [
                "claude-code"
                "codex"
                "omp"
                "opencode"
              ];
              slice = "agents.slice";
            };
        }
        // lib.mapAttrs' (
          name: client: lib.nameValuePair "agents/client/${name}" (expectedClientObservation name client)
        ) clients;
        userTimerObservation = name: timerObservation name // { manager = "user"; };
        # agents root の keyspace は runtime contract、作業日誌、記憶の収穫の timer で閉じる。どれでもない key は stale として落とす
        expectedJournalObservations = lib.optionalAttrs agentConfig.journal.enable {
          "agents/maintenance/journal" = userTimerObservation "dotfiles-agent-journal";
        };
        expectedHarvestObservations =
          lib.optionalAttrs
            (
              agentConfig.memoryHarvest.enable
              && builtins.elem "project-memory" hostConfig.dotfiles.capabilities.resolved
            )
            {
              "agents/maintenance/memory-harvest" = userTimerObservation "dotfiles-agent-memory-harvest";
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
          import ../package.nix (
            runtimeArgs
            // {
              runtimeContract = runtimePackageContract // {
                cache = runtimePackageContract.cache // cacheMutation;
              };
            }
          );
        highBytesMutationRuntime = runtimeWithCacheMutation { highBytes = 1; };
        lowBytesMutationRuntime = runtimeWithCacheMutation { lowBytes = 1; };
        inactiveDaysMutationRuntime = runtimeWithCacheMutation { inactiveDays = 1; };
        runtimeWithContractUpdate =
          update:
          import ../package.nix (runtimeArgs // { runtimeContract = runtimePackageContract // update; });
        relativeCacheRootMutationRuntime = runtimeWithContractUpdate {
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
          (mkProbeSystem [
            normalMachineModule
            {
              systemd.services.dotfiles-agent-autoupdate.description = lib.mkForce "description mutation";
              systemd.services.dotfiles-agent-project-cache-gc.description = lib.mkForce "description mutation";
            }
          ]).config;
      in
      {
        agent-runtime-contract =
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
          pkgs.runCommandLocal "check-agent-runtime-contract" { } "touch $out";

        agent-runtime-behavior =
          pkgs.runCommandLocal "check-agent-runtime-behavior"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.diffutils
                pkgs.gawk
                pkgs.git
                pkgs.gnused
                pkgs.jq
                pkgs.util-linux
              ];
              LAUNCHER = lib.getExe fixtureLauncher;
              STALLING_LAUNCHER = lib.getExe stallingLauncher;
              SUPERVISE = lib.getExe supervise;
              CAPPED_SLICES = lib.concatStringsSep " " cappedUserSlices;
              AGENT_SHIM_DIR = runtime.gitShim;
              GIT_SHIM_DIR = fixtureGitShim;
              RACING_GIT_SHIM_DIR = racingGitShim;
              FAKE_AGENT = "${fakeAgent}";
              FAKE_AGENT_NEXT = "${fakeAgentNext}";
              DEPENDENCY_A = "${dependencyA}";
              DEPENDENCY_B = "${dependencyB}";
            }
            ''
              bash ${../fixtures/runtime/launcher.sh}
              bash ${../fixtures/runtime/git-shim.sh}
              touch $out
            '';

        agent-runtime-protect =
          pkgs.runCommandLocal "check-agent-runtime-protect"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
              ];
              PROTECT = lib.getExe fixtureRuntime.protect;
              DEPENDENCY_A = "${dependencyA}";
              DEPENDENCY_B = "${dependencyB}";
              FAKE_AGENT = "${fakeAgent}";
            }
            ''
              bash ${../fixtures/runtime/protect.sh}
              touch $out
            '';

        # wrapper が実行依存の一覧を受け取り、共通の方針、lifecycle、保護の順に一度ずつ通すことを実際に起動して読む。
        agent-runtime-wrapper =
          assert lib.assertMsg (
            !wrapperRejected {
              client = "fixture-client";
              binary = "fixture-agent";
              targetExecutable = "${fakeAgent}";
              executionDependencies = [ dependencyA ];
            }
          ) "a valid wrapper was rejected";
          assert lib.assertMsg (wrapperRejected {
            client = "fixture-client";
            binary = "fixture-agent";
            targetExecutable = "${fakeAgent}";
            executionDependencies = [ "/home/outside/store" ];
          }) "a wrapper accepted an execution dependency outside the store";
          assert lib.assertMsg (wrapperRejected {
            client = "-fixture";
            binary = "fixture-agent";
            targetExecutable = "${fakeAgent}";
            executionDependencies = [ ];
          }) "a wrapper accepted a client id that is not a plain identifier";
          assert lib.assertMsg (wrapperRejected {
            client = "fixture-client";
            binary = "fixture-agent";
            targetExecutable = "relative/agent";
            executionDependencies = [ ];
          }) "a wrapper accepted a relative target executable";
          pkgs.runCommandLocal "check-agent-runtime-wrapper"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.diffutils
                pkgs.gawk
                pkgs.git
                pkgs.jq
                pkgs.util-linux
              ];
              WRAPPER = lib.getExe fixtureWrapper;
              LAUNCHER = lib.getExe fixtureLauncher;
              FAKE_AGENT = "${fakeAgent}";
              DEPENDENCY_A = "${dependencyA}";
              DEPENDENCY_B = "${dependencyB}";
              MODULE_WRAPPER = lib.getExe moduleSessionWrapper;
              GATE = lib.getExe runtime.gate;
              WRAPPER_CLOSURE = "${moduleSessionWrapperClosure}";
              SKILL_ROOT = clients.omp.skillsDestination;
              SKILL_SOURCE =
                toString
                  homeConfig.home.file."${clients.omp.skillsDestination}/codebase-design".source;
            }
            ''
              bash ${../fixtures/runtime/wrapper.sh}
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
                pkgs.jq
              ];
              GATE = lib.getExe runtime.gate;
              CUSTOM_SKILL_ROOT_GATE = lib.getExe customSkillRootRuntime.gate;
              CODEBASE_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.codebase-design;
              UI_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.ui-design;
              DOMAIN_MODELING_SOURCE = hostConfig.dotfiles.agents.shared.skills.domain-modeling;
            }
            ''
              bash ${../fixtures/runtime/verify.sh} --skills-only
              touch $out
            '';

        agent-omp-verification-gate-hook =
          pkgs.runCommandLocal "check-agent-omp-verification-gate-hook"
            {
              nativeBuildInputs = [
                pkgs.bun
                pkgs.git
              ];
              GATE_HOOK = hookUsingGate (lib.getExe runtime.gate);
              HANGING_GATE_HOOK = hookUsingGate hangingGate;
              NEXT_GENERATION_GATE_HOOK = hookUsingGate recordingGate;
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
                pkgs.gnumake
                pkgs.gnused
                pkgs.jq
                pkgs.nix
                pkgs.nodejs
                pkgs.strace
                pkgs.util-linux
              ];
              VERIFY = lib.getExe runtime.verify;
              STALLING_VERIFY = lib.getExe stallingVerify;
              SLOW_RESOLUTION_VERIFY = lib.getExe slowResolutionRuntime.verify;
              GATE = lib.getExe runtime.gate;
              CUSTOM_SKILL_ROOT_GATE = lib.getExe customSkillRootRuntime.gate;
              CODEBASE_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.codebase-design;
              UI_DESIGN_SOURCE = hostConfig.dotfiles.agents.shared.skills.ui-design;
              DOMAIN_MODELING_SOURCE = hostConfig.dotfiles.agents.shared.skills.domain-modeling;
            }
            ''
              bash ${../fixtures/runtime/verify.sh}
              touch $out
            '';
      }
    )
  ];
}
