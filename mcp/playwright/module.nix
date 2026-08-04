{
  config,
  lib,
  pkgs,
  ...
}:

let
  # gateway は downstream client の Host を upstream へそのまま渡す。実測で
  # localhost:8765 で繋ぐと playwright だけ 403 になり tool が消えた。
  # loopback を指す名前は閉じた集合なので、安全形として両方を宣言する。
  # 稼働中の client は古い設定を持つため、綴りの統一だけでは足りない
  gatewayPort = toString config.my.contract.gateway.endpoints.default.port;
  loopbackNames = [
    "127.0.0.1"
    "localhost"
  ];
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
      "${lib.getExe front} --host 127.0.0.1 --port ${toString port} --allowed-hosts ${
        lib.concatStringsSep "," (
          [ "127.0.0.1:${toString port}" ] ++ map (host: "${host}:${gatewayPort}") loopbackNames
        )
      } --output-dir ${config.my.contract.mcp.fronts.playwright.runtimeDirectoryPath}";
  };
}
