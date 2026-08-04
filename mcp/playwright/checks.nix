{
  helpers,
  pkgs,
  hostConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf onlyValue;
  front = hostConfig.my.contract.mcp.fronts.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
  tokens = tokensOf service.ExecStart;
in
{
  playwright-front =
    # Host は完全一致比較で port を含む。gateway が繋ぐ先と同じ形で許可する。
    # DNS rebinding で loopback へ誘導される経路はこれで塞ぐ
    # loopback を指す表記だけを許す。実機で gateway が送る Host は
    # 127.0.0.1:PORT と一致しなかった
    assert onlyValue tokens "--allowed-hosts" (
      "127.0.0.1:${toString front.port},127.0.0.1:${toString hostConfig.my.contract.gateway.endpoints.default.port},127.0.0.1,localhost"
    );
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert onlyValue tokens "--output-dir" front.runtimeDirectoryPath;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
