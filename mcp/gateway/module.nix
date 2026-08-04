{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;
  agentgateway = pkgs.callPackage ./package.nix { };

  # upstream schema の key を知るのはここだけ。option 名と service 名へ upstream 名を漏らさない
  upstream = front: { mcp.host = front.url; };

  # mcp-searxng は tool を絞る手段を持たない。web_url_read は SearXNG を経由せず
  # 引数の URL へ直接出るので、本文取得は crawl4ai の責務という skill の規範と
  # 食い違い、searxng front が network を必要とする唯一の理由にもなっている
  deniedTools = [ "web_url_read" ];

  # upstream の既定は admin=localhost:15000、stats と readiness は wildcard:15020/15021
  adminPort = 15000;
  statsPort = 15020;
  readinessPort = 15021;

  configOf =
    id:
    (pkgs.formats.yaml { }).generate "agentgateway-${id}-config.yaml" {
      # body 終了から数える idle session の reap 猶予、active stream は patch の guard が pin する
      config.mcp.sessionTtl = "30m";
      # 既定は stats と readiness が全 interface。admin は無認証で quitquitquit と
      # config_dump を持つので、三つとも loopback へ閉じる
      config.adminAddr = "127.0.0.1:${toString adminPort}";
      config.statsAddr = "127.0.0.1:${toString statsPort}";
      config.readinessAddr = "127.0.0.1:${toString readinessPort}";
      binds = [
        {
          inherit (cfg.gateway.endpoints.${id}) port;
          listeners = [
            {
              routes = [
                {
                  backends = [
                    {
                      # 既定の failClosed は front 1 つの停止で session 全体を落とす。
                      # 壊れた target だけを外し、検知は doctor の tool 一覧に任せる
                      mcp.failureMode = "failOpen";
                      mcp.targets = lib.mapAttrsToList (
                        name: front: { inherit name; } // upstream front
                      ) cfg.contract.mcp.fronts;
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

  # endpoint id から派生する名前は全てここで決まる。default にも例外を作らない
  endpoints = lib.mapAttrs (id: endpoint: {
    inherit id;
    inherit (endpoint) port;
    url = "http://127.0.0.1:${toString endpoint.port}/mcp";

    service = "agentgateway-${id}";
    runtimeDirectory = "agentgateway-${id}";
    artifact = "mcp/gateway/${id}/config";
    managementPorts = {
      admin = adminPort;
      stats = statsPort;
      readiness = readinessPort;
    };
    source = configOf id;
    targets = builtins.attrNames cfg.contract.mcp.fronts;
  }) cfg.gateway.endpoints;

  eachEndpoint = f: lib.listToAttrs (map f (builtins.attrValues endpoints));

  ports = map (endpoint: endpoint.port) (builtins.attrValues endpoints);
in
{
  options.my.gateway.endpoints = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.port = lib.mkOption {
          type = lib.types.port;
          description = "この endpoint の listener が loopback へ bind する port。";
        };
      }
    );
    description = "downstream が接続する gateway endpoint。target の集合を分けて session ごとの spawn 範囲を絞る。";
  };

  # front が常駐し gateway は spawn しないので、endpoint を分ける理由が無い
  config.my.gateway.endpoints.default.port = lib.mkDefault 8765;

  config.assertions = [
    {
      assertion = ports == lib.unique ports;
      message = "my.gateway.endpoints must bind one port each";
    }
  ];

  config.my.artifacts = eachEndpoint (endpoint: {
    name = endpoint.artifact;
    value = {
      format = "yaml";
      deployedAt = "/etc/${endpoint.runtimeDirectory}/config.yaml";
      inherit (endpoint) source;
    };
  });

  # CLI と doctor が読む契約。endpoint の名前と URL を導く規則をここだけが持つ
  config.my.contract.gateway.endpoints = endpoints;

  # probe 等の user コード読み取りに必要な user 権限
  config.systemd.services = eachEndpoint (endpoint: {
    name = endpoint.service;
    value = {
      description = "agentgateway MCP aggregator (${endpoint.id})";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = cfg.username;
        Environment = [ "HOME=${cfg.homeDir}" ];
        RuntimeDirectory = endpoint.runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        # downstream session ごとに upstream 接続を張るので、soft 既定 1024 では足りない
        LimitNOFILE = "4096:4096";
        # session を 30 分保持するので、front と同じく上限を置く
        MemoryMax = "2G";
        # upstream は listen address を config で受けず wildcard へ bind する。
        # NixOS-WSL は firewall を masked にするので Windows 側から到達しうる。
        # target は全て loopback なので、通信を loopback へ限る
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        ExecStart = "${agentgateway}/bin/agentgateway -f ${endpoint.source}";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  });

  config.environment.etc = eachEndpoint (endpoint: {
    name = "${endpoint.runtimeDirectory}/config.yaml";
    value.source = endpoint.source;
  });

}
