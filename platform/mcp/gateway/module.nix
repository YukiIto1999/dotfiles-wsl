{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  mcp = config.dotfiles.platform.mcp;
  inherit (mcp) gateway;
  agentgateway = pkgs.callPackage ../package/agentgateway.nix { };
  protocolObserver = pkgs.callPackage ./impl/observer-package.nix {
    gatewayUrl = gateway.url;
    probes = lib.mapAttrs (_: target: target.probe) mcp.targets;
  };
  protocolContract = protocolObserver.dotfilesObservationContract;

  upstream = front: { mcp.host = front.url; };
  deniedTools = [ "web_url_read" ];

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-default-config.yaml" {
    config.mcp.sessionTtl = "${toString mcp.sessionPolicy.idleSeconds}s";
    config.adminAddr = "127.0.0.1:15000";
    config.statsAddr = "127.0.0.1:15020";
    config.readinessAddr = "127.0.0.1:15021";
    binds = [
      {
        inherit (gateway) port;
        listeners = [
          {
            routes = [
              {
                backends = [
                  {
                    mcp.failureMode = "failOpen";
                    mcp.targets = lib.mapAttrsToList (name: front: { inherit name; } // upstream front) mcp.fronts;
                  }
                ];
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
  options.dotfiles.platform.mcp.gateway = {
    id = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "観測資源と gateway 設定を対応付ける固定識別子";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "AI CLI が接続する単一 agentgateway endpoint の待ち受け port";
    };
    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "AI CLI に配布する公開 MCP endpoint URL";
    };
    service = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "公開 gateway の process と再起動を所有する systemd service 名";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "systemd が所有する公開 gateway の実行時 directory 名";
    };
    source = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "公開 gateway が起動時に読み込む生成済み YAML 設定";
    };
    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "公開 gateway に束ねた MCP target 名の確定一覧";
    };
  };

  config.dotfiles.platform.mcp.gateway = {
    id = "default";
    url = "http://127.0.0.1:${toString gateway.port}/mcp";
    service = "agentgateway-default";
    runtimeDirectory = "agentgateway-default";
    source = gatewayConfig;
    targets = builtins.attrNames mcp.targets;
  };

  config.dotfiles.managedArtifacts."mcp/gateway/default/config" = {
    format = "yaml";
    deployedAt = "/etc/${gateway.runtimeDirectory}/config.yaml";
    inherit (gateway) source;
  };

  config.dotfiles.health.observations."mcp/protocol/${gateway.id}" = {
    kind = "normalized-protocol";
    checkId = "mcp-session";
    resourceKey = null;
    timeoutSeconds = protocolContract.outerTimeout;
    failureMessage = "MCP gateway protocol is not operational";
    command = protocolObserver;
    inherit (protocolContract)
      allowedOutcomeIds
      requiredOutcomeIds
      requiredResourceKeys
      envelopeVersion
      ;
  };

  config.systemd.services.${gateway.service} = {
    description = "agentgateway MCP aggregator (${gateway.id})";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = cfg.workstation.username;
      Environment = [ "HOME=${cfg.workstation.homeDir}" ];
      RuntimeDirectory = gateway.runtimeDirectory;
      RuntimeDirectoryMode = "0700";
      LimitNOFILE = "4096:4096";
      MemoryMax = "2G";
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      ExecStart = "${agentgateway}/bin/agentgateway -f ${gateway.source}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  config.environment.etc."${gateway.runtimeDirectory}/config.yaml".source = gateway.source;
}
