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
    # socket が loopback に閉じているので host check は二重防御にならない。
    # 完全一致比較なので port 付きの Host が来ると全 request を 403 にする
    assert lib.hasInfix "--allowed-hosts '*'" service.ExecStart;
    assert lib.hasInfix "--port ${toString front.port}" service.ExecStart;
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert lib.hasInfix "--output-dir ${front.runtimeDirectoryPath}" service.ExecStart;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
