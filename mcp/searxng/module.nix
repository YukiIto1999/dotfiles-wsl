{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    searxngUrl = config.dotfiles.containers.services.searxng.endpoints.http.url;
  };
in
{
  dotfiles.mcp.targets.searxng = {
    provider = "searxng";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8775;
    waitUnits = config.dotfiles.containers.services.searxng.units;
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
