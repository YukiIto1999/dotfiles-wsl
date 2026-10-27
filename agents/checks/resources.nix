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
        limits = hostConfig.systemd.user.slices.agents.sliceConfig;
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
