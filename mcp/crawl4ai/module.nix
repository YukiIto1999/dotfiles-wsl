{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  front = pkgs.callPackage ./package.nix {
    serverBuilder = mkMcpServer;
    crawl4aiUrl = config.dotfiles.containers.services.crawl4ai.endpoints.http.url;
    tokenFile = config.dotfiles.containers.crawl4ai.credentials.apiTokenFile;
  };
in
{
  dotfiles.mcp.targets.crawl4ai = {
    provider = "crawl4ai";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8773;
    waitUnits = config.dotfiles.containers.services.crawl4ai.units;
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
    "${config.dotfiles.mcp.fronts.crawl4ai.service}.service"
  ];
}
