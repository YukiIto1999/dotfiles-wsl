{
  config,
  lib,
  pkgs,
  serveOverProxy,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { };
in
{
  # native の HTTP transport は browser を開いた session を 120 秒の idle で
  # 破棄し、gateway は死んだ upstream session を持ち続けて回復しない。
  # stdio では heartbeat も session table も持たないので失敗の起点が無い
  my.mcp.targets.playwright = {
    port = 8776;
    # chromium が任意の web を開く
    needsNetwork = true;
    serve = serveOverProxy "${lib.getExe front} --output-dir ${config.my.contract.mcp.fronts.playwright.runtimeDirectoryPath}";
  };
}
