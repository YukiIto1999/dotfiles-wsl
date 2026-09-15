{
  pkgs,
  lib,
  hostConfig,
  hostOptions,
  hostNames,
  machineConfigs,
  mkNixosSystem,
  normalMachineModule,
  ...
}:

let
  workstation = hostConfig.dotfiles.workstation;
  windowsDriveObservationKeys = map (drive: "host/windows-${drive}-drive") workstation.windowsDrives;
  zram = hostConfig.zramSwap;
  zramGenerator = hostConfig.services.zram-generator;
  zramService = hostConfig.systemd.services.dotfiles-zram-swap or { };
  wslMemoryReclaimService = hostConfig.systemd.services.dotfiles-wsl-memory-reclaim or { };
  wslMemoryReclaimTimer = hostConfig.systemd.timers.dotfiles-wsl-memory-reclaim or { };
  journald = hostConfig.services.journald;
  fstrimService = hostConfig.systemd.services.fstrim or { };
  fstrimTimer = hostConfig.systemd.timers.fstrim;
  systemUnits = hostConfig.environment.etc."systemd/system".source;
  journaldConfig = hostConfig.environment.etc."systemd/journald.conf".source;
  zramConfig = hostConfig.environment.etc."systemd/zram-generator.conf".source;
  expectedVirtualMemorySysctl = {
    "vm.min_free_kbytes" = 262144;
    "vm.watermark_scale_factor" = 100;
    "vm.compaction_proactiveness" = 40;
    "vm.defrag_mode" = 1;
  };
  expectedNixStorageReserve = {
    "min-free" = 171798691840;
    "max-free" = 274877906944;
  };
  virtualMemorySysctl = builtins.intersectAttrs expectedVirtualMemorySysctl hostConfig.boot.kernel.sysctl;
  hostObservationKeys = lib.sort builtins.lessThan (
    [
      "host/fstrim"
      "host/home-manager"
      "host/home-manager-restart"
      "host/journald"
      "host/nix-daemon"
      "host/nix-gc"
      "host/root-filesystem"
      "host/swap"
      "host/system-generation"
      "host/windows-memory-commit"
      "host/wsl-memory-reclaim"
    ]
    ++ windowsDriveObservationKeys
  );
  hostObservations = lib.filterAttrs (
    name: _: lib.hasPrefix "host/" name
  ) hostConfig.dotfiles.health.observations;
  selectStabilityObservations =
    observations: builtins.intersectAttrs (lib.genAttrs hostObservationKeys (_: null)) observations;
  stabilityObservations = selectStabilityObservations hostObservations;
  observationProjection = lib.mapAttrs (
    _: observation: builtins.removeAttrs observation [ "command" ]
  ) stabilityObservations;
  expectedBaseObservationProjection = {
    "host/fstrim" = {
      activeStates = [ "active" ];
      checkId = "maintenance/fstrim.timer";
      failureMessage = "fstrim.timer or its service is not operational";
      kind = "systemd-timer";
      resourceKey = null;
      service = "fstrim.service";
      serviceResults = [ "success" ];
      timeoutSeconds = 10;
      timer = "fstrim.timer";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
    };
    "host/wsl-memory-reclaim" = {
      activeStates = [ "active" ];
      checkId = "maintenance/dotfiles-wsl-memory-reclaim.timer";
      failureMessage = "dotfiles-wsl-memory-reclaim.timer or its service is not operational";
      kind = "systemd-timer";
      resourceKey = null;
      service = "dotfiles-wsl-memory-reclaim.service";
      serviceResults = [ "success" ];
      timeoutSeconds = 10;
      timer = "dotfiles-wsl-memory-reclaim.timer";
      unitFileStates = [
        "enabled"
        "enabled-runtime"
      ];
    };
    "host/home-manager" = {
      activeStates = [ "active" ];
      checkId = "home-manager";
      failureMessage = "home-manager-${hostConfig.dotfiles.workstation.username}.service is not operational";
      kind = "systemd-service";
      loadStates = [ "loaded" ];
      resourceKey = null;
      results = [ "success" ];
      timeoutSeconds = 10;
      unit = "home-manager-${hostConfig.dotfiles.workstation.username}.service";
    };
    "host/home-manager-restart" = {
      checkId = "restart/service/home-manager-${hostConfig.dotfiles.workstation.username}.service";
      failureAt = 20;
      failureMessage = "could not observe restart count for home-manager-${hostConfig.dotfiles.workstation.username}.service";
      kind = "restart-counter";
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
      maximumBytes = 4294967296;
      resourceKey = "journald";
      timeoutSeconds = 10;
    };
    "host/nix-daemon" = {
      activeStates = [ "active" ];
      checkId = "nix-daemon";
      failureMessage = "nix-daemon.socket is not operational";
      kind = "systemd-socket";
      loadStates = [ "loaded" ];
      resourceKey = null;
      results = [ "success" ];
      timeoutSeconds = 10;
      unit = "nix-daemon.socket";
    };
    "host/nix-gc" = {
      activeStates = [ "active" ];
      checkId = "maintenance/nix-gc.timer";
      failureMessage = "nix-gc.timer or its service is not operational";
      kind = "systemd-timer";
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
  };
  expectedWindowsDriveObservationProjection = builtins.listToAttrs (
    map (
      drive:
      lib.nameValuePair "host/windows-${drive}-drive" {
        checkId = "resource/windows-${drive}-drive";
        failure = 10;
        failureMessage = "could not observe Windows ${lib.toUpper drive} drive free space";
        kind = "numeric-command-threshold";
        metric = "free-percent";
        resourceKey = "windows${lib.toUpper drive}Drive";
        timeoutSeconds = 10;
        warning = 15;
      }
    ) workstation.windowsDrives
  );
  expectedObservationProjection =
    expectedBaseObservationProjection // expectedWindowsDriveObservationProjection;
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
    fstrimInterval = hostConfig.services.fstrim.interval;
    homeManagerUnit = "home-manager-${hostConfig.dotfiles.workstation.username}.service";
    nixGc = hostConfig.nix.gc;
    nixStorageReserve = builtins.intersectAttrs expectedNixStorageReserve hostConfig.nix.settings;
    timers = hostConfig.systemd.timers;
    inherit virtualMemorySysctl;
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
      fstrimObservation = candidateStabilityObservations."host/fstrim" or { };
    in
    builtins.attrNames candidateStabilityObservations == hostObservationKeys
    && candidateProjection == expectedObservationProjection
    &&
      (candidateConfiguration.zram.compression-algorithm or null)
      == (swapObservation.requiredZramAlgorithm or null)
    && lib.hasInfix "SystemMaxUse=${toString (builtins.div (journalObservation.maximumBytes or 0) 1073741824)}G" candidateConfiguration.journald.extraConfig
    && candidateConfiguration.nixGc.automatic
    && candidateConfiguration.nixGc.persistent
    && candidateConfiguration.nixStorageReserve == expectedNixStorageReserve
    && (nixGcObservation.timer or null) == "nix-gc.timer"
    && builtins.hasAttr "nix-gc" candidateConfiguration.timers
    && (fstrimObservation.timer or null) == "fstrim.timer"
    && builtins.hasAttr "fstrim" candidateConfiguration.timers
    && candidateConfiguration.fstrimInterval == "weekly"
    && (homeManagerObservation.unit or null) == candidateConfiguration.homeManagerUnit
    && (homeManagerRestartObservation.target or null) == candidateConfiguration.homeManagerUnit
    && (homeManagerRestartObservation.warningAt or null) == 5
    && (homeManagerRestartObservation.failureAt or null) == 20
    && candidateConfiguration.virtualMemorySysctl == expectedVirtualMemorySysctl;
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
  timerRemovalMutation = builtins.removeAttrs hostObservations [ "host/fstrim" ];
  homeManagerRestartRemovalMutation = builtins.removeAttrs hostObservations [
    "host/home-manager-restart"
  ];
  homeManagerRestartThresholdMutation = hostObservations // {
    "host/home-manager-restart" = hostObservations."host/home-manager-restart" or { } // {
      warningAt = 6;
    };
  };
  additionalObservationVariantConfig =
    (mkNixosSystem [
      normalMachineModule
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
      }
    ]).config;
  additionalObservationVariant = lib.filterAttrs (
    name: _: lib.hasPrefix "host/" name
  ) additionalObservationVariantConfig.dotfiles.health.observations;
  zramAlgorithmMutation = stabilityConfiguration // {
    zram = stabilityConfiguration.zram // {
      compression-algorithm = "zstd";
    };
  };
  descriptionVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { config, lib, ... }:
        {
          systemd.services."home-manager-${config.dotfiles.workstation.username}".description =
            lib.mkForce "A description must not select the Home Manager observation";
        }
      )
    ]).config;
  descriptionVariantStabilityObservations = selectStabilityObservations (
    lib.filterAttrs (
      name: _: lib.hasPrefix "host/" name
    ) descriptionVariantConfig.dotfiles.health.observations
  );
  windowsObservationCommands =
    lib.genAttrs windowsDriveObservationKeys (name: "dotfiles-observe-${lib.removePrefix "host/" name}")
    // {
      "host/windows-memory-commit" = "dotfiles-observe-windows-memory-commit";
    };
  driveObservationKeysFor =
    candidate:
    lib.sort builtins.lessThan (
      map (drive: "host/windows-${drive}-drive") candidate.dotfiles.workstation.windowsDrives
    );
  actualDriveObservationKeysFor =
    candidate:
    lib.sort builtins.lessThan (
      builtins.filter (name: lib.hasPrefix "host/windows-" name && lib.hasSuffix "-drive" name) (
        builtins.attrNames candidate.dotfiles.health.observations
      )
    );
  machineProfileContractMatches =
    name:
    let
      candidate = machineConfigs.${name};
      candidateWorkstation = candidate.dotfiles.workstation;
      candidateSwap = candidate.dotfiles.health.observations."host/swap";
      candidateWindowsMemory = candidate.dotfiles.health.observations."host/windows-memory-commit";
    in
    candidate.networking.hostName == name
    && actualDriveObservationKeysFor candidate == driveObservationKeysFor candidate
    &&
      candidate.services.zram-generator.settings.zram0.zram-size
      == "${toString candidateWorkstation.swap.zramMemoryPercent} / 100 * ram"
    && candidateSwap.minimumTotalBytes == candidateWorkstation.swap.minimumTotalGiB * 1073741824
    && candidateWindowsMemory.warning == candidateWorkstation.windowsMemoryCommit.warning
    && candidateWindowsMemory.failure == candidateWorkstation.windowsMemoryCommit.failure;
  memoryVariantConfig =
    (mkNixosSystem [
      normalMachineModule
      {
        dotfiles.workstation.swap = {
          zramMemoryPercent = 40;
          minimumTotalGiB = 6;
        };
        dotfiles.workstation.windowsMemoryCommit = {
          warning = 80;
          failure = 90;
        };
      }
    ]).config;
  powershellProbe = ''
    $volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'"; if ($null -eq $volume -or $volume.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor(($volume.FreeSpace * 100) / $volume.Size))
  '';
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
  successfulPowerShell = mkFakePowerShell powershellProbe "windows-drive-success" "printf '20\\r\\n'";
  noisyPowerShell = mkFakePowerShell powershellProbe "windows-drive-noisy" ''
    printf '20\r\nnoise\n'
    printf 'WINDOWS_DRIVE_NOISY_STDERR_POISON\n' >&2
  '';
  invalidPowerShell = mkFakePowerShell powershellProbe "windows-drive-invalid" "printf '101\\r\\n'";
  statusPowerShell =
    mkFakePowerShell powershellProbe "windows-drive-status"
      "printf '20\\r\\n'; exit 7";
  timeoutPowerShell =
    mkFakePowerShell powershellProbe "windows-drive-timeout"
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
      commandName = "dotfiles-observe-windows-d-drive";
      timeoutSeconds = 0.1;
    };
  successfulProbe = mkProbe successfulPowerShell;
  noisyProbe = mkProbe noisyPowerShell;
  invalidProbe = mkProbe invalidPowerShell;
  statusProbe = mkProbe statusPowerShell;
  timeoutProbe = mkProbe timeoutPowerShell;
