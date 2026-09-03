{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  backend = config.dotfiles.containers.services.sonarqube;
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
    sonarqubeUrl = backend.endpoints.http.url;
    username = "admin";
    passwordFile = config.dotfiles.containers.sonarqube.credentials.adminPasswordFile;
  };
in
{
  dotfiles.mcp.targets.sonarqube = {
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
