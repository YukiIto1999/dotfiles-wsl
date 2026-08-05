{
  config,
  lib,
  pkgs,
  serveOverProxy,
  mkMcpServer,
  mkNpmMcp,
  ...
}:

let
  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    searxngUrl = config.dotfiles.containers.services.searxng.endpoints.http.url;
  };
in
{
  my.mcp.targets.searxng = {
    port = 8775;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = config.dotfiles.containers.services.searxng.units;
  };
}
