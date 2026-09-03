{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../../../../platform/mcp/package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    searxngUrl = config.dotfiles.platform.containers.services.searxng.endpoints.http.url;
  };
in
{
  dotfiles.platform.mcp.targets.searxng = {
    provider = "searxng";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8775;
    waitUnits = config.dotfiles.platform.containers.services.searxng.units;
    probe = {
      tool = "searxng_web_search";
      args = {
        query = "dotfiles doctor probe";
        num_results = 1;
      };
      timeout = 30;
    };
  };
}
