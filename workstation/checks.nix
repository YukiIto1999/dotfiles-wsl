{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        hostOptions,
        hostNames,
        machineConfigs,
        mkProbeSystem,
        normalMachineModule,
        ...
      }:
      let
        workstation = hostConfig.dotfiles.workstation;
        zram = hostConfig.zramSwap;
        zramGenerator = hostConfig.services.zram-generator;
        zramService = hostConfig.systemd.services.dotfiles-zram-swap or { };
        journald = hostConfig.services.journald;
        systemUnits = hostConfig.environment.etc."systemd/system".source;
        journaldConfig = hostConfig.environment.etc."systemd/journald.conf".source;
        zramConfig = hostConfig.environment.etc."systemd/zram-generator.conf".source;
        expectedNixStorageReserve = {
          "min-free" = workstation.nix.minimumFreeGiB * 1073741824;
          "max-free" = workstation.nix.targetFreeGiB * 1073741824;
        };
        wslMemoryOutcomeIds = [
          "resource/wsl-memory/high-order-pages"
          "resource/wsl-memory/io-pressure"
          "resource/wsl-memory/memory-pressure"
          "resource/wsl-memory/stuck-relays"
          "resource/wsl-memory/vmbus-ring-failures"
        ];
        hostObservationKeys = [
          "host/home-manager"
          "host/home-manager-restart"
          "host/journald"
          "host/nix-daemon"
          "host/nix-daemon-service"
          "host/nix-gc"
          "host/root-filesystem"
          "host/swap"
          "host/system-generation"
          "host/windows-drives"
          "host/windows-memory-commit"
          "host/wsl-memory"
          "host/wsl-vhd"
        ];
        hostObservations = lib.filterAttrs (
          name: _: lib.hasPrefix "host/" name
        ) hostConfig.dotfiles.health.observations;
        selectStabilityObservations =
          observations: builtins.intersectAttrs (lib.genAttrs hostObservationKeys (_: null)) observations;
        stabilityObservations = selectStabilityObservations hostObservations;
        observationProjection = lib.mapAttrs (
          _: observation: builtins.removeAttrs observation [ "command" ]
        ) stabilityObservations;
        expectedObservationProjection = {
          "host/home-manager" = {
            activeStates = [ "active" ];
            checkId = "home-manager";
            failureMessage = "home-manager-${hostConfig.dotfiles.workstation.username}.service is not operational";
            kind = "systemd-service";
            manager = "system";
            loadStates = [ "loaded" ];
            resourceKey = null;
            results = [ "success" ];
            slice = null;
            timeoutSeconds = 10;
            unit = "home-manager-${hostConfig.dotfiles.workstation.username}.service";
          };
          "host/home-manager-restart" = {
            checkId = "restart/service/home-manager-${hostConfig.dotfiles.workstation.username}.service";
            failureAt = 20;
            failureMessage = "could not observe restart count for home-manager-${hostConfig.dotfiles.workstation.username}.service";
            kind = "restart-counter";
            manager = "system";
            resourceKey = null;
            sourceKind = "systemd-service";
            target = "home-manager-${hostConfig.dotfiles.workstation.username}.service";
            timeoutSeconds = 10;
            warningAt = 5;
          };
          "host/journald" = {
            checkId = "resource/journald";
            failureMessage = "could not observe journald disk usage";
            kind = "journal-size";
            maximumBytes = workstation.storage.journal.maximumGiB * 1073741824;
            resourceKey = "journald";
            timeoutSeconds = 10;
          };
          "host/nix-daemon" = {
            activeStates = [ "active" ];
            checkId = "nix-daemon";
            failureMessage = "nix-daemon.socket is not operational";
            kind = "systemd-socket";
            manager = "system";
            loadStates = [ "loaded" ];
            resourceKey = null;
            results = [ "success" ];
            timeoutSeconds = 10;
            unit = "nix-daemon.socket";
          };
          "host/nix-daemon-service" = {
            activeStates = [
              "active"
              "inactive"
            ];
            checkId = "service/nix-daemon";
            failureMessage = "nix-daemon.service is not operational or is outside ${workstation.workload.slices.support}";
            kind = "systemd-service";
            manager = "system";
            loadStates = [ "loaded" ];
            resourceKey = null;
            results = [ "success" ];
            slice = workstation.workload.slices.support;
            timeoutSeconds = 10;
            unit = "nix-daemon.service";
          };
          "host/nix-gc" = {
            activeStates = [ "active" ];
            checkId = "maintenance/nix-gc.timer";
            failureMessage = "nix-gc.timer or its service is not operational";
            kind = "systemd-timer";
            manager = "system";
            resourceKey = null;
            service = "nix-gc.service";
            serviceResults = [ "success" ];
            timeoutSeconds = 10;
            timer = "nix-gc.timer";
            unitFileStates = [
              "enabled"
              "enabled-runtime"
            ];
          };
          "host/root-filesystem" = {
            checkId = "resource/root-filesystem";
            failure = 95;
            failureMessage = "could not observe root filesystem utilization";
            kind = "filesystem-threshold";
            metric = "used-percent";
            path = "/";
            resourceKey = "rootFilesystem";
            timeoutSeconds = 10;
            warning = 85;
          };
          "host/swap" = {
            checkId = "resource/swap";
            failureMessage = "swap must include lzo-rle zram above any disk swap with at least ${toString workstation.swap.minimumTotalGiB} GiB total";
            kind = "swap-policy";
            minimumTotalBytes = workstation.swap.minimumTotalGiB * 1073741824;
            requiredZramAlgorithm = "lzo-rle";
            requireZram = true;
            resourceKey = "swap";
            timeoutSeconds = 10;
            zramAboveDisk = true;
          };
          "host/system-generation" = {
            checkId = "system-generation";
            currentPath = "/run/current-system";
            failureMessage = "could not resolve the current system generation";
            kind = "path-match";
            requiredPath = "/nix/var/nix/profiles/system";
            resolution = "canonical";
            resourceKey = null;
            timeoutSeconds = 10;
          };
          "host/windows-drives" = {
            checkId = "resource/windows-drives";
            failure = 10;
            failureMessage = "could not observe Windows drive free space";
            kind = "numeric-command-threshold-set";
            metric = "free-percent";
            resourceKey = "windowsDrives";
            timeoutSeconds = 10;
            warning = 15;
          };
          "host/windows-memory-commit" = {
            checkId = "resource/windows-memory-commit";
            failure = workstation.windowsMemoryCommit.failure;
            failureMessage = "could not observe Windows committed memory";
            kind = "numeric-command-threshold";
            metric = "used-percent";
            resourceKey = "windowsMemoryCommit";
            timeoutSeconds = 10;
            warning = workstation.windowsMemoryCommit.warning;
          };
          "host/wsl-memory" = {
            allowedOutcomeIds = wslMemoryOutcomeIds;
            checkId = "resource/wsl-memory";
            envelopeVersion = 1;
            failureMessage = "could not observe WSL memory health";
            kind = "normalized-protocol";
            requiredOutcomeIds = wslMemoryOutcomeIds;
            requiredResourceKeys = [ "wslMemory" ];
            resourceKey = null;
            timeoutSeconds = 30;
          };
          "host/wsl-vhd" = {
            allowedOutcomeIds = [
              "resource/wsl-vhd/capacity"
              "resource/wsl-vhd/root-discard"
              "resource/wsl-vhd/wslconfig"
            ];
            checkId = "resource/wsl-vhd";
            envelopeVersion = 1;
            failureMessage = "could not observe the WSL root VHD";
            kind = "normalized-protocol";
            requiredOutcomeIds = [
              "resource/wsl-vhd/capacity"
              "resource/wsl-vhd/root-discard"
              "resource/wsl-vhd/wslconfig"
            ];
            requiredResourceKeys = [ ];
            resourceKey = null;
            timeoutSeconds = 20;
          };
        };
        hostObservationModuleSuffixes = [
          "/workstation/module.nix"
          "/workstation/activation/module.nix"
          "/workstation/home/module.nix"
          "/workstation/nix/module.nix"
          "/workstation/stability/module.nix"
          "/workstation/storage/module.nix"
        ];
        hostObservationDefinitions = builtins.filter (
          definition:
          lib.any (suffix: lib.hasSuffix suffix (toString definition.file)) hostObservationModuleSuffixes
        ) hostOptions.dotfiles.health.observations.definitionsWithLocations;
        hostDefinitionKeys = lib.sort builtins.lessThan (
          lib.unique (
            lib.concatMap (definition: builtins.attrNames definition.value) hostObservationDefinitions
          )
        );
        stabilityConfiguration = {
          inherit journald;
          homeManagerUnit = "home-manager-${hostConfig.dotfiles.workstation.username}.service";
          nixGc = hostConfig.nix.gc;
          nixOptimiseAutomatic = hostConfig.nix.optimise.automatic;
          nixStorageReserve = builtins.intersectAttrs expectedNixStorageReserve hostConfig.nix.settings;
          timers = hostConfig.systemd.timers;
          zram = zramGenerator.settings.zram0;
        };
        stabilityContractMatches =
          candidateConfiguration: candidateObservations:
          let
            candidateStabilityObservations = selectStabilityObservations candidateObservations;
            candidateProjection = lib.mapAttrs (
              _: observation: builtins.removeAttrs observation [ "command" ]
            ) candidateStabilityObservations;
            swapObservation = candidateStabilityObservations."host/swap" or { };
            journalObservation = candidateStabilityObservations."host/journald" or { };
            homeManagerObservation = candidateStabilityObservations."host/home-manager" or { };
            homeManagerRestartObservation = candidateStabilityObservations."host/home-manager-restart" or { };
            nixGcObservation = candidateStabilityObservations."host/nix-gc" or { };
          in
          builtins.attrNames candidateStabilityObservations == hostObservationKeys
          && candidateProjection == expectedObservationProjection
          &&
            (candidateConfiguration.zram.compression-algorithm or null)
            == (swapObservation.requiredZramAlgorithm or null)
          && lib.hasInfix "SystemMaxUse=${toString (builtins.div (journalObservation.maximumBytes or 0) 1073741824)}G" candidateConfiguration.journald.extraConfig
          && candidateConfiguration.nixGc.automatic
          && candidateConfiguration.nixGc.persistent
          && !candidateConfiguration.nixOptimiseAutomatic
          && candidateConfiguration.nixStorageReserve == expectedNixStorageReserve
          && (nixGcObservation.timer or null) == "nix-gc.timer"
          && builtins.hasAttr "nix-gc" candidateConfiguration.timers
          && (homeManagerObservation.unit or null) == candidateConfiguration.homeManagerUnit
          && (homeManagerRestartObservation.target or null) == candidateConfiguration.homeManagerUnit
          && (homeManagerRestartObservation.warningAt or null) == 5
          && (homeManagerRestartObservation.failureAt or null) == 20;
        thresholdMutation = hostObservations // {
          "host/root-filesystem" = hostObservations."host/root-filesystem" or { } // {
            warning = 86;
          };
        };
        nixStorageReserveMutation = stabilityConfiguration // {
          nixStorageReserve = expectedNixStorageReserve // {
            "min-free" = 0;
          };
        };
        failureMessageMutation = hostObservations // {
          "host/root-filesystem" = hostObservations."host/root-filesystem" or { } // {
            failureMessage = "wrong but non-empty failure message";
          };
        };
        timerRemovalMutation = builtins.removeAttrs hostObservations [ "host/nix-gc" ];
        homeManagerRestartRemovalMutation = builtins.removeAttrs hostObservations [
          "host/home-manager-restart"
        ];
        homeManagerRestartThresholdMutation = hostObservations // {
          "host/home-manager-restart" = hostObservations."host/home-manager-restart" or { } // {
            warningAt = 6;
          };
        };
        independentObservationDescriptionVariantConfig =
          (mkProbeSystem [
            normalMachineModule
            (
              { config, lib, ... }:
              {
                dotfiles.health.observations."host/independent-observation" = {
                  kind = "roster";
                  members = [ "fixture" ];
                  minimumCount = 1;
                  failureOnly = false;
                  checkId = null;
                  resourceKey = null;
                  timeoutSeconds = 10;
                  failureMessage = "independent host observation failed";
                };
                systemd.services."home-manager-${config.dotfiles.workstation.username}".description =
                  lib.mkForce "A description must not select the Home Manager observation";
              }
            )
          ]).config;
        independentObservationDescriptionVariant = lib.filterAttrs (
          name: _: lib.hasPrefix "host/" name
        ) independentObservationDescriptionVariantConfig.dotfiles.health.observations;
        zramAlgorithmMutation = stabilityConfiguration // {
          zram = stabilityConfiguration.zram // {
            compression-algorithm = "zstd";
          };
        };
        # drive は実行時に mount から見つける。host profile は drive を知らず、全 host が同じ観測を持つ
        windowsDrivesObservationFor =
          candidate:
          let
            observation = candidate.dotfiles.health.observations."host/windows-drives";
          in
          observation // { command = lib.getExe observation.command; };
        machineProfileContractMatches =
          name:
          let
            candidate = machineConfigs.${name};
            candidateWorkstation = candidate.dotfiles.workstation;
            candidateSwap = candidate.dotfiles.health.observations."host/swap";
            candidateWindowsMemory = candidate.dotfiles.health.observations."host/windows-memory-commit";
          in
          candidate.networking.hostName == name
          && windowsDrivesObservationFor candidate == windowsDrivesObservationFor hostConfig
          &&
            candidate.services.zram-generator.settings.zram0.zram-size
            == "${toString candidateWorkstation.swap.zramMemoryPercent} / 100 * ram"
          && candidateSwap.minimumTotalBytes == candidateWorkstation.swap.minimumTotalGiB * 1073741824
          && candidateWindowsMemory.warning == candidateWorkstation.windowsMemoryCommit.warning
          && candidateWindowsMemory.failure == candidateWorkstation.windowsMemoryCommit.failure
          && candidate.nix.settings.max-jobs == candidateWorkstation.nix.maxJobs
          && candidate.nix.settings.cores == candidateWorkstation.nix.cores
          && candidate.nix.settings.min-free == candidateWorkstation.nix.minimumFreeGiB * 1073741824
          && candidate.nix.settings.max-free == candidateWorkstation.nix.targetFreeGiB * 1073741824
          &&
            candidate.dotfiles.health.observations."host/journald".maximumBytes
            == candidateWorkstation.storage.journal.maximumGiB * 1073741824
          && lib.hasInfix "defaultVhdSize=${toString candidateWorkstation.storage.vhd.sizeGiB}GB" candidateWorkstation.wsl.windowsConfigTemplate;
        memoryVariantConfig =
          (mkProbeSystem [
            normalMachineModule
            ({ lib, ... }: {
              dotfiles.workstation.swap = {
                zramMemoryPercent = 40;
                minimumTotalGiB = lib.mkForce 6;
              };
              dotfiles.workstation.windowsMemoryCommit = {
                warning = 80;
                failure = 90;
              };
            })
          ]).config;
        # user.slice は logind の user-<UID>.slice の祖先で、名前の dash が親を表すため user-workload.slice も同じ祖先に入る。
        # init.scope と system.slice の基盤は祖先の外に残る
        sliceStem = slice: lib.removeSuffix ".slice" slice;
        sliceWithin = parent: slice: lib.hasPrefix "${sliceStem parent}-" slice;
        slicePercent = value: lib.toInt (lib.removeSuffix "%" value);
        workloadVariantConfig =
          (mkProbeSystem [
            normalMachineModule
            (
              { lib, ... }:
              {
                dotfiles.workstation.workload = {
                  hostReservePercent = lib.mkForce 20;
                  reclaimMarginPercent = 8;
                  memorySwapMaxPercent = lib.mkForce 65;
                };
              }
            )
          ]).config;
        workloadConfigs = machineConfigs // {
          workload-variant = workloadVariantConfig;
        };
        # 上限の外に残す基盤。docker は container の scope を作る daemon であり、container そのものではない
        workloadEssentialServices = [
          "docker"
          "docker-build-artifact-gc"
          "dotfiles-agent-reserve-swap"
          "dotfiles-zram-swap"
          "nix-gc"
          "otel-collector"
        ];
        workloadViolations =
          configuration:
          let
            options = configuration.dotfiles.workstation.workload;
            inherit (options) slices;
            services = configuration.systemd.services;
            serviceSlice = name: services.${name}.serviceConfig.Slice or null;
            insideAggregate =
              slice: slice != null && (slice == slices.aggregate || sliceWithin slices.aggregate slice);
            placed = lib.sort builtins.lessThan (
              builtins.attrNames (
                lib.filterAttrs (_: service: (service.serviceConfig.Slice or null) == slices.support) services
              )
            );
            expectedPlaced = lib.sort builtins.lessThan (
              [
                "nix-daemon"
                configuration.dotfiles.platform.mcp.gateway.service
              ]
              ++ map (front: front.service) (builtins.attrValues configuration.dotfiles.platform.mcp.fronts)
            );
            expectedLimits = {
              MemoryHigh = "${toString options.memoryHighPercent}%";
              MemoryMax = "${toString options.memoryMaxPercent}%";
              MemorySwapMax = "${toString options.memorySwapMaxPercent}%";
            };
            agentSlice = configuration.dotfiles.agents.slice;
            containersSlice = configuration.systemd.slices.${sliceStem slices.containers} or null;
            declaredContainers = builtins.attrValues configuration.virtualisation.oci-containers.containers;
            undeclaredBounded =
              containersSlice != null
              && (configuration.virtualisation.docker.daemon.settings.cgroup-parent or null) == slices.containers
              && slicePercent containersSlice.sliceConfig.MemoryMax < options.memoryMaxPercent
              && slicePercent containersSlice.sliceConfig.MemorySwapMax <= options.memorySwapMaxPercent;
          in
          lib.optional (
            (configuration.systemd.slices.${sliceStem slices.aggregate}.sliceConfig or { }) != expectedLimits
          ) "aggregate slice limits do not follow the workload options"
          ++ lib.optional (
            !(builtins.hasAttr (sliceStem slices.support) configuration.systemd.slices)
          ) "the workload support slice is not declared"
          ++ lib.optional (
            !(sliceWithin slices.aggregate slices.support && sliceWithin slices.support slices.containers)
          ) "workload slices are not nested by name under user.slice"
          ++ lib.optional (
            !(
              options.memoryHighPercent < options.memoryMaxPercent
              && options.memoryMaxPercent + options.hostReservePercent == 100
            )
          ) "workload MemoryHigh and MemoryMax do not leave the declared host reserve"
          ++
            lib.optional (placed != expectedPlaced)
              "services placed in user-workload.slice differ from nix-daemon, the MCP fronts and the MCP gateway"
          ++ lib.optional (lib.any (
            name: insideAggregate (serviceSlice name)
          ) workloadEssentialServices) "an essential host service moved inside user.slice"
          ++ lib.optional (
            (services."user@".serviceConfig or { }) ? Slice
          ) "user@ was moved out of its canonical user-<UID>.slice"
          # launcher、GC、doctor は /user.slice/user-<UID>.slice/user@<UID>.service/agents.slice/ の実 path を読む
          ++ lib.optional (
            !(configuration.systemd.user.slices ? agents)
            || (configuration.systemd.user.slices.agents.sliceConfig ? Slice)
          ) "the agents slice must stay a user-manager slice below user@<UID>.service"
          ++ lib.optional (
            !(lib.all (
              container: lib.elem "--cgroup-parent=${slices.support}" container.extraOptions
            ) declaredContainers)
          ) "a declared container is outside user-workload.slice"
          ++ lib.optional (
            configuration.virtualisation.docker.enable && !undeclaredBounded
          ) "undeclared containers are not bounded inside the workload envelope"
          ++ lib.optional (
            !(
              agentSlice.userManager.memoryMaxPercent < options.memoryMaxPercent
              && agentSlice.userManager.memoryHighPercent < options.memoryHighPercent
              && agentSlice.memorySwapMaxPercent <= options.memorySwapMaxPercent
            )
          ) "agent user manager limits are not enclosed by the workload envelope";
        # 実測（2026-10-27、nixos host）。基盤は kernel、init.scope と Docker daemon の最大、otel-collector の最大と
        # journald などの概算。workload は同時に動いていた user.slice、nix-daemon、MCP front、宣言済みと宣言外の container の常駐量
        observedWorkloadResources = {
          physicalBytes = 42059022336;
          hostBytes = 1237168128 + 859488256 + 4369203200 + 384303104 + 134217728;
          workloadResidentBytes = 19298754560 + 1794834432 + 4541833216 + 4667039744 + 232697856;
          workloadSwapBytes = 546754560 + 32141312 + 2940928;
        };
        observedReserveHolds =
          configuration:
          let
            options = configuration.dotfiles.workstation.workload;
            physical = observedWorkloadResources.physicalBytes;
          in
          observedWorkloadResources.hostBytes <= builtins.div (physical * options.hostReservePercent) 100
          &&
            observedWorkloadResources.workloadResidentBytes
            <= builtins.div (physical * options.memoryHighPercent) 100
          &&
            observedWorkloadResources.workloadSwapBytes
            <= builtins.div (physical * options.memorySwapMaxPercent) 100;
        withWorkloadOptions =
          configuration: update:
          configuration
          // {
            dotfiles = configuration.dotfiles // {
              workstation = configuration.dotfiles.workstation // {
                workload = configuration.dotfiles.workstation.workload // update;
              };
            };
          };
        withServices =
          configuration: update:
          configuration
          // {
            systemd = configuration.systemd // {
              services = update configuration.systemd.services;
            };
          };
        withoutServiceSlice =
          name: services:
          services
          // {
            ${name} = services.${name} // {
              serviceConfig = builtins.removeAttrs services.${name}.serviceConfig [ "Slice" ];
            };
          };
        withServiceSlice =
          name: slice: services:
          services
          // {
            ${name} = services.${name} // {
              serviceConfig = services.${name}.serviceConfig // {
                Slice = slice;
              };
            };
          };
        withoutSlices =
          names: configuration:
          configuration
          // {
            systemd = configuration.systemd // {
              slices = builtins.removeAttrs configuration.systemd.slices names;
            };
          };
        referenceSlices = hostConfig.dotfiles.workstation.workload.slices;
        workloadMutations = {
          nix-daemon-outside = withServices hostConfig (withoutServiceSlice "nix-daemon");
          mcp-front-outside = withServices hostConfig (
            withoutServiceSlice (
              lib.head (map (front: front.service) (builtins.attrValues hostConfig.dotfiles.platform.mcp.fronts))
            )
          );
          mcp-gateway-outside = withServices hostConfig (
            withoutServiceSlice hostConfig.dotfiles.platform.mcp.gateway.service
          );
          docker-daemon-inside = withServices hostConfig (withServiceSlice "docker" referenceSlices.support);
          user-manager-relocated = withServices hostConfig (withServiceSlice "user@" referenceSlices.support);
          agents-slice-missing = hostConfig // {
            systemd = hostConfig.systemd // {
              user = hostConfig.systemd.user // {
                slices = builtins.removeAttrs hostConfig.systemd.user.slices [ "agents" ];
              };
            };
          };
          aggregate-unbounded = withoutSlices [ "user" ] hostConfig;
          undeclared-unbounded = withoutSlices [ (sliceStem referenceSlices.containers) ] hostConfig;
          declared-container-unplaced = hostConfig // {
            virtualisation = hostConfig.virtualisation // {
              oci-containers = hostConfig.virtualisation.oci-containers // {
                containers = lib.mapAttrs (
                  _: container:
                  container
                  // {
                    extraOptions = builtins.filter (
                      option: !(lib.hasPrefix "--cgroup-parent" option)
                    ) container.extraOptions;
                  }
                ) hostConfig.virtualisation.oci-containers.containers;
              };
            };
          };
          reserve-drift = withWorkloadOptions hostConfig { memoryMaxPercent = 95; };
        };
        powershellProbe = "[Console]::WriteLine(20)";
        mkWindowsPercentageObservation = import ./package.nix;
        mkFakePowerShell =
          expectedProbe: name: body:
          pkgs.writeShellScript name ''
            set -euo pipefail

            test "$#" -eq 5
            test "$1" = -NoLogo
            test "$2" = -NoProfile
            test "$3" = -NonInteractive
            test "$4" = -Command
            test "$5" = ${lib.escapeShellArg expectedProbe}
            ${body}
          '';
        successfulPowerShell =
          mkFakePowerShell powershellProbe "windows-percent-success"
            "printf '20\\r\\n'";
        noisyPowerShell = mkFakePowerShell powershellProbe "windows-percent-noisy" ''
          printf '20\r\nnoise\n'
          printf 'WINDOWS_PERCENT_NOISY_STDERR_POISON\n' >&2
        '';
        invalidPowerShell = mkFakePowerShell powershellProbe "windows-percent-invalid" "printf '101\\r\\n'";
        statusPowerShell =
          mkFakePowerShell powershellProbe "windows-percent-status"
            "printf '20\\r\\n'; exit 7";
        timeoutPowerShell =
          mkFakePowerShell powershellProbe "windows-percent-timeout"
            "sleep 3; printf '20\\r\\n'";
        mkProbe =
          powershellCommand:
          mkWindowsPercentageObservation {
            inherit
              pkgs
              lib
              powershellCommand
              powershellProbe
              ;
            commandName = "dotfiles-observe-windows-fixture";
            timeoutSeconds = 0.1;
          };
        successfulProbe = mkProbe successfulPowerShell;
        noisyProbe = mkProbe noisyPowerShell;
        invalidProbe = mkProbe invalidPowerShell;
        statusProbe = mkProbe statusPowerShell;
        timeoutProbe = mkProbe timeoutPowerShell;
        mkWindowsDrivesObservation = import ./storage/package.nix;
        mkDrivesProbe =
          name: mounts: body:
          mkWindowsDrivesObservation {
            inherit pkgs lib;
            mountsFile = pkgs.writeText "${name}-mounts" mounts;
            dfCommand = pkgs.writeShellScript name ''
              set -euo pipefail
              ${body}
            '';
          };
        driveMounts = ''
          drivers /drivers 9p ro 0 0
          D:\134 /mnt/d 9p rw 0 0
          C:\134Users /mnt/c-users 9p rw 0 0
          C:\134 /mnt/c\040disk 9p rw 0 0
          C:\134 /mnt/c-duplicate 9p rw 0 0
          G: /mnt/g 9p rw 0 0
        '';
        drivesProbe = mkDrivesProbe "df-drives" driveMounts ''
          case "''${!#}" in
            /mnt/d) printf '1K-blocks Avail\n2000 1000\n' ;;
            "/mnt/c disk") printf '1K-blocks Avail\n1000 99\n' ;;
            *) printf 'df: inaccessible unrelated mount\n' >&2; exit 1 ;;
          esac
        '';
        drivesFailedProbes = {
          df-status = mkDrivesProbe "df-status" driveMounts "printf '1K-blocks Avail\\n1000 99\\n'; exit 1";
          no-drive = mkDrivesProbe "df-no-drive" "drivers /drivers 9p ro 0 0\n" "exit 1";
          zero-size = mkDrivesProbe "df-zero-size" driveMounts "printf '1K-blocks Avail\\n0 0\\n'";
          non-numeric = mkDrivesProbe "df-non-numeric" driveMounts "printf '1K-blocks Avail\\n- -\\n'";
        };
        mkWslVhdObservation = import ./storage/impl/wsl-vhd-package.nix;
        # root の device 番号、sysfs の sector 数、PowerShell が返す .wslconfig を差し替える
        wslVhdStat = pkgs.writeShellScript "wsl-vhd-stat" ''
          set -euo pipefail

          test "$*" = '--format=%Hd:%Ld /'
          printf '8:48\n'
        '';
        mkWslVhdBlockDevices = device: sectors: pkgs.writeTextDir "${device}/size" "${toString sectors}\n";
        mkWslconfigPowerShell =
          name: body:
          pkgs.writeShellScript name ''
            set -euo pipefail

            test "$#" -eq 5
            test "$1" = -NoLogo
            test "$2" = -NoProfile
            test "$3" = -NonInteractive
            test "$4" = -Command
            ${body}
          '';
        printWslconfig =
          name: content: mkWslconfigPowerShell name "printf '%s' ${lib.escapeShellArg content}";
        # / に重なった最後の mount が見える root になり、discard は super block の option にだけ現れる
        mkMountinfo = name: lines: pkgs.writeText name (lib.concatStringsSep "\n" lines + "\n");
        mkRootMountinfo =
          superOptions: "23 1 8:48 / / rw,relatime shared:1 - ext4 /dev/sdd ${superOptions}";
        mkStoreMountinfo =
          superOptions:
          "24 23 8:48 /nix/store /nix/store ro,relatime shared:1 - ext4 /dev/sdd ${superOptions}";
        wslRootOptions = "rw,errors=remount-ro,data=ordered";
        wslRootDiscardOptions = "rw,discard,errors=remount-ro,data=ordered";
        mountinfoWithoutDiscard = mkMountinfo "mountinfo-nodiscard" [
          (mkRootMountinfo wslRootOptions)
          (mkStoreMountinfo wslRootDiscardOptions)
        ];
        mkWslVhdProbe =
          {
            blockDevices ? mkWslVhdBlockDevices "8:48" 1677721600,
            mountinfo ? mountinfoWithoutDiscard,
            powershellCommand ? printWslconfig "wslconfig-declared" (
              "[wsl2]\r\ndefaultVhdSize=800GB\r\nmemory=40GB\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n\r\n"
              + "[experimental]\r\nautoMemoryReclaim=gradual\r\nsparseVhd=false\r\n"
            ),
            sizeBytes ? 800 * 1073741824,
            sparse ? false,
          }:
          mkWslVhdObservation {
            inherit
              pkgs
              lib
              blockDevices
              mountinfo
              powershellCommand
              ;
            inherit sizeBytes sparse;
            statCommand = wslVhdStat;
            timeoutSeconds = 1;
          };
        # 容量と .wslconfig は独立に判定し、PowerShell が失敗しても容量の結果を返す
        wslVhdCases = {
          declared = {
            probe = mkWslVhdProbe { };
            capacity = "pass";
            wslconfig = "pass";
          };
          other-capacity = {
            probe = mkWslVhdProbe { blockDevices = mkWslVhdBlockDevices "8:48" 2147483648; };
            capacity = "fail";
            wslconfig = "pass";
          };
          unknown-device = {
            probe = mkWslVhdProbe { blockDevices = mkWslVhdBlockDevices "8:0" 1677721600; };
            capacity = "fail";
            wslconfig = "pass";
          };
          equivalent-notation = {
            probe = mkWslVhdProbe {
              powershellCommand = printWslconfig "wslconfig-equivalent" "  [WSL2]  # cap\n  DefaultVhdSize = \"819200MB\"  # 800 GiB\n[Experimental]\nSPARSEVHD=False\n";
            };
            capacity = "pass";
            wslconfig = "pass";
          };
          first-value-wins = {
            probe = mkWslVhdProbe {
              powershellCommand = printWslconfig "wslconfig-duplicate" "[wsl2]\ndefaultVhdSize=1TB\ndefaultVhdSize=800GB\n[experimental]\nsparseVhd=false\n";
            };
            capacity = "pass";
            wslconfig = "fail";
          };
          sparse-enabled = {
            probe = mkWslVhdProbe {
              powershellCommand = printWslconfig "wslconfig-sparse" "[wsl2]\ndefaultVhdSize=800GB\n[experimental]\nsparseVhd=true\n";
            };
            capacity = "pass";
            wslconfig = "fail";
          };
          sparse-outside-experimental = {
            probe = mkWslVhdProbe {
              powershellCommand = printWslconfig "wslconfig-wrong-section" "[wsl2]\ndefaultVhdSize=800GB\nsparseVhd=false\n";
            };
            capacity = "pass";
            wslconfig = "fail";
          };
          missing-file = {
            probe = mkWslVhdProbe { powershellCommand = mkWslconfigPowerShell "wslconfig-missing" ":"; };
            capacity = "pass";
            wslconfig = "fail";
          };
          powershell-status = {
            probe = mkWslVhdProbe {
              powershellCommand = mkWslconfigPowerShell "wslconfig-status" "printf '[wsl2]\\ndefaultVhdSize=800GB\\n[experimental]\\nsparseVhd=false\\n'; exit 1";
            };
            capacity = "pass";
            wslconfig = "fail";
          };
          powershell-timeout = {
            probe = mkWslVhdProbe { powershellCommand = mkWslconfigPowerShell "wslconfig-timeout" "sleep 30"; };
            capacity = "pass";
            wslconfig = "fail";
          };
        };
        # root の online discard は容量や .wslconfig と独立に判定し、/ の super block の option だけを見る
        wslRootDiscardCases = {
          root-discard = {
            mountinfo = mkMountinfo "mountinfo-discard" [ (mkRootMountinfo wslRootDiscardOptions) ];
            status = "fail";
          };
          explicit-nodiscard = {
            mountinfo = mkMountinfo "mountinfo-explicit-nodiscard" [
              (mkRootMountinfo "rw,nodiscard,errors=remount-ro,data=ordered")
            ];
            status = "pass";
          };
          discard-argument = {
            mountinfo = mkMountinfo "mountinfo-discard-argument" [
              (mkRootMountinfo "rw,discard=1,errors=remount-ro,data=ordered")
            ];
            status = "fail";
          };
          source-named-discard = {
            mountinfo = mkMountinfo "mountinfo-source-discard" [
              "23 1 8:48 / / rw,relatime shared:1 - ext4 /dev/discard0 ${wslRootOptions}"
            ];
            status = "pass";
          };
          store-discard-only = {
            mountinfo = mkMountinfo "mountinfo-store-discard" [
              (mkRootMountinfo wslRootOptions)
              (mkStoreMountinfo wslRootDiscardOptions)
            ];
            status = "pass";
          };
          overmounted-discard-hidden = {
            mountinfo = mkMountinfo "mountinfo-overmount-hidden" [
              (mkRootMountinfo wslRootDiscardOptions)
              "25 23 8:64 / / rw,relatime shared:2 - ext4 /dev/sde ${wslRootOptions}"
            ];
            status = "pass";
          };
          overmounted-discard-visible = {
            mountinfo = mkMountinfo "mountinfo-overmount-visible" [
              (mkRootMountinfo wslRootOptions)
              "25 23 8:64 / / rw,relatime shared:2 - ext4 /dev/sde ${wslRootDiscardOptions}"
            ];
            status = "fail";
          };
          non-ext4-root = {
            mountinfo = mkMountinfo "mountinfo-overlay-root" [
              "23 1 0:50 / / rw,relatime shared:1 - overlay overlay rw,lowerdir=/lower"
            ];
            status = "fail";
          };
          no-root-mount = {
            mountinfo = mkMountinfo "mountinfo-no-root" [ (mkStoreMountinfo wslRootOptions) ];
            status = "fail";
          };
          unreadable = {
            mountinfo = "/nonexistent/mountinfo";
            status = "fail";
          };
        };
        hostVhdVariant = {
          probe = mkWslVhdProbe {
            blockDevices = mkWslVhdBlockDevices "8:48" 536870912;
            powershellCommand = printWslconfig "wslconfig-host-variant" "[wsl2]\ndefaultVhdSize=256GB\n[experimental]\nsparseVhd=true\n";
            sizeBytes = 256 * 1073741824;
            sparse = true;
          };
          capacity = "pass";
          wslconfig = "pass";
        };
        mkWslMemoryObservation = import ./stability/impl/wsl-memory-package.nix;
        mkZoneinfo =
          name:
          {
            dma32Free,
            normalFree ? 487862,
            normalMin ? 59160,
          }:
          pkgs.writeText name ''
            Node 0, zone    DMA32
              pages free     ${toString dma32Free}
                    min      6375
                    low      16364
                    high     26353
                    protection: (0, 36208, 36208, 36208)
            Node 0, zone   Normal
              pages free     ${toString normalFree}
                    min      ${toString normalMin}
                    low      151854
                    high     244548
                    protection: (0, 0, 0, 0)
            Node 0, zone  Movable
              pages free     0
                    min      32
                    protection: (0, 0, 0, 0)
          '';
        mkBuddyinfo =
          name: normalHighOrders:
          pkgs.writeText name ''
            Node 0, zone    DMA32   1551   1317   1679   2502   1557    710    263    105      0      0      0
            Node 0, zone   Normal   2976  14639  10542   7585   4104    781     25 ${normalHighOrders}
          '';
        mkPressure =
          name: memoryFull: ioFull:
          pkgs.runCommandLocal name { } ''
            mkdir -p "$out"
            printf 'some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=1.00 avg60=%s avg300=1.00 total=1\n' \
              ${memoryFull} >"$out/memory"
            printf 'some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=1.00 avg60=%s avg300=1.00 total=1\n' \
              ${ioFull} >"$out/io"
          '';
        mkKernelLog =
          name: matches: latest:
          pkgs.writeShellScript name ''
            for argument in "$@"; do
              if [[ $argument == --grep=* ]]; then
                ${if matches == "" then "exit 1" else "printf '%s\\n' ${lib.escapeShellArg matches}; exit 0"}
              fi
            done
            printf '%s' ${lib.escapeShellArg latest}
          '';
        mkProcessList = name: rows: pkgs.writeShellScript name "printf '%s\\n' ${lib.escapeShellArg rows}";
        mkWslMemoryProbe =
          {
            journalctlCommand ? mkKernelLog "kernel-log-clean" "" "kernel: latest\n",
            psCommand ? mkProcessList "processes-live" "427501 121645 Relay(427503)\n 1 299 Relay\n1515710 65537 Relay",
            zoneinfo ? mkZoneinfo "zoneinfo-roomy" { dma32Free = 135220; },
            buddyinfo ? mkBuddyinfo "buddyinfo-roomy" "4 3 2 1",
            pressureRoot ? mkPressure "pressure-calm" "9.99" "9.99",
          }:
          mkWslMemoryObservation {
            inherit
              pkgs
              lib
              journalctlCommand
              psCommand
              zoneinfo
              buddyinfo
              pressureRoot
              ;
            journalTimeoutSeconds = 1;
            pressureWarning = 10;
            pressureFailure = 40;
            relayMinimumAgeSeconds = 300;
          };
        wslMemoryCases = {
          calm = {
            probe = mkWslMemoryProbe { };
            statuses = {
              vmbus-ring-failures = "pass";
              stuck-relays = "pass";
              high-order-pages = "pass";
              memory-pressure = "pass";
              io-pressure = "pass";
            };
            resource = {
              vmbusRingFailures = 0;
              stuckRelays = 0;
              ringOrderBlocks = 115;
              pageblocks = 3;
              memoryFullAvg60 = 9.99;
              ioFullAvg60 = 9.99;
            };
          };
          fragmented = {
            probe = mkWslMemoryProbe {
              journalctlCommand =
                mkKernelLog "kernel-log-failures" " vmbus_alloc_ring+0x78/0xd0\n vmbus_alloc_ring+0x78/0xd0"
                  "kernel: latest\n";
              psCommand = mkProcessList "processes-orphaned" "427501 121645 Relay(427503)\n 1 299 Relay\n 1 300 Relay\n 1 68114 Relay";
              buddyinfo = mkBuddyinfo "buddyinfo-fragmented" "0 0 0 0";
              pressureRoot = mkPressure "pressure-stalled" "10.00" "40.00";
            };
            statuses = {
              vmbus-ring-failures = "fail";
              stuck-relays = "fail";
              high-order-pages = "warn";
              memory-pressure = "warn";
              io-pressure = "fail";
            };
            resource = {
              vmbusRingFailures = 2;
              stuckRelays = 2;
              ringOrderBlocks = 105;
              pageblocks = 0;
              memoryFullAvg60 = 10;
              ioFullAvg60 = 40;
            };
          };
          reserved = {
            probe = mkWslMemoryProbe {
              zoneinfo = mkZoneinfo "zoneinfo-reserved" { dma32Free = 42710; };
              buddyinfo = mkBuddyinfo "buddyinfo-reserved" "0 0 0 0";
            };
            statuses = {
              vmbus-ring-failures = "pass";
              stuck-relays = "pass";
              high-order-pages = "fail";
              memory-pressure = "pass";
              io-pressure = "pass";
            };
            resource = {
              vmbusRingFailures = 0;
              stuckRelays = 0;
              ringOrderBlocks = 0;
              pageblocks = 0;
              memoryFullAvg60 = 9.99;
              ioFullAvg60 = 9.99;
            };
          };
          # boost を含む min を下回る zone の空き block まで数えると watermark で落ちる VMBus ring の確保を pass と誤るため zone の空きによる除外の省略は不可
          boosted = {
            probe = mkWslMemoryProbe {
              zoneinfo = mkZoneinfo "zoneinfo-boosted" {
                dma32Free = 42710;
                normalFree = 248000;
                normalMin = 248600;
              };
              buddyinfo = mkBuddyinfo "buddyinfo-boosted" "131 40 3 0";
            };
            statuses = {
              vmbus-ring-failures = "pass";
              stuck-relays = "pass";
              high-order-pages = "fail";
              memory-pressure = "pass";
              io-pressure = "pass";
            };
            resource = {
              vmbusRingFailures = 0;
              stuckRelays = 0;
              ringOrderBlocks = 0;
              pageblocks = 0;
              memoryFullAvg60 = 9.99;
              ioFullAvg60 = 9.99;
            };
          };
          unreadable = {
            probe = mkWslMemoryProbe {
              journalctlCommand = mkKernelLog "kernel-log-unreadable" "" "";
              psCommand = pkgs.writeShellScript "processes-unreadable" "exit 1";
              buddyinfo = "/nonexistent/buddyinfo";
              pressureRoot = "/nonexistent/pressure";
            };
            statuses = {
              vmbus-ring-failures = "fail";
              stuck-relays = "fail";
              high-order-pages = "fail";
              memory-pressure = "fail";
              io-pressure = "fail";
            };
            resource = {
              vmbusRingFailures = null;
              stuckRelays = null;
              ringOrderBlocks = null;
              pageblocks = null;
              memoryFullAvg60 = null;
              ioFullAvg60 = null;
            };
          };
          slow-kernel-log = {
            probe = mkWslMemoryProbe {
              journalctlCommand = pkgs.writeShellScript "kernel-log-slow" "sleep 30";
            };
            statuses = {
              vmbus-ring-failures = "warn";
              stuck-relays = "pass";
              high-order-pages = "pass";
              memory-pressure = "pass";
              io-pressure = "pass";
            };
            resource = {
              vmbusRingFailures = null;
              stuckRelays = 0;
              ringOrderBlocks = 115;
              pageblocks = 3;
              memoryFullAvg60 = 9.99;
              ioFullAvg60 = 9.99;
            };
          };
        };
      in
      {
        machine-profile-contract =
          assert lib.assertMsg (
            hostNames == builtins.attrNames machineConfigs
          ) "host registry and evaluated machine configs diverged";
          assert lib.assertMsg (lib.all machineProfileContractMatches hostNames)
            "machine profile facts did not reach the host configuration";
          assert lib.assertMsg (lib.all (
            name: !(machineConfigs.${name}.dotfiles.workstation ? windowsDrives)
          ) hostNames) "host profiles must not declare a Windows drive inventory";
          assert lib.assertMsg (
            memoryVariantConfig.services.zram-generator.settings.zram0.zram-size == "40 / 100 * ram"
            && memoryVariantConfig.dotfiles.health.observations."host/swap".minimumTotalBytes == 6 * 1073741824
            && memoryVariantConfig.dotfiles.health.observations."host/windows-memory-commit".warning == 80
            && memoryVariantConfig.dotfiles.health.observations."host/windows-memory-commit".failure == 90
          ) "machine-specific memory policy did not reach runtime observations";
          pkgs.runCommandLocal "check-machine-profile-contract" { } "touch $out";

        host-reserve-swap-contract =
          assert lib.assertMsg (
            let
              service = hostConfig.systemd.services.dotfiles-agent-reserve-swap or { };
            in
            lib.elem "multi-user.target" (service.wantedBy or [ ])
            && (service.restartIfChanged or true) == false
            && (service.serviceConfig.RemainAfterExit or false)
            && !(service.serviceConfig ? ExecStop)
          ) "追加 swap の起動時有効化と停止回避の契約を満たしません";
          pkgs.runCommandLocal "check-host-reserve-swap-contract" { nativeBuildInputs = [ pkgs.bash ]; } ''
            mkdir -p mock
            cat > mock/swapon <<'SH'
            #!${pkgs.bash}/bin/bash
            if [ "$1" = --show=NAME ]; then
              case "$SWAP_STATE" in
                active) echo /var/lib/dotfiles-agent-swap/reserve.swap ;;
                failed) exit 42 ;;
              esac
              exit 0
            fi
            printf '%s\n' "$*" >> "$OPERATIONS"
            SH
            chmod +x mock/swapon
            export PATH="$PWD/mock:$PATH" OPERATIONS="$PWD/operations"
            : > "$OPERATIONS"
            SWAP_STATE=active bash ${./stability/impl/reserve-swap.sh} /var/lib/dotfiles-agent-swap/reserve.swap
            test ! -s "$OPERATIONS"
            SWAP_STATE=inactive bash ${./stability/impl/reserve-swap.sh} /var/lib/dotfiles-agent-swap/reserve.swap
            test "$(cat "$OPERATIONS")" = '--priority 10 /var/lib/dotfiles-agent-swap/reserve.swap'
            : > "$OPERATIONS"
            if SWAP_STATE=failed bash ${./stability/impl/reserve-swap.sh} /var/lib/dotfiles-agent-swap/reserve.swap; then
              echo '利用状況の取得失敗後に有効化を続行しました' >&2
              exit 1
            fi
            test ! -s "$OPERATIONS"
            touch "$out"
          '';

        # 基盤の最大使用量を残し、同時に動く workload を MemoryHigh に収め、user.slice の一つの親で合計を抑える
        workload-envelope-contract =
          assert lib.assertMsg
            (lib.all (violations: violations == [ ]) (
              builtins.attrValues (lib.mapAttrs (_: workloadViolations) workloadConfigs)
            ))
            "workload envelope violations: ${
              builtins.toJSON (lib.mapAttrs (_: workloadViolations) workloadConfigs)
            }";
          assert lib.assertMsg (
            builtins.attrNames workloadConfigs
            == lib.sort builtins.lessThan (hostNames ++ [ "workload-variant" ])
          ) "every host and the reserve variant must be checked";
          assert lib.assertMsg
            (lib.all (mutation: workloadViolations mutation != [ ]) (builtins.attrValues workloadMutations))
            "workload envelope mutations escaped the contract: ${
              builtins.toJSON (
                builtins.attrNames (
                  lib.filterAttrs (_: mutation: workloadViolations mutation == [ ]) workloadMutations
                )
              )
            }";
          assert lib.assertMsg (observedReserveHolds hostConfig)
            "the host reserve, MemoryHigh or swap limit does not accommodate the observed host and workload";
          assert lib.assertMsg (
            !(observedReserveHolds (
              withWorkloadOptions hostConfig {
                hostReservePercent = 5;
                memoryHighPercent = 90;
              }
            ))
          ) "a reserve below the observed host peak escaped the contract";
          assert lib.assertMsg (
            !(observedReserveHolds (withWorkloadOptions hostConfig { memoryHighPercent = 60; }))
          ) "a MemoryHigh below the observed workload escaped the contract";
          pkgs.runCommandLocal "check-workload-envelope-contract"
            {
              nativeBuildInputs = [ pkgs.gnugrep ];
            }
            ''
              set -euo pipefail

              units=${systemUnits}
              aggregate_dropin=$units/${workstation.workload.slices.aggregate}.d/overrides.conf
              test -f "$units/${workstation.workload.slices.support}"
              test -f "$aggregate_dropin"
              grep -Fxq 'MemoryHigh=${toString workstation.workload.memoryHighPercent}%' "$aggregate_dropin"
              grep -Fxq 'MemoryMax=${toString workstation.workload.memoryMaxPercent}%' "$aggregate_dropin"
              grep -Fxq 'MemorySwapMax=${toString workstation.workload.memorySwapMaxPercent}%' "$aggregate_dropin"

              # logind の user-.slice の template は user- で始まる全 slice に TasksMax と StopWhenUnneeded を与える。
              # NixOS が配備しない間だけ user-workload.slice の資源と寿命は宣言した値になる
              test ! -e "$units/user-.slice.d"
              if [ -e "$units/user@.service.d/overrides.conf" ]; then
                if grep -Eq '^Slice=' "$units/user@.service.d/overrides.conf"; then
                  echo 'user@.service must stay in its canonical user-<UID>.slice' >&2
                  exit 1
                fi
              fi

              runtime=$TMPDIR/systemd-analyze-runtime
              mkdir -p "$runtime"
              HOME=$TMPDIR XDG_RUNTIME_DIR="$runtime" SYSTEMD_UNIT_PATH="$units" \
                ${lib.getExe' pkgs.systemd "systemd-analyze"} --user verify --man=no --generators=no \
                  ${workstation.workload.slices.aggregate} ${workstation.workload.slices.support}
              touch "$out"
            '';

        # root は WSL の host service が discard 付きで mount し、systemd-remount-fs は WSL で動かず、fileSystems にも root が無い。
        # 稼働中に remount せず、WSL init が起動時に一度だけ実行する wsl.conf の boot.command で外す
        wsl-root-discard-boot-contract =
          let
            bootCommand = hostConfig.wsl.wslConf.boot.command;
            commandTokens = lib.splitString " " bootCommand;
            wslConfLines = lib.splitString "\n" hostConfig.environment.etc."wsl.conf".text;
            headerIndex = lib.lists.findFirstIndex (line: line == "[boot]") null wslConfLines;
            afterHeader = lib.drop (headerIndex + 1) wslConfLines;
            bootSection = lib.take (lib.lists.findFirstIndex (
              line: lib.hasPrefix "[" line
            ) (builtins.length afterHeader) afterHeader) afterHeader;
            rootDiscardUnits = builtins.filter (
              name: (lib.hasInfix "discard" name || lib.hasInfix "remount" name) && name != "systemd-remount-fs"
            ) (builtins.attrNames (hostConfig.systemd.services // hostConfig.systemd.timers));
          in
          assert lib.assertMsg (
            builtins.length commandTokens == 4
            && lib.hasPrefix "/nix/store/" (builtins.elemAt commandTokens 0)
            && lib.hasSuffix "/bin/mount" (builtins.elemAt commandTokens 0)
            && builtins.elemAt commandTokens 1 == "-o"
            && builtins.elemAt commandTokens 2 == "remount,nodiscard"
            && builtins.elemAt commandTokens 3 == "/"
          ) "the WSL boot command must remount root with nodiscard through an absolute mount path";
          assert lib.assertMsg (
            lib.elem "command=${bootCommand}" bootSection
            && lib.count (line: lib.hasPrefix "command=" line) bootSection == 1
            && lib.elem "systemd=true" bootSection
          ) "/etc/wsl.conf [boot] must carry exactly the declared boot command next to systemd=true";
          assert lib.assertMsg (
            !(hostConfig.fileSystems ? "/")
          ) "an ordinary fileSystems root entry would be skipped on WSL and must not be the nodiscard route";
          assert lib.assertMsg (
            (hostConfig.systemd.services.systemd-remount-fs.unitConfig.ConditionVirtualization or null)
            == "!container"
          ) "systemd-remount-fs no longer skips WSL, so the boot command premise must be re-examined";
          assert lib.assertMsg (rootDiscardUnits == [ ])
            "root discard must not gain a unit next to the WSL boot command: ${builtins.toJSON rootDiscardUnits}";
          assert lib.assertMsg (
            !(hostConfig.services.fstrim.enable or false)
          ) "online fstrim must stay disabled on WSL";
          assert lib.assertMsg (lib.all
            (
              field:
              lib.elem "resource/wsl-vhd/root-discard"
                hostConfig.dotfiles.health.observations."host/wsl-vhd".${field}
            )
            [
              "allowedOutcomeIds"
              "requiredOutcomeIds"
            ]
          ) "the root discard outcome must be required from the WSL root VHD observation";
          pkgs.runCommandLocal "check-wsl-root-discard-boot-contract" { } ''
            touch "$out"
          '';

        host-stability-contract =
          assert lib.assertMsg (
            builtins.attrNames stabilityObservations == hostObservationKeys
          ) "host runtime observation registry is incomplete";
          assert lib.assertMsg (
            observationProjection == expectedObservationProjection
          ) "host runtime observation shape or canonical value drifted";
          assert lib.assertMsg (
            let
              command = hostObservations."host/windows-memory-commit".command;
            in
            command.dotfilesObservationCommandKind == "numeric-command-threshold"
            && command.meta.mainProgram == "dotfiles-observe-windows-memory-commit"
          ) "Windows committed memory must use a dedicated numeric threshold package";
          assert lib.assertMsg (
            let
              command = hostObservations."host/windows-drives".command;
            in
            command.dotfilesObservationCommandKind == "numeric-command-threshold-set"
            && command.meta.mainProgram == "dotfiles-observe-windows-drives"
            && lib.getExe command == "${lib.getBin command}/bin/dotfiles-observe-windows-drives"
          ) "Windows drives must use a dedicated numeric threshold set package";
          assert lib.assertMsg (
            let
              command = hostObservations."host/wsl-vhd".command;
            in
            command.dotfilesObservationCommandKind == "normalized-protocol"
            && command.meta.mainProgram == "dotfiles-observe-wsl-vhd"
          ) "WSL VHD must use a dedicated normalized protocol package";
          assert lib.assertMsg (
            let
              command = hostObservations."host/wsl-memory".command;
            in
            command.dotfilesObservationCommandKind == "normalized-protocol"
            && command.meta.mainProgram == "dotfiles-observe-wsl-memory"
          ) "WSL memory must use a dedicated normalized protocol package";
          assert lib.assertMsg (
            hostDefinitionKeys == hostObservationKeys
            && builtins.all (name: lib.hasPrefix "host/" name) hostDefinitionKeys
          ) "host observation definitions must use the host owner prefix";
          assert lib.assertMsg (stabilityContractMatches stabilityConfiguration hostObservations)
            "host settings and runtime observations do not share the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches stabilityConfiguration thresholdMutation)
          ) "root filesystem threshold mutation escaped the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches nixStorageReserveMutation hostObservations)
          ) "Nix storage reserve mutation escaped the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches stabilityConfiguration failureMessageMutation)
          ) "wrong non-empty failure message escaped the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches stabilityConfiguration timerRemovalMutation)
          ) "maintenance timer removal escaped the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches stabilityConfiguration homeManagerRestartRemovalMutation)
          ) "Home Manager restart observation removal escaped the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches stabilityConfiguration homeManagerRestartThresholdMutation)
          ) "Home Manager restart threshold mutation escaped the stability contract";
          assert lib.assertMsg
            (stabilityContractMatches stabilityConfiguration independentObservationDescriptionVariant)
            "an independent host-owned observation changed the stability contract";
          assert lib.assertMsg (
            !(stabilityContractMatches zramAlgorithmMutation hostObservations)
          ) "zram algorithm mutation escaped the stability contract";
          assert lib.assertMsg (
            selectStabilityObservations independentObservationDescriptionVariant == stabilityObservations
          ) "service descriptions must not select host runtime observations";
          assert lib.assertMsg (!zram.enable) "zramSwap must stay disabled on WSL";
          assert lib.assertMsg zramGenerator.enable "zram-generator is disabled";
          assert lib.assertMsg (
            zramGenerator.settings.zram0 == {
              compression-algorithm = "lzo-rle";
              swap-priority = 100;
              zram-size = "${toString workstation.swap.zramMemoryPercent} / 100 * ram";
            }
          ) "zram-generator output does not match the swap contract";
          assert lib.assertMsg (lib.elem "swap.target" (
            zramService.wantedBy or [ ]
          )) "dotfiles-zram-swap must be wanted by swap.target";
          assert lib.assertMsg (
            (zramService.unitConfig.DefaultDependencies or true) == false
          ) "dotfiles-zram-swap must disable default dependencies";
          assert lib.assertMsg (
            (zramService.restartIfChanged or true) == false
          ) "dotfiles-zram-swap must not restart on a configuration switch";
          assert lib.assertMsg (lib.elem "shutdown.target" (
            zramService.conflicts or [ ]
          )) "dotfiles-zram-swap must conflict with shutdown.target";
          assert lib.assertMsg (builtins.all (target: lib.elem target (zramService.before or [ ])) [
            "swap.target"
            "shutdown.target"
          ]) "dotfiles-zram-swap must complete before swap.target and shutdown.target";
          assert lib.assertMsg (
            zramService.serviceConfig.Type or null == "oneshot"
          ) "dotfiles-zram-swap must be a oneshot service";
          assert lib.assertMsg (zramService.serviceConfig.RemainAfterExit or false
          ) "dotfiles-zram-swap must remain active after setup";
          assert lib.assertMsg (
            zramService.serviceConfig ? ExecStopPost
          ) "dotfiles-zram-swap must clean up after failed setup";
          assert lib.assertMsg (lib.elem pkgs.util-linux (
            zramService.path or [ ]
          )) "dotfiles-zram-swap must expose mkswap from util-linux";
          assert lib.assertMsg (
            !(builtins.hasAttr "dotfiles-wsl-memory-reclaim" hostConfig.systemd.services)
            && !(builtins.hasAttr "dotfiles-wsl-memory-reclaim" hostConfig.systemd.timers)
          ) "WSL memory reclaim must not evict page cache during active sessions";
          assert lib.assertMsg (journald.storage == "persistent") "journald storage is not persistent";
          assert lib.assertMsg
            (lib.hasInfix "SystemMaxUse=${toString workstation.storage.journal.maximumGiB}G" journald.extraConfig)
            "journald SystemMaxUse does not follow the host storage policy";
          assert lib.assertMsg (lib.hasInfix "MaxRetentionSec=30day" journald.extraConfig)
            "journald retention is not bounded at 30 days";
          assert lib.assertMsg (
            !(hostConfig.services.fstrim.enable or false)
          ) "online fstrim must stay disabled on WSL";
          pkgs.runCommandLocal "check-host-stability-contract"
            {
              nativeBuildInputs = [
                pkgs.findutils
                pkgs.gnugrep
                pkgs.jq
              ];
            }
            ''
                      set -euo pipefail

                      test "$(${lib.getExe successfulProbe})" = 20

                      assert_failed_probe() {
                        local name=$1
                        local command=$2
                        local stdout="$TMPDIR/probe-$name.stdout"
                        local stderr="$TMPDIR/probe-$name.stderr"
                        local status

                        if "$command" >"$stdout" 2>"$stderr"; then
                          status=0
                        else
                          status=$?
                        fi
                        if ((status != 1)); then
                          echo "$name probe returned status $status instead of 1" >&2
                          return 1
                        fi
                        if [[ -s $stdout ]]; then
                          echo "$name probe leaked stdout" >&2
                          return 1
                        fi
                        if [[ -s $stderr ]]; then
                          echo "$name probe leaked stderr" >&2
                          return 1
                        fi
                      }

                      assert_failed_probe noisy ${lib.getExe noisyProbe}
                      assert_failed_probe invalid ${lib.getExe invalidProbe}
                      assert_failed_probe status ${lib.getExe statusProbe}
                      assert_failed_probe timeout ${lib.getExe timeoutProbe}

                      test "$(${lib.getExe drivesProbe})" = $'d 50\nc 9'
                      ${lib.concatStringsSep "\n" (
                        lib.mapAttrsToList (
                          name: probe: "assert_failed_probe drives-${name} ${lib.getExe probe}"
                        ) drivesFailedProbes
                      )}

                      assert_wsl_vhd() {
                        local name=$1
                        local command=$2
                        local capacity=$3
                        local wslconfig=$4
                        local root_discard=$5
                        local stdout="$TMPDIR/wsl-vhd-$name.stdout"

                        if ! "$command" >"$stdout" 2>"$TMPDIR/wsl-vhd-$name.stderr"; then
                          echo "WSL VHD $name probe did not produce an envelope" >&2
                          return 1
                        fi
                        if ! jq -e --arg capacity "$capacity" --arg wslconfig "$wslconfig" --arg rootDiscard "$root_discard" '
                          .schemaVersion == 1
                          and .resources == []
                          and (.outcomes | length) == 3
                          and (.outcomes | map({key: .id, value: .status}) | from_entries)
                            == {
                              "resource/wsl-vhd/capacity": $capacity,
                              "resource/wsl-vhd/wslconfig": $wslconfig,
                              "resource/wsl-vhd/root-discard": $rootDiscard
                            }
                          and all(.outcomes[]; (.message | length) > 0)
                        ' "$stdout" >/dev/null; then
                          echo "WSL VHD $name probe did not report capacity $capacity, .wslconfig $wslconfig and root discard $root_discard" >&2
                          cat "$stdout" >&2
                          return 1
                        fi
                      }

                      ${lib.concatStringsSep "\n" (
                        lib.mapAttrsToList (
                          name: case:
                          "assert_wsl_vhd ${name} ${lib.getExe case.probe} ${case.capacity} ${case.wslconfig} pass"
                        ) wslVhdCases
                      )}
                      ${lib.concatStringsSep "\n" (
                        lib.mapAttrsToList (
                          name: case:
                          "assert_wsl_vhd root-${name} ${
                            lib.getExe (mkWslVhdProbe {
                              inherit (case) mountinfo;
                            })
                          } pass pass ${case.status}"
                        ) wslRootDiscardCases
                      )}
                      assert_wsl_vhd host-policy ${lib.getExe hostVhdVariant.probe} ${hostVhdVariant.capacity} ${hostVhdVariant.wslconfig} pass

                      assert_wsl_memory() {
                        local name=$1
                        local command=$2
                        local expected=$3
                        local stdout="$TMPDIR/wsl-memory-$name.stdout"

                        if ! "$command" >"$stdout" 2>"$TMPDIR/wsl-memory-$name.stderr"; then
                          echo "WSL memory $name probe did not produce an envelope" >&2
                          return 1
                        fi
                        if ! jq -e --argjson expected "$expected" '
                          .schemaVersion == 1
                          and (.outcomes | map({key: (.id | ltrimstr("resource/wsl-memory/")), value: .status}) | from_entries)
                            == $expected.statuses
                          and .resources == [{key: "wslMemory", value: $expected.resource}]
                          and all(.outcomes[]; (.message | length) > 0)
                        ' "$stdout" >/dev/null; then
                          echo "WSL memory $name probe did not report $expected" >&2
                          cat "$stdout" >&2
                          return 1
                        fi
                      }

                      ${lib.concatStringsSep "\n" (
                        lib.mapAttrsToList (
                          name: case:
                          "assert_wsl_memory ${name} ${lib.getExe case.probe} ${
                            lib.escapeShellArg (builtins.toJSON { inherit (case) statuses resource; })
                          }"
                        ) wslMemoryCases
                      )}

                      zram_service=${systemUnits}/dotfiles-zram-swap.service
                      zram_wants=${systemUnits}/swap.target.wants/dotfiles-zram-swap.service

                      test ! -e ${systemUnits}/timers.target.wants/fstrim.timer
                      test -L "$zram_service"
                      test -L "$zram_wants"
                      test ! -e ${systemUnits}/dotfiles-wsl-memory-reclaim.service
                      test ! -e ${systemUnits}/dotfiles-wsl-memory-reclaim.timer
                      test ! -e ${systemUnits}/timers.target.wants/dotfiles-wsl-memory-reclaim.timer

                      grep -Fxq 'DefaultDependencies=false' "$zram_service"
                      conflict_targets=$(sed -n 's/^Conflicts=//p' "$zram_service")
                      if ! tr ' ' '\n' <<<"$conflict_targets" | grep -Fxq shutdown.target; then
                        echo 'dotfiles-zram-swap does not conflict with shutdown.target' >&2
                        exit 1
                      fi
                      before_targets=$(sed -n 's/^Before=//p' "$zram_service")
                      for target in swap.target shutdown.target; do
                        if ! tr ' ' '\n' <<<"$before_targets" | grep -Fxq "$target"; then
                          echo "dotfiles-zram-swap is not ordered before $target" >&2
                          exit 1
                        fi
                      done
                      grep -Fxq 'Type=oneshot' "$zram_service"
                      grep -Fxq 'RemainAfterExit=true' "$zram_service"

                      verify_no_ordering_cycle() {
                        local unit_path=$1
                        local stderr=$2
                        local runtime=$TMPDIR/systemd-analyze-runtime
                        local status=0

                        mkdir -p "$runtime"
                        HOME=$TMPDIR \
                          XDG_RUNTIME_DIR="$runtime" \
                          SYSTEMD_UNIT_PATH="$unit_path" \
                          ${lib.getExe' pkgs.systemd "systemd-analyze"} --user verify --man=no --generators=no \
                            basic.target \
                            2>"$stderr" || status=$?
                        if ((status != 0)); then
                          return 2
                        fi
                        ! grep -Eq 'Found ordering cycle|deleted to break ordering cycle' "$stderr"
                      }

                      if ! verify_no_ordering_cycle "${systemUnits}" "$TMPDIR/zram-units.stderr"; then
                        sed -n '1,80p' "$TMPDIR/zram-units.stderr" >&2
                        echo 'generated system unit tree failed ordering verification' >&2
                        exit 1
                      fi

                      cycle_unit_overlay=$TMPDIR/zram-cycle-units
                      mkdir -p "$cycle_unit_overlay/dotfiles-zram-swap.service.d"
                      printf '[Unit]\nAfter=basic.target\n' > "$cycle_unit_overlay/dotfiles-zram-swap.service.d/cycle.conf"
                      cycle_result=0
                      verify_no_ordering_cycle "$cycle_unit_overlay:${systemUnits}" "$TMPDIR/zram-cycle.stderr" \
                        || cycle_result=$?
                      if ((cycle_result != 1)); then
                        sed -n '1,80p' "$TMPDIR/zram-cycle.stderr" >&2
                        echo 'After=basic.target cycle mutation escaped host unit verification' >&2
                        exit 1
                      fi

                      zram_setup=$(sed -n 's/^ExecStart=//p' "$zram_service")
                      zram_teardown=$(sed -n 's/^ExecStopPost=//p' "$zram_service")
                      zram_generator=$(sed -n 's|^\(/nix/store/[^ ]*/lib/systemd/system-generators/zram-generator\).*|\1|p' "$zram_setup")
                      test -x "$zram_generator"
                      test -x "$zram_setup"
                      test -x "$zram_teardown"

                      lifecycle_root=$TMPDIR/zram-lifecycle
                      mkdir -p "$lifecycle_root/bin" "$lifecycle_root/sys/block/zram0"
                      : > "$lifecycle_root/operations"
                      : > "$lifecycle_root/proc-swaps"
                      touch "$lifecycle_root/sys/block/zram0/reset"
                      cat > "$lifecycle_root/bin/grep" <<EOF
              #!${lib.getExe pkgs.bash}
              exec ${lib.getExe pkgs.gnugrep} "\$@"
              EOF
                      cat > "$lifecycle_root/bin/test" <<EOF
              #!${lib.getExe pkgs.bash}
              if [ "\$1" = -b ] && [ "\$2" = /dev/zram0 ]; then
                exit 0
              fi
              exec ${lib.getExe' pkgs.coreutils "test"} "\$@"
              EOF
                      cat > "$lifecycle_root/bin/modprobe" <<EOF
              #!${lib.getExe pkgs.bash}
              printf 'modprobe %s\n' "\$*" >> "$lifecycle_root/operations"
              EOF
                      cat > "$lifecycle_root/bin/swapon" <<EOF
              #!${lib.getExe pkgs.bash}
              printf 'swapon %s\n' "\$*" >> "$lifecycle_root/operations"
              EOF
                      cat > "$lifecycle_root/bin/zram-generator" <<EOF
              #!${lib.getExe pkgs.bash}
              if [ "\$1" = --setup-device ]; then
                printf 'generator setup %s\n' "\$2" >> "$lifecycle_root/operations"
                if ${lib.getExe' pkgs.coreutils "test"} -e "$lifecycle_root/fail-setup"; then
                  exit 7
                fi
              elif [ "\$1" = --reset-device ]; then
                printf 'generator reset %s\n' "\$2" >> "$lifecycle_root/operations"
              else
                exit 64
              fi
              EOF
                      chmod +x "$lifecycle_root/bin/"*
                      patch_lifecycle() {
                        sed \
                          -e "s|/nix/store/[^/]*/bin/grep|$lifecycle_root/bin/grep|g" \
                          -e "s|/nix/store/[^/]*/bin/modprobe|$lifecycle_root/bin/modprobe|g" \
                          -e "s|/nix/store/[^/]*/lib/systemd/system-generators/zram-generator|$lifecycle_root/bin/zram-generator|g" \
                          -e "s|/nix/store/[^/]*/bin/swapon|$lifecycle_root/bin/swapon|g" \
                          -e "s|/proc/swaps|$lifecycle_root/proc-swaps|g" \
                          -e "s|/sys/block/zram0/reset|$lifecycle_root/sys/block/zram0/reset|g" \
                          "$1" >"$2"
                        chmod +x "$2"
                      }
                      patched_setup=$lifecycle_root/setup
                      patched_teardown=$lifecycle_root/teardown
                      patch_lifecycle "$zram_setup" "$patched_setup"
                      patch_lifecycle "$zram_teardown" "$patched_teardown"
                      run_lifecycle() {
                        local script=$1
                        set +e
                        PATH="$lifecycle_root/bin:$PATH" \
                          ${lib.getExe pkgs.bash} -c 'enable -n test; source "$1"' lifecycle "$script"
                        local status=$?
                        set -e
                        return "$status"
                      }
                      for active_name in /zram0 /dev/zram0; do
                        printf '%s partition 4294967296 100\n' "$active_name" > "$lifecycle_root/proc-swaps"
                        : > "$lifecycle_root/operations"
                        run_lifecycle "$patched_setup"
                        run_lifecycle "$patched_teardown"
                        if grep -q . "$lifecycle_root/operations"; then
                          echo "active zram lifecycle performed an operation" >&2
                          exit 1
                        fi
                      done
                      : > "$lifecycle_root/proc-swaps"
                      : > "$lifecycle_root/operations"
                      touch "$lifecycle_root/fail-setup"
                      setup_status=0
                      run_lifecycle "$patched_setup" || setup_status=$?
                      test "$setup_status" -eq 7
                      run_lifecycle "$patched_teardown"
                      grep -Fxq 'modprobe zram num_devices=1' "$lifecycle_root/operations"
                      grep -Fxq 'generator setup zram0' "$lifecycle_root/operations"
                      grep -Fxq 'generator reset zram0' "$lifecycle_root/operations"
                      ! grep -Fq 'swapon ' "$lifecycle_root/operations"
                      ! grep -Fq 'swapoff ' "$lifecycle_root/operations"

                      dependency_pattern='^(After|Before|Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|PropagatesReloadTo|ReloadPropagatedFrom|JoinsNamespaceOf)=.*(dotfiles-zram-swap\.service|systemd-zram-setup@[^[:space:]]*\.service|(dev-)?zram[^[:space:]]*\.swap)'
                      dependency_probe=$TMPDIR/zram-dependency-probe.service
                      printf '%s\n' 'Requires=dotfiles-zram-swap.service' > "$dependency_probe"
                      if ! grep -Eq "$dependency_pattern" "$dependency_probe"; then
                        echo 'zram dependency pattern does not cover the WSL lifecycle service' >&2
                        exit 1
                      fi
                      if find -L ${systemUnits} -type f \( -name '*.service' -o -name '*.conf' \) \
                        -exec grep -HnE "$dependency_pattern" {} +; then
                        echo 'a generated service depends on a zram swap or setup unit' >&2
                        exit 1
                      fi

                      while IFS= read -r dependency_link; do
                        dependency=$(basename "$dependency_link")
                        target=$(readlink "$dependency_link")
                        if printf '%s\n%s\n' "$dependency" "$target" \
                          | grep -Eq 'dotfiles-zram-swap\.service|systemd-zram-setup@.*\.service|(dev-)?zram.*\.swap'; then
                          echo "a generated service dependency symlink references zram: $dependency_link" >&2
                          exit 1
                        fi
                      done < <(
                        find ${systemUnits} -type l \
                          \( -path '*.service.wants/*' -o -path '*.service.requires/*' -o -path '*.service.upholds/*' \) \
                          -print
                      )

                      grep -Fxq 'Storage=persistent' ${journaldConfig}
                      grep -Fxq 'SystemMaxUse=${toString workstation.storage.journal.maximumGiB}G' ${journaldConfig}
                      grep -Fxq 'MaxRetentionSec=30day' ${journaldConfig}

                      grep -Fxq '[zram0]' ${zramConfig}
                      grep -Fxq 'compression-algorithm=lzo-rle' ${zramConfig}
                      grep -Fxq 'swap-priority=100' ${zramConfig}
                      grep -Fxq 'zram-size=${toString workstation.swap.zramMemoryPercent} / 100 * ram' ${zramConfig}
                      if grep -q '^writeback-device=' ${zramConfig}; then
                        echo 'zram writeback was enabled' >&2
                        exit 1
                      fi

                      touch $out
            '';
      }
    )
  ];
}
