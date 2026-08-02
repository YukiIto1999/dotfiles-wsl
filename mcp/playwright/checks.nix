{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  inherit (import "${self}/mcp/impl/exec-tokens.nix" { inherit lib; }) tokensOf onlyValue;
  front = hostConfig.my.contract.mcp.fronts.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
  tokens = tokensOf service.ExecStart;
in
{
  playwright-front =
    # Host は完全一致比較で port を含む。gateway が繋ぐ先と同じ形で許可する。
    # DNS rebinding で loopback へ誘導される経路はこれで塞ぐ
    assert onlyValue tokens "--allowed-hosts" "127.0.0.1:${toString front.port}";
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert onlyValue tokens "--output-dir" front.runtimeDirectoryPath;
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { } "touch $out";
}
