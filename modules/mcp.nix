{ config, pkgs, lib, ... }:

# MCP stack: per-server Docker containers on the "mcp" network, aggregated by
# agentgateway into one loopback endpoint. Step A keeps the existing Docker
# design verbatim; the transport redesign happens in a later step.

let
  cfg      = config.my;
  userHome = "/home/${cfg.username}";
  gwPort   = toString cfg.gatewayPort;
  ph       = config.sops.placeholder;

  # Ports
  context7Port          = "3001";
  playwrightPort        = "8931";
  githubMcpPort         = "3002";
  searxngMcpPort        = "3000";
  searxngPort           = "8080";
  valkeyPort            = "6379";
  crawl4aiPort          = "11235";
  crawl4aiMcpPort       = "11236";
  probeMcpPort          = "3005";
  agentmemoryUid        = "65532";
  agentmemoryHttpPort   = "3111";
  agentmemoryStreamPort = "3112";
  agentmemoryMcpPort    = "3006";
  primaryAccount        = builtins.head cfg.accounts;

  # Images
  context7McpImage     = pkgs.callPackage ../services/context7-mcp    { };
  githubMcpImage       = pkgs.callPackage ../services/github-mcp      { };
  probeMcpImage        = pkgs.callPackage ../services/probe-mcp       { };
  crawl4aiMcpImage     = pkgs.callPackage ../services/crawl4ai-mcp    { };
  agentmemoryImage     = pkgs.callPackage ../services/agentmemory     { };
  agentmemoryMcpImage  = pkgs.callPackage ../services/agentmemory-mcp { };

  # Helpers
  # 26.05 oci-containers sets Restart=on-failure itself; force "always" to keep prior behaviour.
  restartCfg = {
    Restart    = lib.mkForce "always";
    RestartSec = "5s";
  };
  mkMcpService = extraDeps: {
    after    = [ "docker-mcp-network.service" ] ++ extraDeps;
    requires = [ "docker-mcp-network.service" ] ++ extraDeps;
    serviceConfig = restartCfg;
  };
  buildAccountTarget = name: builtins.readFile (pkgs.replaceVars ../templates/account-target.yaml {
    accountName = name;
    inherit githubMcpPort;
  });
  buildAccountContainer = name: lib.nameValuePair "github-mcp-${name}" {
    image            = "${githubMcpImage.imageName}:${githubMcpImage.imageTag}";
    imageFile        = githubMcpImage;
    environmentFiles = [ config.sops.templates."github-mcp-${name}.env".path ];
    extraOptions     = [ "--network=mcp" ];
  };
  buildAccountEnvTemplate = name: lib.nameValuePair "github-mcp-${name}.env" {
    mode         = "0400";
    owner        = "root";
    group        = "root";
    restartUnits = [ "docker-github-mcp-${name}.service" ];
    content      = "GITHUB_PERSONAL_ACCESS_TOKEN=${ph."accounts/${name}/token"}\n";
  };
  buildAccountService = name: lib.nameValuePair "docker-github-mcp-${name}" (mkMcpService [ ]);
  accountServices = map (a: "docker-github-mcp-${a}.service") cfg.accounts;
  allMcpServices = [
    "docker-mcp-network.service"
    "docker-agentmemory.service"
    "docker-agentmemory-mcp.service"
    "docker-context7.service"
    "docker-playwright.service"
    "docker-searxng-mcp.service"
    "docker-searxng.service"
    "docker-valkey.service"
    "docker-crawl4ai.service"
    "docker-crawl4ai-mcp.service"
    "docker-probe-mcp.service"
  ] ++ accountServices;

  # Generated config
  agentmemoryConfig = pkgs.replaceVars ../templates/agentmemory.yaml {
    httpPort   = agentmemoryHttpPort;
    streamPort = agentmemoryStreamPort;
  };
  agentgatewayConfig = builtins.readFile (pkgs.replaceVars ../etc/agentgateway/config.yaml {
    gatewayPort = gwPort;
    inherit context7Port playwrightPort searxngMcpPort crawl4aiMcpPort probeMcpPort agentmemoryMcpPort;
    accountTargets = lib.concatMapStrings buildAccountTarget cfg.accounts;
  });
  searxngSettingsConfig = builtins.readFile (pkgs.replaceVars ../templates/searxng-settings.yml {
    searxngSecret = ph."searxng/secret_key";
    inherit searxngPort valkeyPort;
  });

  # Containers
  mcp = {
    agentmemory = {
      image     = "${agentmemoryImage.imageName}:${agentmemoryImage.imageTag}";
      imageFile = agentmemoryImage;
      volumes = [
        "${agentmemoryConfig}:/app/config.yaml:ro"
        "/var/lib/agentmemory/data:/data"
      ];
      extraOptions = [ "--network=mcp" "--user=${agentmemoryUid}:${agentmemoryUid}" ];
      deps = [ ];
    };
    agentmemory-mcp = {
      image     = "${agentmemoryMcpImage.imageName}:${agentmemoryMcpImage.imageTag}";
      imageFile = agentmemoryMcpImage;
      environment.AGENTMEMORY_URL = "http://agentmemory:${agentmemoryHttpPort}";
      extraOptions = [ "--network=mcp" ];
      deps = [ "docker-agentmemory.service" ];
    };
    context7 = {
      image     = "${context7McpImage.imageName}:${context7McpImage.imageTag}";
      imageFile = context7McpImage;
      extraOptions = [ "--network=mcp" ];
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
        node /viewer/server.js >/tmp/viewer.log 2>&1 &
        exec node /app/cli.js --browser=chromium --no-sandbox \
          --cdp-endpoint http://127.0.0.1:9222 \
          --port=${playwrightPort} --host=0.0.0.0 --allowed-hosts '*'
      '' ];
      volumes = [ "${../etc/playwright/viewer}:/viewer:ro" ];
      extraOptions = [ "--network=mcp" "--init" "-p" "9224:9224" ];
      deps = [ ];
    };
    valkey = {
      image = "valkey/valkey:latest@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      extraOptions = [ "--network=mcp" "--memory=128m" ];
      deps = [ ];
    };
    searxng = {
      image = "searxng/searxng:2026.5.17-d7e8b7cd1@sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
      volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
      extraOptions = [ "--network=mcp" "--memory=512m" ];
      deps = [ "docker-valkey.service" ];
    };
    searxng-mcp = {
      image = "isokoliuk/mcp-searxng:1.0.3@sha256:2d936f821eae1f4859b3534e1dd10d73f9c3687f366f1755538cf3217b2716f0";
      environment = {
        SEARXNG_URL   = "http://searxng:${searxngPort}";
        MCP_HTTP_PORT = searxngMcpPort;
      };
      extraOptions = [ "--network=mcp" ];
      deps = [ "docker-searxng.service" ];
    };
    crawl4ai = {
      image = "unclecode/crawl4ai:latest@sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
      extraOptions = [ "--network=mcp" "--memory=2g" "--shm-size=1g" ];
      deps = [ ];
    };
    crawl4ai-mcp = {
      image     = "${crawl4aiMcpImage.imageName}:${crawl4aiMcpImage.imageTag}";
      imageFile = crawl4aiMcpImage;
      environment.CRAWL4AI_URL = "http://crawl4ai:${crawl4aiPort}";
      extraOptions = [ "--network=mcp" ];
      deps = [ "docker-crawl4ai.service" ];
    };
    probe-mcp = {
      image     = "${probeMcpImage.imageName}:${probeMcpImage.imageTag}";
      imageFile = probeMcpImage;
      volumes   = [
        "${userHome}/dotfiles-wsl:${userHome}/dotfiles-wsl:ro"
        "${userHome}/workspace:${userHome}/workspace:ro"
        "${userHome}/projects:${userHome}/projects:ro"
      ];
      workdir = userHome;
      extraOptions = [ "--network=mcp" ];
      deps = [ ];
    };
  };
  mcpContainers = lib.mapAttrs  (_: v: builtins.removeAttrs v [ "deps" ]) mcp;
  mcpServices   = lib.mapAttrs' (n: v: lib.nameValuePair "docker-${n}" (mkMcpService v.deps)) mcp;

  # Gateway
  gatewayContainer = {
    image = "cr.agentgateway.dev/agentgateway:v1.2.1@sha256:60f7d4fbb7cec7f31aae5c2834c2e94ee46d88381fbca0600596b9e38efce760";
    cmd = [ "-f" "/etc/agentgateway/config.yaml" ];
    volumes = [ "/etc/agentgateway/config.yaml:/etc/agentgateway/config.yaml:ro" ];
    extraOptions = [ "--network=mcp" "-p" "127.0.0.1:${gwPort}:${gwPort}" ];
  };
  gatewayService = {
    after    = allMcpServices;
    wants    = allMcpServices;
    requires = allMcpServices;
    serviceConfig = restartCfg;
  };
  networkService = {
    description = "Docker network for MCP containers";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = lib.tail allMcpServices;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.docker}/bin/docker network inspect mcp >/dev/null 2>&1 \
        || ${pkgs.docker}/bin/docker network create mcp
    '';
  };
in
{
  users.users.${cfg.username}.extraGroups = [ "docker" ];

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers =
    { agentgateway = gatewayContainer; }
    // mcpContainers
    // lib.listToAttrs (map buildAccountContainer cfg.accounts);

  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = agentmemoryUid;
      group = agentmemoryUid;
      mode = "0755";
    };
  };

  systemd.services =
    {
      docker-agentgateway = gatewayService;
      docker-mcp-network = networkService;
    }
    // mcpServices
    // lib.listToAttrs (map buildAccountService cfg.accounts);

  sops.templates = {
    "agentgateway-config.yaml" = {
      path         = "/etc/agentgateway/config.yaml";
      mode         = "0444";
      owner        = "root";
      group        = "root";
      restartUnits = [ "docker-agentgateway.service" ];
      content      = agentgatewayConfig;
    };
    "searxng-settings.yml" = {
      path         = "/etc/searxng/settings.yml";
      mode         = "0400";
      owner        = "root";
      group        = "root";
      restartUnits = [ "docker-searxng.service" ];
      content      = searxngSettingsConfig;
    };
  } // lib.listToAttrs (map buildAccountEnvTemplate cfg.accounts);
}
