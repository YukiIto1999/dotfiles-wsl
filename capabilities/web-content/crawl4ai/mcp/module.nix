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
    # `ask` は Crawl4AI 自身の library index を返すだけで、browser を使う本文取得経路を
    # 通らない。fetch が壊れても pass するため、probe は `md` で実際に一枚取得する
    probe = {
      tool = "md";
      args = {
        url = "https://example.com";
        f = "fit";
      };
      timeout = 60;
    };
  };

  sops.secrets."crawl4ai/api_token".restartUnits = [
    "${config.dotfiles.platform.mcp.fronts.crawl4ai.service}.service"
  ];
}
