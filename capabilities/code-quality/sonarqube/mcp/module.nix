{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../../../../platform/mcp/package/mk-npm.nix { };
  backend = config.dotfiles.platform.containers.services.sonarqube;
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    sonarqubeUrl = backend.endpoints.http.url;
    username = "admin";
    passwordFile = config.dotfiles.capabilities.code-quality.sonarqube.credentials.adminPasswordFile;
  };
in
{
  dotfiles.platform.mcp.targets.sonarqube = {
    provider = "sonarqube";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8778;
    waitUnits = backend.units;
    probe = {
      tool = "system_status";
      args = { };
      timeout = 30;
    };
  };
}
