{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    searxngUrl = config.dotfiles.containers.services.searxng.endpoints.http.url;
  };
in
{
  dotfiles.mcp.targets.searxng = {
    provider = "searxng";
    port = 8775;
    serve = serveOverProxy (lib.getExe front);
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
