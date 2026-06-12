{ config, pkgs, lib, ... }:

# MCP stack. agentgateway runs natively and aggregates every MCP server behind
# one loopback endpoint (my.gatewayUrl). Lightweight servers are spawned by the
# gateway over stdio; heavy services run as Docker containers on the
# "mcp-backends" network and are reached over loopback-published ports.

let
  cfg      = config.my;
  userHome = "/home/${cfg.username}";

  # Backing-service ports
  searxngMcpPort        = "3000";
  searxngPort           = "8080";
  valkeyPort            = "6379";
  crawl4aiPort          = "11235";
  playwrightPort        = "8931";
  agentmemoryUid        = "65532";
  agentmemoryHttpPort   = "3111";
  agentmemoryStreamPort = "3112";

  # stdio MCP servers (native, spawned by the gateway)
  context7Pkg    = pkgs.callPackage ../services/context7-mcp { };
  probeMcpPkg    = pkgs.callPackage ../services/probe-mcp { };
  githubBin      = pkgs.callPackage ../services/github-mcp { };
  agentmemoryMcp = pkgs.callPackage ../services/agentmemory-mcp {
    agentmemoryUrl = "http://127.0.0.1:${agentmemoryHttpPort}";
  };
  crawl4aiMcp    = pkgs.callPackage ../services/crawl4ai-mcp {
    crawl4aiUrl = "http://127.0.0.1:${crawl4aiPort}";
  };
  agentgateway   = pkgs.callPackage ../services/agentgateway { };
  agentmemoryImage = pkgs.callPackage ../services/agentmemory { };

  # github per-account wrapper: read the PAT from /run/secrets at spawn, then exec.
  githubWrapper = account: pkgs.writeShellScript "github-mcp-${account}" ''
    export GITHUB_PERSONAL_ACCESS_TOKEN="$(<${config.sops.secrets."accounts/${account}/token".path})"
    exec ${githubBin}/bin/github-mcp-server stdio
  '';

  # Gateway targets. Names match the previous gateway so tool prefixes are stable.
  stdioTarget = name: cmd: { inherit name; stdio.cmd = cmd; };
  httpTarget  = name: url: { inherit name; mcp.host = url; };
  githubTargets = map (a: stdioTarget "github-mcp-${a}" "${githubWrapper a}") cfg.accounts;

  targets =
    [
      (stdioTarget "context7"  "${context7Pkg}/bin/context7-mcp")
      (stdioTarget "probe-mcp" "${probeMcpPkg}/bin/probe-mcp")
      (stdioTarget "memory"    "${agentmemoryMcp}/bin/agentmemory-mcp")
      (stdioTarget "crawl4ai"  "${crawl4aiMcp}/bin/crawl4ai-mcp")
    ]
    ++ githubTargets
    ++ [
      (httpTarget "searxng-mcp" "http://127.0.0.1:${searxngMcpPort}/mcp")
      (httpTarget "playwright"  "http://127.0.0.1:${playwrightPort}/mcp")
    ];

  gatewayConfig = (pkgs.formats.yaml { }).generate "agentgateway-config.yaml" {
    binds = [{
      port = cfg.gatewayPort;
      listeners = [{
        routes = [{ backends = [{ mcp.targets = targets; }]; }];
      }];
    }];
  };

  # Backing Docker services
  restartCfg = {
    Restart    = lib.mkForce "always";
    RestartSec = "5s";
  };
  mkBackendService = extraDeps: {
    after    = [ "docker-mcp-backends-network.service" ] ++ extraDeps;
    requires = [ "docker-mcp-backends-network.service" ] ++ extraDeps;
    serviceConfig = restartCfg;
  };

  agentmemoryConfig = pkgs.replaceVars ../templates/agentmemory.yaml {
    httpPort   = agentmemoryHttpPort;
    streamPort = agentmemoryStreamPort;
  };
  searxngSettingsConfig = builtins.readFile (pkgs.replaceVars ../templates/searxng-settings.yml {
    searxngSecret = config.sops.placeholder."searxng/secret_key";
    inherit searxngPort valkeyPort;
  });

  backends = {
    valkey = {
      image = "valkey/valkey:latest@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      extraOptions = [ "--network=mcp-backends" "--memory=128m" ];
      deps = [ ];
    };
    searxng = {
      image = "searxng/searxng:2026.5.17-d7e8b7cd1@sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
      volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
      extraOptions = [ "--network=mcp-backends" "--memory=512m" ];
      deps = [ "docker-valkey.service" ];
    };
    searxng-mcp = {
      image = "isokoliuk/mcp-searxng:1.0.3@sha256:2d936f821eae1f4859b3534e1dd10d73f9c3687f366f1755538cf3217b2716f0";
      environment = {
        SEARXNG_URL   = "http://searxng:${searxngPort}";
        MCP_HTTP_PORT = searxngMcpPort;
      };
      extraOptions = [ "--network=mcp-backends" "-p" "127.0.0.1:${searxngMcpPort}:${searxngMcpPort}" ];
      deps = [ "docker-searxng.service" ];
    };
    crawl4ai = {
      image = "unclecode/crawl4ai:latest@sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
      extraOptions = [ "--network=mcp-backends" "--memory=2g" "--shm-size=1g" "-p" "127.0.0.1:${crawl4aiPort}:${crawl4aiPort}" ];
      deps = [ ];
    };
    agentmemory = {
      image     = "${agentmemoryImage.imageName}:${agentmemoryImage.imageTag}";
      imageFile = agentmemoryImage;
      volumes = [
        "${agentmemoryConfig}:/app/config.yaml:ro"
        "/var/lib/agentmemory/data:/data"
      ];
      extraOptions = [ "--network=mcp-backends" "--user=${agentmemoryUid}:${agentmemoryUid}" "-p" "127.0.0.1:${agentmemoryHttpPort}:${agentmemoryHttpPort}" ];
      deps = [ ];
    };
    playwright = {
      image = "mcr.microsoft.com/playwright/mcp:latest@sha256:d238ec7bc98cc4e22df0696d6031dad5b8a4b46781f4f0abaa3bfadeedb43b9a";
      entrypoint = "sh";
      cmd = [ "-c" ''
        CHROME=$(ls /ms-playwright/chromium-*/chrome-linux64/chrome | head -1)
        "$CHROME" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-port=9222 \
          --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36" \
          --user-data-dir=/tmp/chrome-data about:blank >/tmp/chrome.log 2>&1 &
        CPID=$!
        until node -e 'fetch("http://127.0.0.1:9222/json/version").then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))' 2>/dev/null; do
          kill -0 $CPID 2>/dev/null || exit 1
          sleep 0.2
        done
        exec node /app/cli.js --browser=chromium --no-sandbox \
          --cdp-endpoint http://127.0.0.1:9222 \
          --port=${playwrightPort} --host=0.0.0.0 --allowed-hosts '*'
      '' ];
      extraOptions = [ "--network=mcp-backends" "--init" "-p" "127.0.0.1:${playwrightPort}:${playwrightPort}" ];
      deps = [ ];
    };
  };
  backendContainers  = lib.mapAttrs  (_: v: builtins.removeAttrs v [ "deps" ]) backends;
  backendServices    = lib.mapAttrs' (n: v: lib.nameValuePair "docker-${n}" (mkBackendService v.deps)) backends;
  httpBackendUnits   = [ "docker-searxng-mcp.service" "docker-playwright.service" "docker-crawl4ai.service" "docker-agentmemory.service" ];

  networkService = {
    description = "Docker network for MCP backing services";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = map (n: "docker-${n}.service") (builtins.attrNames backends);
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.docker}/bin/docker network inspect mcp-backends >/dev/null 2>&1 \
        || ${pkgs.docker}/bin/docker network create mcp-backends
    '';
  };
in
{
  users.users.${cfg.username}.extraGroups = [ "docker" ];

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers = backendContainers;

  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = agentmemoryUid;
      group = agentmemoryUid;
      mode = "0755";
    };
  };

  # Native MCP gateway runs as the user so probe and friends can read the user's code.
  systemd.services = {
    agentgateway = {
      description = "agentgateway MCP aggregator";
      after    = [ "network.target" ] ++ httpBackendUnits;
      wants    = httpBackendUnits;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User        = cfg.username;
        Environment = [ "HOME=${userHome}" ];
        ExecStart   = "${agentgateway}/bin/agentgateway -f ${gatewayConfig}";
        Restart     = "always";
        RestartSec  = "5s";
      };
    };
    docker-mcp-backends-network = networkService;
  } // backendServices;

  # Mirror the generated config to /etc for inspection (doctor, debugging).
  environment.etc."agentgateway/config.yaml".source = gatewayConfig;

  sops.templates."searxng-settings.yml" = {
    path         = "/etc/searxng/settings.yml";
    mode         = "0400";
    owner        = "root";
    group        = "root";
    restartUnits = [ "docker-searxng.service" ];
    content      = searxngSettingsConfig;
  };
}
