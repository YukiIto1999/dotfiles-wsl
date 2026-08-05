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
    inherit mkMcpServer;
    crawl4aiUrl = config.dotfiles.containers.services.crawl4ai.endpoints.http.url;
    tokenFile = config.dotfiles.containers.crawl4ai.credentials.apiTokenFile;
  };
in
{
  dotfiles.mcp.targets.crawl4ai = {
    provider = "crawl4ai";
    port = 8773;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = config.dotfiles.containers.services.crawl4ai.units;
    probe = {
      tool = "md";
      args = {
        url = "http://127.0.0.1:11235/health";
        f = "raw";
      };
      timeout = 60;
    };
  };
}
