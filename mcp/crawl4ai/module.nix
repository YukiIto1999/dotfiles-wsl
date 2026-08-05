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
    crawl4aiUrl = config.dotfiles.containers.services.crawl4ai.endpoints.http.url;
    tokenFile = config.dotfiles.containers.crawl4ai.credentials.apiTokenFile;
  };
in
{
  my.mcp.targets.crawl4ai = {
    port = 8773;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = config.dotfiles.containers.services.crawl4ai.units;
  };
}
