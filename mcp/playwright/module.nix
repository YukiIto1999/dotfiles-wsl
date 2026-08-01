{
  config,
  lib,
  pkgs,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { };
in
{
  # 常駐するので出力先は front 自身の runtime directory に閉じる
  my.mcp.targets.playwright = {
    port = 18106;
    serve =
      port:
      "${lib.getExe front} --host 127.0.0.1 --port ${toString port} --allowed-hosts 127.0.0.1:${toString port} --output-dir ${config.my.contract.mcp.fronts.playwright.runtimeDirectoryPath}";
  };
}
