{ config, lib, pkgs, username, gatewayPort, gatewayUrl, accounts, workIdentity, ... }:

let
  # Constants
  userHome              = "/home/${username}";
  agentmemoryUid        = "65532";
  agentmemoryHttpPort   = "3111";
  agentmemoryStreamPort = "3112";
  context7Port          = "3001";
  playwrightPort        = "8931";
  githubMcpPort         = "3002";
  searxngMcpPort        = "3000";
  searxngPort           = "8080";
  valkeyPort            = "6379";
  crawl4aiPort          = "11235";
  probeMcpPort          = "3005";
  primaryAccount        = builtins.head accounts;

  # Images
  context7McpImage = pkgs.callPackage ../../services/context7-mcp { };
  githubMcpImage   = pkgs.callPackage ../../services/github-mcp   { };
  probeMcpImage    = pkgs.callPackage ../../services/probe-mcp    { };

  # Helpers
  userTpl = path: content: {
    inherit path content;
    mode  = "0600";
    owner = username;
    group = "users";
  };
  restartCfg = {
    Restart    = "always";
    RestartSec = "5s";
  };
  mkMcpService = extraDeps: {
    after    = [ "docker-mcp-network.service" ] ++ extraDeps;
    requires = [ "docker-mcp-network.service" ] ++ extraDeps;
    serviceConfig = restartCfg;
  };
  buildAccountTarget = name: builtins.readFile (pkgs.replaceVars ../../templates/account-target.yaml {
    accountName = name;
    inherit githubMcpPort;
  });
  buildGhUser = name: builtins.readFile (pkgs.replaceVars ../../templates/gh-user.yml {
    accountUsername = config.sops.placeholder."accounts/${name}/username";
    accountToken    = config.sops.placeholder."accounts/${name}/token";
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
    content      = "GITHUB_PERSONAL_ACCESS_TOKEN=${config.sops.placeholder."accounts/${name}/token"}\n";
  };
  buildAccountService = name: lib.nameValuePair "docker-github-mcp-${name}" (mkMcpService [ ]);
  accountServices = map (a: "docker-github-mcp-${a}.service") accounts;
  allMcpServices = [
    "docker-mcp-network.service"
    "docker-agentmemory.service"
    "docker-context7.service"
    "docker-playwright.service"
    "docker-searxng-mcp.service"
    "docker-searxng.service"
    "docker-valkey.service"
    "docker-crawl4ai.service"
    "docker-probe-mcp.service"
  ] ++ accountServices;

  # Templates
  agentmemoryConfig     = pkgs.replaceVars ../../templates/agentmemory.yaml {
    httpPort   = agentmemoryHttpPort;
    streamPort = agentmemoryStreamPort;
  };
  agentgatewayConfig    = builtins.readFile (pkgs.replaceVars ../agentgateway/config.yaml {
    inherit gatewayPort context7Port playwrightPort
            searxngMcpPort crawl4aiPort probeMcpPort;
    accountTargets = lib.concatMapStrings buildAccountTarget accounts;
  });
  searxngSettingsConfig = builtins.readFile (pkgs.replaceVars ../../templates/searxng-settings.yml {
    searxngSecret = config.sops.placeholder."searxng/secret_key";
    inherit searxngPort valkeyPort;
  });
  gitIdentityConfig     = builtins.readFile (pkgs.replaceVars ../../home/nixos/.config/git/identity.conf {
    userName  = config.sops.placeholder."identity/default/name";
    userEmail = config.sops.placeholder."identity/default/email";
  });
  gitWorkIdentityConfig = builtins.readFile (pkgs.replaceVars ../../home/nixos/.config/git/work-identity.conf {
    userName  = config.sops.placeholder."identity/work/name";
    userEmail = config.sops.placeholder."identity/work/email";
  });
  ghHostsConfig         = builtins.readFile (pkgs.replaceVars ../../home/nixos/.config/gh/hosts.yml {
    accountUsers    = lib.concatMapStrings buildGhUser accounts;
    primaryUsername = config.sops.placeholder."accounts/${primaryAccount}/username";
    primaryToken    = config.sops.placeholder."accounts/${primaryAccount}/token";
  });

  # MCP containers
  mcp = {
    agentmemory = {
      image = "iiidev/iii:0.11.2@sha256:15f8d4ed16c0bec350b98f4e18ed04498b1fc5ccc50585e087b736717300cf26";
      volumes = [
        "${agentmemoryConfig}:/app/config.yaml:ro"
        "/var/lib/agentmemory/data:/data"
      ];
      extraOptions = [ "--network=mcp" "--user=${agentmemoryUid}:${agentmemoryUid}" ];
      deps = [ ];
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
      volumes = [ "${../playwright/viewer}:/viewer:ro" ];
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
    extraOptions = [ "--network=mcp" "-p" "127.0.0.1:${gatewayPort}:${gatewayPort}" ];
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
  system.stateVersion = "25.11";


  # Nix
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [
      "https://cache.nixos.org"
      "https://devenv.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
    trusted-users = [ "root" username ];
  };

  # WSL
  wsl.enable = true;
  wsl.defaultUser = username;
  wsl.useWindowsDriver = true;
  wsl.wslConf = {
    boot.systemd = true;
    interop.appendWindowsPath = false;
  };
  environment.localBinInPath = true;
  programs.nix-ld.enable = true;

  # CLI
  environment.etc."claude-code/managed-settings.json".source =
    ../../home/nixos/.claude/managed-settings.json;
  environment.etc."codex/config.toml".source =
    pkgs.replaceVars ../../home/nixos/.codex/config-system.toml { inherit gatewayUrl; };

  # Secrets
  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets = {
    "identity/default/name"  = { };
    "identity/default/email" = { };
    "searxng/secret_key"     = { };
  } // lib.optionalAttrs (workIdentity != null) {
    "identity/work/name"  = { };
    "identity/work/email" = { };
  } // lib.listToAttrs (lib.concatMap (a: [
    { name = "accounts/${a}/username"; value = { }; }
    { name = "accounts/${a}/token";    value = { }; }
  ]) accounts);
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
    "git-identity" = userTpl "${userHome}/.config/git/identity.conf" gitIdentityConfig;
    "gh-hosts.yml" = userTpl "${userHome}/.config/gh/hosts.yml"      ghHostsConfig;
  } // lib.optionalAttrs (workIdentity != null) {
    "git-work-identity" = userTpl "${userHome}/.config/git/work-identity.conf" gitWorkIdentityConfig;
  } // lib.listToAttrs (map buildAccountEnvTemplate accounts);

  # Docker
  virtualisation.docker.enable = true;
  users.users.${username} = {
    isNormalUser = true;
    home = userHome;
    extraGroups = [ "wheel" "docker" ];
  };
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers =
    { agentgateway = gatewayContainer; }
    // mcpContainers
    // lib.listToAttrs (map buildAccountContainer accounts);

  # Memory
  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = agentmemoryUid;
      group = agentmemoryUid;
      mode = "0755";
    };
  };

  # Services
  systemd.services =
    {
      docker-agentgateway = gatewayService;
      docker-mcp-network = networkService;
      # crates.io rejects curl's default UA (403); give fetchurl an accepted one
      nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent=Nixpkgs";
    }
    // mcpServices
    // lib.listToAttrs (map buildAccountService accounts);

  # Packages
  environment.systemPackages = with pkgs; [

    # CLI
    wget
    curl
    vim

    # WSL
    wslu

    # Dev
    direnv
    nix-direnv
    devenv

    # Secrets
    sops
    age
  ];

  # Direnv
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  # Fonts
  fonts.enableDefaultPackages = true;
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
  ];
  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      serif     = [ "Noto Serif CJK JP" "Noto Serif" ];
      sansSerif = [ "Noto Sans CJK JP" "Noto Sans" ];
      monospace = [ "Noto Sans Mono CJK JP" "Noto Sans Mono" ];
      emoji     = [ "Noto Color Emoji" ];
    };
  };
}
