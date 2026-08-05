{
  config,
  lib,
  pkgs,
  mkMcpServer,
  serveOverProxy,
  ...
}:

let
  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer;
    agentmemoryUrl = config.dotfiles.containers.services.agentmemory.endpoints.http.url;
    version = config.dotfiles.containers.agentmemory.version;
  };
in
{
  my.mcp.targets.memory = {
    port = 8774;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = config.dotfiles.containers.services.agentmemory.units;
  };
}
