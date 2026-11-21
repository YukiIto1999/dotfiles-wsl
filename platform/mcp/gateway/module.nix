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
  defaultTargets = lib.filterAttrs (_: target: target.exposure == "default") mcp.targets;
  optionalTargets = lib.filterAttrs (_: target: target.exposure == "session") mcp.targets;
  baseUrl = "http://127.0.0.1:${toString gateway.port}";
  defaultPath = "/mcp";
  optionalPath = name: "${defaultPath}/${name}";
  protocolObserver = pkgs.callPackage ./impl/observer-package.nix {
    gatewayUrl = gateway.url;
    probes = lib.mapAttrs (_: target: target.probe) defaultTargets;
  };
  protocolContract = protocolObserver.dotfilesObservationContract;

  route = path: targets: {
    matches = [ { path.exact = path; } ];
    policies.timeout.backendRequestTimeout = "60s";
    backends = [
      {
        mcp.failureMode = if path == defaultPath then "failOpen" else "failClosed";
        mcp.targets = lib.mapAttrsToList (name: _: {
          inherit name;
          mcp.host = mcp.fronts.${name}.url;
        }) targets;
      }
    ];
  };

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-default-config.yaml" {
    config.mcp.sessionTtl = "${toString mcp.sessionPolicy.idleSeconds}s";
    config.adminAddr = "127.0.0.1:15000";
    config.statsAddr = "127.0.0.1:15020";
    config.readinessAddr = "127.0.0.1:15021";
    binds = [
      {
        inherit (gateway) port;
        address = "127.0.0.1";
        listeners = [
          {
            routes = [
              (route defaultPath defaultTargets)
            ]
            ++ lib.mapAttrsToList (
              name: target: route (optionalPath name) { ${name} = target; }
            ) optionalTargets;
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
      description = "AI CLI が接続する agentgateway の待ち受け port";
    };
    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "通常セッションへ配布する MCP endpoint URL";
    };
    optionalUrls = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "対象を選んだセッションにだけ追加する MCP endpoint";
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
    url = baseUrl + defaultPath;
    optionalUrls = lib.mapAttrs (name: _: baseUrl + optionalPath name) optionalTargets;
    service = "agentgateway-default";
    runtimeDirectory = "agentgateway-default";
    source = gatewayConfig;
    targets = builtins.attrNames mcp.targets;
  };

  config.assertions = [
    {
      assertion = defaultTargets != { };
      message = "The default MCP gateway route must have at least one target";
    }
    {
      assertion = lib.intersectLists gateway.targets (builtins.attrNames mcp.privateServers) == [ ];
      message = "Private MCP server IDs must not overlap gateway target IDs";
    }
  ];

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
      Slice = cfg.workstation.workload.slices.support;
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
      ExecStart = "${agentgateway}/bin/agentgateway -f ${gateway.source}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  config.environment.etc."${gateway.runtimeDirectory}/config.yaml".source = gateway.source;
}
