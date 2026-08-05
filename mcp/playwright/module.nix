{
  config,
  lib,
  pkgs,
  ...
}:

let
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = pkgs.callPackage ./package.nix { inherit (config.dotfiles.mcp) chromium; };
in
{
  # native の HTTP transport は browser を開いた session を 120 秒の idle で
  # 破棄し、gateway は死んだ upstream session を持ち続けて回復しない。
  # stdio では heartbeat も session table も持たないので失敗の起点が無い
  dotfiles.mcp.targets.playwright = {
    provider = "playwright";
    port = 8776;
    # chromium が任意の web を開く
    needsNetwork = true;
    serve = serveOverProxy "${lib.getExe front} --output-dir ${config.dotfiles.mcp.fronts.playwright.runtimeDirectoryPath}";
    probe = {
      tool = "browser_tabs";
      args.action = "list";
      timeout = 30;
    };
  };
}
