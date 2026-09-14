{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "browser-automation" config.dotfiles.capabilities.resolved;
  front = pkgs.callPackage ./package.nix {
    chromium = config.dotfiles.capabilities.browser-runtime.package;
  };
in
{
  config = lib.mkIf enabled {
    # Playwright 本来の HTTP transport と公開 gateway の session 寿命不一致
    dotfiles.platform.mcp.targets.playwright = {
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
  };
}
