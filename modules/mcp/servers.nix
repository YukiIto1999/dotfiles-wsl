{ config, pkgs, ... }:

let
  cfg         = config.my;
  userHome    = cfg.homeDir;
  ep          = import ./endpoints.nix;
  mkMcpServer = pkgs.callPackage ../../pkgs/mk-mcp-server.nix { };

  agentgateway = pkgs.callPackage ../../pkgs/agentgateway { };

  # bot 判定を避ける Windows UA
  userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

  # target は skills が参照する安定した公開契約
  # bin は package の実行ファイル名
  github = account: {
    target = "github-mcp-${account}";
    bin    = "github-mcp";
    pkg    = pkgs.callPackage ../../pkgs/github-mcp {
      inherit mkMcpServer;
      tokenFile = config.sops.secrets."accounts/${account}/token".path;
    };
  };

  servers =
    [
      { target = "context7";    bin = "context7-mcp";    pkg = pkgs.callPackage ../../pkgs/context7-mcp    { inherit mkMcpServer; }; }
      { target = "probe-mcp";   bin = "probe-mcp";       pkg = pkgs.callPackage ../../pkgs/probe-mcp       { inherit mkMcpServer; }; }
      { target = "crawl4ai";    bin = "crawl4ai-mcp";    pkg = pkgs.callPackage ../../pkgs/crawl4ai-mcp    { inherit mkMcpServer; inherit (ep) crawl4aiUrl; }; }
      { target = "memory";      bin = "agentmemory-mcp"; pkg = pkgs.callPackage ../../pkgs/agentmemory-mcp { inherit mkMcpServer; inherit (ep) agentmemoryUrl; }; }
      { target = "searxng-mcp"; bin = "searxng-mcp";     pkg = pkgs.callPackage ../../pkgs/searxng-mcp     { inherit mkMcpServer; inherit (ep) searxngUrl; }; }
      { target = "playwright";  bin = "playwright-mcp";  pkg = pkgs.callPackage ../../pkgs/playwright-mcp  { inherit mkMcpServer userAgent; }; }
    ]
    ++ map github cfg.accounts;

  targets = map (s: { name = s.target; stdio.cmd = "${s.pkg}/bin/${s.bin}"; }) servers;

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-config.yaml" {
    binds = [{
      port = cfg.gatewayPort;
      listeners = [{ routes = [{ backends = [{ mcp.targets = targets; }]; }]; }];
    }];
  };
in
{
  # probe 等の user コード読み取りに必要な user 権限
  systemd.services.agentgateway = {
    description = "agentgateway MCP aggregator";
    after    = [ "network.target" ] ++ cfg.gatewayBackendUnits;
    wants    = cfg.gatewayBackendUnits;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User        = cfg.username;
      Environment = [ "HOME=${userHome}" ];
      ExecStart   = "${agentgateway}/bin/agentgateway -f ${gatewayConfig}";
      Restart     = "always";
      RestartSec  = "5s";
    };
  };

  # 生成 config の /etc への複製
  environment.etc."agentgateway/config.yaml".source = gatewayConfig;
}
