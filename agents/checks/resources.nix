{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:
      let
        slices = hostConfig.systemd.user.slices;
        limits = slices.agents.sliceConfig;
        classSlices = hostConfig.dotfiles.workstation.workload.classSlices;
        classConfig = class: slices.${lib.removeSuffix ".slice" classSlices.${class}}.sliceConfig;
        cappedBudget = hostConfig.dotfiles.workstation.workload.capped.cpuBudgetPercent;
        observed = {
          physicalBytes = 42059018240;
          residentBytes = 24101044224;
          swappedBytes = 13956947968;
        };
        highBytes = builtins.div (
          observed.physicalBytes * lib.toInt (lib.removeSuffix "%" limits.MemoryHigh)
        ) 100;
        swapBytes = builtins.div (
          observed.physicalBytes * lib.toInt (lib.removeSuffix "%" limits.MemorySwapMax)
        ) 100;
      in
      {
        agent-resource-contract =
          assert lib.assertMsg (highBytes >= observed.residentBytes) "WSL の継続中処理の実測常駐量を MemoryHigh が収容できません";
          # 検証の class の slice は CPU の配分だけを持ち、memory の上限は agent の slice のものだけを受ける。
          # deep は他の使わない CPU だけを使い、受入は session と同じ重みで分け合う
          assert lib.assertMsg (
            (classConfig "deep").CPUWeight == "idle"
          ) "deep の slice は CPUWeight=idle で CPU を譲る必要があります";
          assert lib.assertMsg (
            (classConfig "acceptance").CPUWeight >= 100
          ) "受入の slice の CPUWeight は session の既定の重み以上である必要があります";
          assert lib.assertMsg (
            ((classConfig "capped").CPUQuota or null)
            == (if cappedBudget == null then null else "${toString cappedBudget}%")
          ) "上限付きの slice の CPUQuota は入場の予算と一致する必要があります";
          assert lib.assertMsg (lib.all
            (class: !(lib.any (name: lib.hasPrefix "Memory" name) (builtins.attrNames (classConfig class))))
            (builtins.attrNames classSlices)
          ) "検証の class の slice は memory の上限を持たず agent の slice の上限だけを受ける必要があります";
          assert lib.assertMsg (
            swapBytes >= observed.swappedBytes
          ) "WSL の継続中処理の実測退避量を MemorySwapMax が収容できません";
          pkgs.runCommandLocal "check-agent-resource-contract" { } ''
            cat > "$out" <<'JSON'
            ${builtins.toJSON { inherit observed highBytes swapBytes; }}
            JSON
          '';
      }
    )
  ];
}
