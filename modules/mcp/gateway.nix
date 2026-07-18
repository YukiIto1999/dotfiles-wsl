{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  agentgateway = pkgs.callPackage ../../pkgs/agentgateway { };

  targets = lib.mapAttrsToList (name: target: {
    inherit name;
    stdio.cmd = target.command;
  }) cfg.mcp.targets;

  # probe の grep は npm package と native binary の subcommand が食い違い、呼ぶと常に失敗する
  deniedTools = [ "grep" ];

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-config.yaml" {
    # idle session の reap 猶予
    config.mcp.sessionTtl = "4h";
    binds = [
      {
        port = cfg.gatewayPort;
        listeners = [
          {
            routes = [
              {
                backends = [ { mcp.targets = targets; } ];
                policies.mcpAuthorization.rules = map (name: {
                  deny = ''mcp.tool.name == "${name}"'';
                }) deniedTools;
              }
            ];
          }
        ];
      }
    ];
  };
in
{
  # probe 等の user コード読み取りに必要な user 権限
  systemd.services.agentgateway = {
    description = "agentgateway MCP aggregator";
    after = [ "network.target" ] ++ cfg.mcp.gatewayWaitUnits;
    wants = cfg.mcp.gatewayWaitUnits;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = cfg.username;
      Environment = [
        "HOME=${cfg.homeDir}"
        "PLAYWRIGHT_MCP_RUNTIME_DIR=/run/agentgateway"
      ];
      RuntimeDirectory = "agentgateway";
      RuntimeDirectoryMode = "0700";
      ExecStart = "${agentgateway}/bin/agentgateway -f ${gatewayConfig}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  environment.etc."agentgateway/config.yaml".source = gatewayConfig;

  my.doctor = {
    units = [ "agentgateway.service" ];
    managedFiles.agentgateway = {
      path = "/etc/agentgateway/config.yaml";
      source = gatewayConfig;
    };
  };
}
