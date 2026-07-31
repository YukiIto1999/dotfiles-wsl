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
    # body 終了から数える idle session の reap 猶予、active stream は patch の guard が pin する
    config.mcp.sessionTtl = "30m";
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
  my.configArtifacts."mcp/agentgateway/config" = {
    format = "yaml";
    source = gatewayConfig;
  };

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
      # soft 既定 1024 の暫定封じ込め、session 解放の代替にはしない
      LimitNOFILE = "4096:4096";
      ExecStart = "${agentgateway}/bin/agentgateway -f ${gatewayConfig}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  environment.etc."agentgateway/config.yaml".source = gatewayConfig;

  my.doctor = {
    units."agentgateway.service".expected = {
      LoadState = "loaded";
      ActiveState = "active";
      SubState = "running";
      Result = "success";
    };
    managedFiles.agentgateway = {
      path = "/etc/agentgateway/config.yaml";
      source = gatewayConfig;
    };
  };
}