in
{
  machine-profile-contract =
    assert lib.assertMsg (
      hostNames == builtins.attrNames machineConfigs
    ) "host registry and evaluated machine configs diverged";
    assert lib.assertMsg (lib.all machineProfileContractMatches hostNames)
      "machine profile facts did not reach the host configuration";
    assert lib.assertMsg (
      machineConfigs.nixos.dotfiles.workstation.windowsDrives == [
        "c"
        "d"
        "e"
      ]
    ) "nixos Windows drive inventory drifted";
    assert lib.assertMsg (
      machineConfigs.tcs-a295.dotfiles.workstation.windowsDrives == [
        "c"
        "d"
      ]
    ) "tcs-a295 Windows drive inventory drifted";
    assert lib.assertMsg (
      memoryVariantConfig.services.zram-generator.settings.zram0.zram-size == "40 / 100 * ram"
      && memoryVariantConfig.dotfiles.health.observations."host/swap".minimumTotalBytes == 6 * 1073741824
      && memoryVariantConfig.dotfiles.health.observations."host/windows-memory-commit".warning == 80
      && memoryVariantConfig.dotfiles.health.observations."host/windows-memory-commit".failure == 90
    ) "machine-specific memory policy did not reach runtime observations";
    pkgs.runCommandLocal "check-machine-profile-contract" { } "touch $out";

  host-stability-contract =
    assert lib.assertMsg (
      builtins.attrNames stabilityObservations == hostObservationKeys
    ) "host runtime observation registry is incomplete";
    assert lib.assertMsg (
      observationProjection == expectedObservationProjection
    ) "host runtime observation shape or canonical value drifted";
    assert lib.assertMsg (lib.all
      (
        name:
        let
          command = hostObservations.${name}.command;
          mainProgram = command.meta.mainProgram;
        in
        command.dotfilesObservationCommandKind == "numeric-command-threshold"
        && mainProgram == windowsObservationCommands.${name}
        && lib.getExe command == "${lib.getBin command}/bin/${mainProgram}"
      )
      (builtins.attrNames windowsObservationCommands)
    ) "Windows resource observations must use dedicated numeric threshold packages";
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
    assert lib.assertMsg (stabilityContractMatches stabilityConfiguration additionalObservationVariant)
      "an independent host-owned observation changed the stability contract";
    assert lib.assertMsg (
      !(stabilityContractMatches zramAlgorithmMutation hostObservations)
    ) "zram algorithm mutation escaped the stability contract";
    assert lib.assertMsg (
      descriptionVariantStabilityObservations == stabilityObservations
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
      wslMemoryReclaimService.serviceConfig.Type or null == "oneshot"
    ) "WSL memory reclaim must be an isolated oneshot service";
    assert lib.assertMsg (
      wslMemoryReclaimService.serviceConfig.TimeoutStartSec or null == "20s"
    ) "WSL memory reclaim must not remain blocked indefinitely";
    assert lib.assertMsg (
      wslMemoryReclaimService.serviceConfig.Nice or null == 19
      && wslMemoryReclaimService.serviceConfig.IOSchedulingClass or null == "idle"
    ) "WSL memory reclaim must yield to active sessions";
    assert lib.assertMsg (
      wslMemoryReclaimService.unitConfig.ConditionVirtualization or null == "wsl"
    ) "WSL memory reclaim must run only under WSL";
    assert lib.assertMsg (
      lib.elem "timers.target" (wslMemoryReclaimTimer.wantedBy or [ ])
      && wslMemoryReclaimTimer.timerConfig.OnBootSec or null == "45s"
      && wslMemoryReclaimTimer.timerConfig.OnUnitInactiveSec or null == "30s"
      && wslMemoryReclaimTimer.timerConfig.AccuracySec or null == "5s"
      && !(wslMemoryReclaimTimer.timerConfig.Persistent or true)
    ) "WSL memory reclaim timer contract drifted";
    assert lib.assertMsg (journald.storage == "persistent") "journald storage is not persistent";
    assert lib.assertMsg (lib.hasInfix "SystemMaxUse=4G" journald.extraConfig)
      "journald SystemMaxUse is not bounded at 4G";
    assert lib.assertMsg (lib.hasInfix "MaxRetentionSec=30day" journald.extraConfig)
      "journald retention is not bounded at 30 days";
    assert lib.assertMsg (
      fstrimService.overrideStrategy or null == "asDropin"
    ) "fstrim.service must be overridden with a drop-in";
    assert lib.assertMsg (
      fstrimService.unitConfig.ConditionVirtualization or [ ] == [
        ""
        "wsl"
      ]
    ) "fstrim.service virtualization condition is not reset for WSL";
    assert lib.assertMsg (
      fstrimTimer.overrideStrategy or null == "asDropin"
    ) "fstrim.timer must be overridden with a drop-in";
    assert lib.assertMsg (
      fstrimTimer.unitConfig.ConditionVirtualization or [ ] == [
        ""
        "wsl"
      ]
    ) "fstrim.timer virtualization condition is not reset for WSL";
    assert lib.assertMsg (
      fstrimTimer.timerConfig.OnCalendar == [
        ""
        hostConfig.services.fstrim.interval
      ]
    ) "fstrim must keep the NixOS schedule";
    pkgs.runCommandLocal "check-host-stability-contract"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
        ];
      }
      ''
                set -euo pipefail

                test "$(${lib.getExe successfulProbe})" = 20

                assert_failed_probe() {
                  local name=$1
                  local command=$2
                  local stdout="$TMPDIR/windows-drive-$name.stdout"
                  local stderr="$TMPDIR/windows-drive-$name.stderr"
                  local status

                  if "$command" >"$stdout" 2>"$stderr"; then
                    status=0
                  else
                    status=$?
                  fi
                  if ((status != 1)); then
                    echo "Windows drive $name probe returned status $status instead of 1" >&2
                    return 1
                  fi
                  if [[ -s $stdout ]]; then
                    echo "Windows drive $name probe leaked stdout" >&2
                    return 1
                  fi
                  if [[ -s $stderr ]]; then
                    echo "Windows drive $name probe leaked stderr" >&2
                    return 1
                  fi
                }

                assert_failed_probe noisy ${lib.getExe noisyProbe}
                assert_failed_probe invalid ${lib.getExe invalidProbe}
                assert_failed_probe status ${lib.getExe statusProbe}
                assert_failed_probe timeout ${lib.getExe timeoutProbe}

                service=${systemUnits}/fstrim.service
                service_drop_in=${systemUnits}/fstrim.service.d/overrides.conf
                timer=${systemUnits}/fstrim.timer
                timer_drop_in=${systemUnits}/fstrim.timer.d/overrides.conf
                zram_service=${systemUnits}/dotfiles-zram-swap.service
                zram_wants=${systemUnits}/swap.target.wants/dotfiles-zram-swap.service
                wsl_reclaim_service=${systemUnits}/dotfiles-wsl-memory-reclaim.service
                wsl_reclaim_timer=${systemUnits}/dotfiles-wsl-memory-reclaim.timer
                wsl_reclaim_wants=${systemUnits}/timers.target.wants/dotfiles-wsl-memory-reclaim.timer

                test -L "$service"
                test -L "$timer"
                test -f "$service_drop_in"
                test -f "$timer_drop_in"
                test -L "$zram_service"
                test -L "$zram_wants"
                test -L "$wsl_reclaim_service"
                test -L "$wsl_reclaim_timer"
                test -L "$wsl_reclaim_wants"

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

                grep -Fxq 'ConditionVirtualization=wsl' "$wsl_reclaim_service"
                grep -Fxq 'Type=oneshot' "$wsl_reclaim_service"
                grep -Fxq 'TimeoutStartSec=20s' "$wsl_reclaim_service"
                grep -Fxq 'Nice=19' "$wsl_reclaim_service"
                grep -Fxq 'IOSchedulingClass=idle' "$wsl_reclaim_service"
                grep -Fxq 'ConditionVirtualization=wsl' "$wsl_reclaim_timer"
                grep -Fxq 'OnBootSec=45s' "$wsl_reclaim_timer"
                grep -Fxq 'OnUnitInactiveSec=30s' "$wsl_reclaim_timer"
                grep -Fxq 'AccuracySec=5s' "$wsl_reclaim_timer"
                grep -Fxq 'Persistent=false' "$wsl_reclaim_timer"

                wsl_reclaim_command=$(sed -n 's/^ExecStart=//p' "$wsl_reclaim_service")
                test -x "$wsl_reclaim_command"
                reclaim_root=$TMPDIR/wsl-memory-reclaim
                mkdir -p "$reclaim_root"
                meminfo=$reclaim_root/meminfo
                drop_caches=$reclaim_root/drop-caches
                state_directory=$reclaim_root/state
                legacy_state=$state_directory/last-success
                state=$state_directory/last-success-uptime-seconds
                uptime=$reclaim_root/uptime

                write_meminfo() {
                  local total=$1
                  local free=$2
                  local cached=$3
                  local shmem=$4
                  local dirty=$5
                  local writeback=$6
                  printf 'MemTotal: %s kB\nMemFree: %s kB\nCached: %s kB\nShmem: %s kB\nDirty: %s kB\nWriteback: %s kB\n' \
                    "$total" "$free" "$cached" "$shmem" "$dirty" "$writeback" > "$meminfo"
                }

                run_reclaim() {
                  WSL_MEMORY_RECLAIM_MEMINFO_PATH=$meminfo \
                    WSL_MEMORY_RECLAIM_DROP_CACHES_PATH=$drop_caches \
                    WSL_MEMORY_RECLAIM_STATE_DIRECTORY=$state_directory \
                    WSL_MEMORY_RECLAIM_ELAPSED_SECONDS=$1 \
                    "$wsl_reclaim_command"
                }

                run_reclaim_from_uptime() {
                  WSL_MEMORY_RECLAIM_MEMINFO_PATH=$meminfo \
                    WSL_MEMORY_RECLAIM_UPTIME_PATH=$uptime \
                    WSL_MEMORY_RECLAIM_DROP_CACHES_PATH=$drop_caches \
                    WSL_MEMORY_RECLAIM_STATE_DIRECTORY=$state_directory \
                    "$wsl_reclaim_command"
                }

                expect_reclaim_failure() {
                  if run_reclaim "$1"; then
                    echo 'WSL memory reclaim accepted invalid runtime state' >&2
                    exit 1
                  fi
                }

                mkdir -p "$state_directory"
                printf '1789494733\n' > "$legacy_state"
                : > "$drop_caches"
                write_meminfo 41943040 16777216 12582912 0 0 0
                run_reclaim 1000
                test ! -s "$drop_caches"
                test ! -e "$state"
                printf 'invalid\n' > "$state"
                expect_reclaim_failure 1000
                test ! -s "$drop_caches"
                grep -Fxq invalid "$state"
                rm "$state"

                write_meminfo 41943040 8388608 4194304 0 0 0
                run_reclaim 1000
                test ! -s "$drop_caches"
                test ! -e "$state"

                write_meminfo 41943040 8388608 12582912 1048576 3145728 2097152
                run_reclaim 1000
                test ! -s "$drop_caches"
                test ! -e "$state"

                write_meminfo 41943040 8388608 12582912 1048576 0 0
                run_reclaim 1000
                grep -Fxq 1 "$drop_caches"
                grep -Fxq 1000 "$state"
                grep -Fxq 1789494733 "$legacy_state"

                : > "$drop_caches"
                run_reclaim 1050
                test ! -s "$drop_caches"
                grep -Fxq 1000 "$state"

                run_reclaim 1120
                grep -Fxq 1 "$drop_caches"
                grep -Fxq 1120 "$state"

                : > "$drop_caches"
                write_meminfo 41943040 8388608 12582912 1048576 0 0
                expect_reclaim_failure 1100
                test ! -s "$drop_caches"
                grep -Fxq 1120 "$state"

                printf '1240.75 0.00\n' > "$uptime"
                run_reclaim_from_uptime
                grep -Fxq 1 "$drop_caches"
                grep -Fxq 1240 "$state"
                test ! -e "$state.tmp"

                : > "$drop_caches"
                printf 'invalid\n' > "$state"
                expect_reclaim_failure 1300
                test ! -s "$drop_caches"
                grep -Fxq invalid "$state"
                printf '09\n' > "$state"
                expect_reclaim_failure 1300
                test ! -s "$drop_caches"
                grep -Fxq 09 "$state"

                printf '9223372036854775808\n' > "$state"
                expect_reclaim_failure 1300
                test ! -s "$drop_caches"
                grep -Fxq 9223372036854775808 "$state"
                printf '1240\n' > "$state"

                : > "$drop_caches"
                printf 'MemTotal: invalid kB\n' > "$meminfo"
                expect_reclaim_failure 1300
                test ! -s "$drop_caches"
                grep -Fxq 1240 "$state"

                write_meminfo 41943040 8388608 12582912 1048576 0 0
                chmod a-w "$drop_caches"
                expect_reclaim_failure 1300
                chmod u+w "$drop_caches"
                test ! -s "$drop_caches"
                grep -Fxq 1240 "$state"

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

                grep -Fxq 'ConditionVirtualization=!container' "$service"
                grep -Fxq 'ConditionVirtualization=' "$service_drop_in"
                grep -Fxq 'ConditionVirtualization=wsl' "$service_drop_in"
                grep -Eq '^ExecStart=.+/fstrim ' "$service"
                if grep -q '^ExecStart=' "$service_drop_in"; then
                  echo 'fstrim.service drop-in replaced the vendor ExecStart' >&2
                  exit 1
                fi

                grep -Fxq 'ConditionVirtualization=!container' "$timer"
                grep -Fxq 'ConditionVirtualization=' "$timer_drop_in"
                grep -Fxq 'ConditionVirtualization=wsl' "$timer_drop_in"
                grep -Fxq 'OnCalendar=weekly' "$timer"
                grep -Fxq 'Persistent=true' "$timer"
                grep -Fxq 'OnCalendar=' "$timer_drop_in"
                grep -Fxq 'OnCalendar=weekly' "$timer_drop_in"
                if grep -q '^Persistent=' "$timer_drop_in"; then
                  echo 'fstrim.timer drop-in replaced the vendor persistence setting' >&2
                  exit 1
                fi

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
                grep -Fxq 'SystemMaxUse=4G' ${journaldConfig}
                grep -Fxq 'MaxRetentionSec=30day' ${journaldConfig}

                grep -Fxq '[zram0]' ${zramConfig}
                grep -Fxq 'compression-algorithm=lzo-rle' ${zramConfig}
                grep -Fxq 'swap-priority=100' ${zramConfig}
                grep -Fxq 'zram-size=25 / 100 * ram' ${zramConfig}
                if grep -q '^writeback-device=' ${zramConfig}; then
                  echo 'zram writeback was enabled' >&2
                  exit 1
                fi

                touch $out
      '';
}
