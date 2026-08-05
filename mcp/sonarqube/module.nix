{
  config,
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  serveOverProxy,
  ...
}:

let
  backend = config.dotfiles.containers.services.sonarqube;
  front = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    sonarqubeUrl = backend.endpoints.http.url;
    username = "admin";
    passwordFile = config.dotfiles.containers.sonarqube.credentials.adminPasswordFile;
  };
in
{
  my.mcp.targets.sonarqube = {
    port = 8778;
    serve = serveOverProxy (lib.getExe front);
    waitUnits = backend.units;
  };
}
