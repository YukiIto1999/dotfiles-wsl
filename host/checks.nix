{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  zram = hostConfig.zramSwap;
  zramGenerator = hostConfig.services.zram-generator;
  journald = hostConfig.services.journald;
  fstrimService = hostConfig.systemd.services.fstrim or { };
  fstrimTimer = hostConfig.systemd.timers.fstrim;
  systemUnits = hostConfig.environment.etc."systemd/system".source;
  journaldConfig = hostConfig.environment.etc."systemd/journald.conf".source;
  zramConfig = hostConfig.environment.etc."systemd/zram-generator.conf".source;
in
{
  host-stability-contract =
    assert lib.assertMsg zram.enable "zram swap is disabled";
    assert lib.assertMsg (zram.swapDevices == 1) "zram must use one swap device";
    assert lib.assertMsg (zram.memoryPercent == 25) "zram size must be 25 percent of RAM";
    assert lib.assertMsg (zram.priority == 100) "zram must have priority 100";
    assert lib.assertMsg (zram.algorithm == "lzo-rle") "zram must use lzo-rle";
    assert lib.assertMsg (zram.writebackDevice == null) "zram writeback must remain disabled";
    assert lib.assertMsg zramGenerator.enable "zram-generator is disabled";
    assert lib.assertMsg (
      zramGenerator.settings.zram0 == {
        compression-algorithm = "lzo-rle";
        swap-priority = 100;
        zram-size = "25 / 100 * ram";
      }
    ) "zram-generator output does not match the swap contract";
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

        test -L "$service"
        test -L "$timer"
        test -f "$service_drop_in"
        test -f "$timer_drop_in"

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

        dependency_pattern='^(After|Before|Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|PropagatesReloadTo|ReloadPropagatedFrom|JoinsNamespaceOf)=.*(systemd-zram-setup@[^[:space:]]*\.service|(dev-)?zram[^[:space:]]*\.swap)'
        if find -L ${systemUnits} -type f \( -name '*.service' -o -name '*.conf' \) \
          -exec grep -HnE "$dependency_pattern" {} +; then
          echo 'a generated service depends on a zram swap or setup unit' >&2
          exit 1
        fi

        while IFS= read -r dependency_link; do
          dependency=$(basename "$dependency_link")
          target=$(readlink "$dependency_link")
          if printf '%s\n%s\n' "$dependency" "$target" \
            | grep -Eq 'systemd-zram-setup@.*\.service|(dev-)?zram.*\.swap'; then
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
