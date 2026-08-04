{
  config,
  lib,
  pkgs,
  ...
}:

let
  gatewayPort = config.my.contract.gateway.endpoints.default.port;
  front = pkgs.callPackage ./package.nix { };
in
{
  # 常駐するので出力先は front 自身の runtime directory に閉じる
  my.mcp.targets.playwright = {
    port = 8776;
    # chromium が任意の web を開く
    needsNetwork = true;
    serve =
      port:
      "${lib.getExe front} --host 127.0.0.1 --port ${toString port} --allowed-hosts 127.0.0.1:${toString port},127.0.0.1:${toString gatewayPort},127.0.0.1,localhost --output-dir ${config.my.contract.mcp.fronts.playwright.runtimeDirectoryPath}";
  };
}
