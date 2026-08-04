{
  helpers,
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf onlyValue;
  front = hostConfig.my.contract.mcp.fronts.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
  tokens = tokensOf service.ExecStart;

  gatewayPort = toString hostConfig.my.contract.gateway.endpoints.default.port;

  allowed = lib.concatStringsSep "," (
    [ "127.0.0.1:${toString front.port}" ]
    ++ map (host: "${host}:${gatewayPort}") [
      "127.0.0.1"
      "localhost"
    ]
  );
in
{
  playwright-front =
    # Host は完全一致比較で port を含む。gateway は downstream client の Host を
    # upstream へそのまま渡すので、契約の authority を許可対象に含める。
    # DNS rebinding で loopback へ誘導される経路はこれで塞ぐ
    assert onlyValue tokens "--allowed-hosts" allowed;
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert onlyValue tokens "--output-dir" front.runtimeDirectoryPath;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
