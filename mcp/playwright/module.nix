{
  config,
  lib,
  pkgs,
  ...
}:

let
  # gateway は downstream client の Host を upstream へそのまま渡す。実測で
  # localhost:8765 で繋ぐと playwright だけ 403 になり tool が消えた
  authorityOf = url: lib.head (lib.splitString "/" (lib.removePrefix "http://" url));
  gatewayAuthority = authorityOf config.my.contract.gateway.endpoints.default.url;
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
      "${lib.getExe front} --host 127.0.0.1 --port ${toString port} --allowed-hosts 127.0.0.1:${toString port},${gatewayAuthority} --output-dir ${config.my.contract.mcp.fronts.playwright.runtimeDirectoryPath}";
  };
}
