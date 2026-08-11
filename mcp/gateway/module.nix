{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  mcp = config.dotfiles.mcp;
  inherit (mcp) gateway;
  agentgateway = pkgs.callPackage ./package.nix { };
  protocolObserver = pkgs.callPackage ./impl/observer-package.nix {
    gatewayUrl = gateway.url;
    probes = lib.mapAttrs (_: target: target.probe) mcp.targets;
  };
  protocolContract = protocolObserver.dotfilesObservationContract;

  upstream = front: { mcp.host = front.url; };
  deniedTools = [ "web_url_read" ];

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-default-config.yaml" {
    config.mcp.sessionTtl = "30m";
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
  options.dotfiles.mcp.gateway = {
    id = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "AI CLI が接続する単一 agentgateway endpoint の port。";
    };
    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    service = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
    };
    source = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
    };
    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
    };
  };

  config.dotfiles.mcp.gateway = {
    id = "default";
    url = "http://127.0.0.1:${toString gateway.port}/mcp";
    service = "agentgateway-default";
    runtimeDirectory = "agentgateway-default";
    source = gatewayConfig;
    targets = builtins.attrNames mcp.targets;
  };

  config.dotfiles.artifacts."mcp/gateway/default/config" = {
    format = "yaml";
    deployedAt = "/etc/${gateway.runtimeDirectory}/config.yaml";
    inherit (gateway) source;
  };

  config.dotfiles.observations."mcp/protocol/${gateway.id}" = {
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
      User = cfg.host.username;
      Environment = [ "HOME=${cfg.host.homeDir}" ];
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
