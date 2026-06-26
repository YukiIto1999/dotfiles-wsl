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

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-config.yaml" {
    binds = [
      {
        port = cfg.gatewayPort;
        listeners = [ { routes = [ { backends = [ { mcp.targets = targets; } ]; } ]; } ];
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
      Environment = [ "HOME=${cfg.homeDir}" ];
      ExecStart = "${agentgateway}/bin/agentgateway -f ${gatewayConfig}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # 生成 config の /etc への複製
  environment.etc."agentgateway/config.yaml".source = gatewayConfig;
}
