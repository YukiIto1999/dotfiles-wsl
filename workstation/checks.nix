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
  zram = hostConfig.zramSwap;
  zramGenerator = hostConfig.services.zram-generator;
  zramService = hostConfig.systemd.services.dotfiles-zram-swap or { };
  journald = hostConfig.services.journald;
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
    "min-free" = 34359738368;
    "max-free" = 68719476736;
  };
  virtualMemorySysctl = builtins.intersectAttrs expectedVirtualMemorySysctl hostConfig.boot.kernel.sysctl;
  hostObservationKeys = [
    "host/home-manager"
    "host/home-manager-restart"
    "host/journald"
    "host/nix-daemon"
    "host/nix-gc"
    "host/root-filesystem"
    "host/swap"
    "host/system-generation"
    "host/windows-drives"
    "host/windows-memory-commit"
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
    "host/wsl-vhd" = {
      allowedOutcomeIds = [
        "resource/wsl-vhd/capacity"
        "resource/wsl-vhd/wslconfig"
      ];
      checkId = "resource/wsl-vhd";
      envelopeVersion = 1;
      failureMessage = "could not observe the WSL root VHD";
      kind = "normalized-protocol";
      requiredOutcomeIds = [
        "resource/wsl-vhd/capacity"
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
  timerRemovalMutation = builtins.removeAttrs hostObservations [ "host/nix-gc" ];
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
  # WSL の drvfs は source を drive の root にする。drive の下の directory や他の 9p mount は drive ではない
  mkFakeDf =
    name: body:
    pkgs.writeShellScript name ''
      set -euo pipefail

      test "$*" = '-t 9p --block-size=1K --output=source,size,avail'
      ${body}
    '';
  mkDrivesProbe =
    name: body:
    mkWindowsDrivesObservation {
      inherit pkgs lib;
      dfCommand = mkFakeDf name body;
    };
  drivesProbe = mkDrivesProbe "df-drives" ''
    printf 'Filesystem      1K-blocks      Avail\n'
    printf 'drivers              1000        990\n'
    printf 'D:\\                  2000       1000\n'
    printf 'C:\\Users             1000          1\n'
    printf 'C:\\                  1000         99\n'
    printf 'C:\\                  1000         99\n'
  '';
  drivesFailedProbes = {
    df-status = mkDrivesProbe "df-status" "printf 'Filesystem 1K-blocks Avail\\nC:\\\\ 1000 99\\n'; exit 1";
    no-drive = mkDrivesProbe "df-no-drive" "printf 'Filesystem 1K-blocks Avail\\ndrivers 1000 990\\n'";
    zero-size = mkDrivesProbe "df-zero-size" "printf 'Filesystem 1K-blocks Avail\\nC:\\\\ 0 0\\n'";
    non-numeric = mkDrivesProbe "df-non-numeric" "printf 'Filesystem 1K-blocks Avail\\nC:\\\\ - -\\n'";
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
  mkWslVhdProbe =
    {
      blockDevices ? mkWslVhdBlockDevices "8:48" 1677721600,
      powershellCommand ? printWslconfig "wslconfig-declared" (
        "[wsl2]\r\ndefaultVhdSize=800GB\r\nmemory=40GB\r\n\r\n[general]\r\ninstanceIdleTimeout=-1\r\n\r\n"
        + "[experimental]\r\nautoMemoryReclaim=gradual\r\nsparseVhd=false\r\n"
      ),
    }:
    mkWslVhdObservation {
      inherit
        pkgs
        lib
        blockDevices
        powershellCommand
        ;
      sizeBytes = 800 * 1073741824;
      sparse = false;
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
      !(builtins.hasAttr "dotfiles-wsl-memory-reclaim" hostConfig.systemd.services)
      && !(builtins.hasAttr "dotfiles-wsl-memory-reclaim" hostConfig.systemd.timers)
    ) "WSL memory reclaim must not evict page cache during active sessions";
    assert lib.assertMsg (journald.storage == "persistent") "journald storage is not persistent";
    assert lib.assertMsg (lib.hasInfix "SystemMaxUse=4G" journald.extraConfig)
      "journald SystemMaxUse is not bounded at 4G";
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
                  local stdout="$TMPDIR/wsl-vhd-$name.stdout"

                  if ! "$command" >"$stdout" 2>"$TMPDIR/wsl-vhd-$name.stderr"; then
                    echo "WSL VHD $name probe did not produce an envelope" >&2
                    return 1
                  fi
                  if ! jq -e --arg capacity "$capacity" --arg wslconfig "$wslconfig" '
                    .schemaVersion == 1
                    and .resources == []
                    and (.outcomes | length) == 2
                    and (.outcomes | map({key: .id, value: .status}) | from_entries)
                      == {"resource/wsl-vhd/capacity": $capacity, "resource/wsl-vhd/wslconfig": $wslconfig}
                    and all(.outcomes[]; (.message | length) > 0)
                  ' "$stdout" >/dev/null; then
                    echo "WSL VHD $name probe did not report capacity $capacity and .wslconfig $wslconfig" >&2
                    cat "$stdout" >&2
                    return 1
                  fi
                }

                ${lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (
                    name: case: "assert_wsl_vhd ${name} ${lib.getExe case.probe} ${case.capacity} ${case.wslconfig}"
                  ) wslVhdCases
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
