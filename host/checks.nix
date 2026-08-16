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
  zram = hostConfig.zramSwap;
  zramGenerator = hostConfig.services.zram-generator;
  zramService = hostConfig.systemd.services.dotfiles-zram-swap or { };
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
  virtualMemorySysctl = builtins.intersectAttrs expectedVirtualMemorySysctl hostConfig.boot.kernel.sysctl;
  hostObservationKeys = [
    "host/fstrim"
    "host/home-manager"
    "host/home-manager-restart"
    "host/journald"
    "host/nix-daemon"
    "host/nix-gc"
    "host/root-filesystem"
    "host/swap"
    "host/system-generation"
    "host/windows-d-drive"
  ];
  hostObservations = lib.filterAttrs (
    name: _: lib.hasPrefix "host/" name
  ) hostConfig.dotfiles.observations;
  selectStabilityObservations =
    observations: builtins.intersectAttrs (lib.genAttrs hostObservationKeys (_: null)) observations;
  stabilityObservations = selectStabilityObservations hostObservations;
  observationProjection = lib.mapAttrs (
    _: observation: builtins.removeAttrs observation [ "command" ]
  ) stabilityObservations;
  expectedObservationProjection = {
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
    "host/home-manager" = {
      activeStates = [ "active" ];
      checkId = "home-manager";
      failureMessage = "home-manager-${hostConfig.dotfiles.host.username}.service is not operational";
      kind = "systemd-service";
      loadStates = [ "loaded" ];
      resourceKey = null;
      results = [ "success" ];
      timeoutSeconds = 10;
      unit = "home-manager-${hostConfig.dotfiles.host.username}.service";
    };
    "host/home-manager-restart" = {
      checkId = "restart/service/home-manager-${hostConfig.dotfiles.host.username}.service";
      failureAt = 20;
      failureMessage = "could not observe restart count for home-manager-${hostConfig.dotfiles.host.username}.service";
      kind = "restart-counter";
      resourceKey = null;
      sourceKind = "systemd-service";
      target = "home-manager-${hostConfig.dotfiles.host.username}.service";
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
      failureMessage = "swap must include lzo-rle zram above any disk swap with at least 8 GiB total";
      kind = "swap-policy";
      minimumTotalBytes = 8589934592;
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
    "host/windows-d-drive" = {
      checkId = "resource/windows-d-drive";
      failure = 10;
      failureMessage = "could not observe Windows D drive free space";
      kind = "numeric-command-threshold";
      metric = "free-percent";
      resourceKey = "windowsDDrive";
      timeoutSeconds = 10;
      warning = 15;
    };
  };
  hostObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/host/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  hostDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) hostObservationDefinitions
  );
  stabilityConfiguration = {
    inherit journald;
    fstrimInterval = hostConfig.services.fstrim.interval;
    homeManagerUnit = "home-manager-${hostConfig.dotfiles.host.username}.service";
    nixGc = hostConfig.nix.gc;
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
        dotfiles.observations."host/independent-observation" = {
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
  ) additionalObservationVariantConfig.dotfiles.observations;
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
          systemd.services."home-manager-${config.dotfiles.host.username}".description =
            lib.mkForce "A description must not select the Home Manager observation";
        }
      )
    ]).config;
  descriptionVariantStabilityObservations = selectStabilityObservations (
    lib.filterAttrs (name: _: lib.hasPrefix "host/" name) descriptionVariantConfig.dotfiles.observations
  );
  powershellProbe = ''$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'"; if ($null -eq $drive -or $drive.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor(($drive.FreeSpace * 100) / $drive.Size))'';
  mkWindowsDriveObservation = import ./package.nix;
  mkFakePowerShell =
    name: body:
    pkgs.writeShellScript name ''
      set -euo pipefail

      test "$#" -eq 5
      test "$1" = -NoLogo
      test "$2" = -NoProfile
      test "$3" = -NonInteractive
      test "$4" = -Command
      test "$5" = ${lib.escapeShellArg powershellProbe}
      ${body}
    '';
  successfulPowerShell = mkFakePowerShell "windows-drive-success" "printf '20\\r\\n'";
  noisyPowerShell = mkFakePowerShell "windows-drive-noisy" ''
    printf '20\r\nnoise\n'
    printf 'WINDOWS_DRIVE_NOISY_STDERR_POISON\n' >&2
  '';
  invalidPowerShell = mkFakePowerShell "windows-drive-invalid" "printf '101\\r\\n'";
  statusPowerShell = mkFakePowerShell "windows-drive-status" "printf '20\\r\\n'; exit 7";
  timeoutPowerShell = mkFakePowerShell "windows-drive-timeout" "sleep 3; printf '20\\r\\n'";
  mkProbe =
    powershellCommand:
    mkWindowsDriveObservation {
      inherit pkgs lib powershellCommand;
      drive = "D:";
      timeoutSeconds = 0.1;
    };
  successfulProbe = mkProbe successfulPowerShell;
  noisyProbe = mkProbe noisyPowerShell;
  invalidProbe = mkProbe invalidPowerShell;
  statusProbe = mkProbe statusPowerShell;
  timeoutProbe = mkProbe timeoutPowerShell;
in
{
  host-stability-contract =
    assert lib.assertMsg (
      builtins.attrNames stabilityObservations == hostObservationKeys
    ) "host runtime observation registry is incomplete";
    assert lib.assertMsg (
      observationProjection == expectedObservationProjection
    ) "host runtime observation shape or canonical value drifted";
    assert lib.assertMsg (
      hostObservations."host/windows-d-drive".command.dotfilesObservationCommandKind
      == "numeric-command-threshold"
      &&
        hostObservations."host/windows-d-drive".command.meta.mainProgram == "dotfiles-observe-windows-drive"
      &&
        lib.getExe hostObservations."host/windows-d-drive".command == "${
          lib.getBin hostObservations."host/windows-d-drive".command
        }/bin/dotfiles-observe-windows-drive"
    ) "Windows drive observation command is not a dedicated numeric threshold package";
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
        zram-size = "25 / 100 * ram";
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

        test -L "$service"
        test -L "$timer"
        test -f "$service_drop_in"
        test -f "$timer_drop_in"
        test -L "$zram_service"
        test -L "$zram_wants"

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
            ${pkgs.systemd}/bin/systemd-analyze --user verify --man=no --generators=no \
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
        test -x "$zram_setup"
        test -x "$zram_teardown"
        grep -Fq 'modprobe zram num_devices=1' "$zram_setup"
        grep -Fq 'zram-generator --setup-device zram0' "$zram_setup"
        grep -Fq 'swapon --priority 100 /dev/zram0' "$zram_setup"
        grep -Fq '/proc/swaps' "$zram_teardown"
        grep -Fq 'swapoff /dev/zram0' "$zram_teardown"
        grep -Fq '/sys/block/zram0' "$zram_teardown"
        grep -Fq 'zram-generator --reset-device zram0' "$zram_teardown"

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
