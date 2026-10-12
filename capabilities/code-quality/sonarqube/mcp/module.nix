{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "code-quality" config.dotfiles.capabilities.resolved;
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  backend = config.dotfiles.platform.containers.services.sonarqube;
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    sonarqubeUrl = backend.endpoints.http.url;
    tokenFile = config.dotfiles.capabilities.code-quality.sonarqube.credentials.tokenFile;
    storagePath = config.dotfiles.platform.mcp.fronts.sonarqube.runtimeDirectoryPath;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.sonarqube = {
      provider = "sonarqube";
      executable = lib.getExe front;
      serverLifecycle = "service";
      port = 8778;
      waitUnits = backend.units;
      probe = {
        tool = "get_system_status";
        args = { };
        timeout = 30;
      };
    };
    systemd.services.mcp-front-sonarqube.serviceConfig = {
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      ReadWritePaths = [ config.dotfiles.platform.mcp.fronts.sonarqube.runtimeDirectoryPath ];
      LimitCORE = 0;
    };
  };
}
