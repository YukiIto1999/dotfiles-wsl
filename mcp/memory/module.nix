{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    agentmemoryUrl = config.dotfiles.containers.services.agentmemory.endpoints.http.url;
    version = config.dotfiles.containers.agentmemory.upstream.version;
  };
in
{
  dotfiles.mcp.targets.memory = {
    provider = "memory";
    port = 8774;
    serve = serveOverProxy (lib.getExe front);
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
