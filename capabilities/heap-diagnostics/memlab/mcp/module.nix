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
      executable = lib.getExe front;
      serverLifecycle = "session";
      port = 8777;
      needsNetwork = false;
      probe = {
        tool = "memlab_server_status";
        args = { };
        timeout = 30;
      };
    };
  };
}
