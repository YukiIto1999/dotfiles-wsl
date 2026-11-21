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
    supervise = config.dotfiles.platform.supervise.package;
  };
in
{
  config = lib.mkIf enabled {
    # Playwright 本来の HTTP transport と公開 gateway の session 寿命不一致
    dotfiles.platform.mcp.targets.playwright = {
      provider = "playwright";
      exposure = "default";
      executable = lib.getExe front;
      serverLifecycle = "session";
      lazyDiscovery = true;
      port = 8776;
      needsNetwork = true;
    };
  };
}
