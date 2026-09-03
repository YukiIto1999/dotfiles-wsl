{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    agentmemoryUrl = config.dotfiles.containers.services.agentmemory.endpoints.http.url;
    version = config.dotfiles.containers.agentmemory.upstream.version;
  };
in
{
  dotfiles.mcp.targets.memory = {
    provider = "memory";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8774;
    waitUnits = config.dotfiles.containers.services.agentmemory.units;
    probe = {
      tool = "memory_recall";
      args = {
        query = "dotfiles-doctor-probe-no-match";
        limit = 1;
        format = "compact";
      };
      timeout = 30;
    };
  };
}
