{
  config,
  lib,
  pkgs,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit (config.dotfiles.mcp) chromium; };
in
{
  # Playwright 本来の HTTP transport と公開 gateway の session 寿命不一致
  dotfiles.mcp.targets.playwright = {
    provider = "playwright";
    executable = lib.getExe front;
    serverLifecycle = "session";
    port = 8776;
    needsNetwork = true;
    probe = {
      tool = "browser_tabs";
      args.action = "list";
      timeout = 30;
    };
  };
}
