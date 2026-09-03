{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    crawl4aiUrl = config.dotfiles.platform.containers.services.crawl4ai.endpoints.http.url;
    tokenFile = config.dotfiles.capabilities.web-content.crawl4ai.credentials.apiTokenFile;
  };
in
{
  dotfiles.platform.mcp.targets.crawl4ai = {
    provider = "crawl4ai";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8773;
    waitUnits = config.dotfiles.platform.containers.services.crawl4ai.units;
    probe = {
      tool = "ask";
      args = {
        context_type = "doc";
        query = "health";
        max_results = 1;
      };
      timeout = 60;
    };
  };

  sops.secrets."crawl4ai/api_token".restartUnits = [
    "${config.dotfiles.platform.mcp.fronts.crawl4ai.service}.service"
  ];
}
