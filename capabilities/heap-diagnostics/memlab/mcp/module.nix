{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "heap-diagnostics" config.dotfiles.capabilities.resolved;
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../../../../platform/mcp/package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.memlab = {
      provider = "memlab";
      exposure = "default";
      executable = lib.getExe front;
      serverLifecycle = "session";
      lazyDiscovery = true;
      port = 8777;
      needsNetwork = false;
    };
  };
}
