{
  pkgs,
  lib,
  hostConfig,
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
in
{
  host-stability-contract =
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
