{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  front = hostConfig.my.contract.mcp.fronts.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
in
{
  playwright-front =
    assert lib.hasInfix "--host 127.0.0.1" service.ExecStart;
    # Host は完全一致比較で port を含む。gateway が繋ぐ先と同じ形で許可する。
    # DNS rebinding で loopback へ誘導される経路はこれで塞ぐ
    assert lib.hasInfix "--allowed-hosts 127.0.0.1:${toString front.port}" service.ExecStart;
    assert lib.hasInfix "--port ${toString front.port}" service.ExecStart;
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert lib.hasInfix "--output-dir ${front.runtimeDirectoryPath}" service.ExecStart;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
