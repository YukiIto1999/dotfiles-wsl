{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled =
    builtins.elem "project-memory" config.dotfiles.capabilities.resolved
    && config.dotfiles.capabilities.registry."project-memory".implementation == "hindsight";
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    runtime = config.dotfiles.capabilities.project-memory.runtime;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.memory = {
      provider = "memory";
      executable = lib.getExe front;
      serverLifecycle = "service";
      port = 8774;
      waitUnits = config.dotfiles.platform.containers.services.hindsight.units;
      probe = {
        tool = "memory_health";
        args = { };
        timeout = 20;
      };
    };
  };
}
