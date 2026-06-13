{ config, pkgs, lib, ... }:

let
  cfg = config.my;
  ep  = import ./endpoints.nix;
  ph  = config.sops.placeholder;
  render = import ../render.nix { inherit pkgs; };

  agentmemoryUid   = "65532";
  agentmemoryImage = pkgs.callPackage ../../pkgs/agentmemory { };

  restartCfg = {
    Restart    = lib.mkForce "always";
    RestartSec = "5s";
  };
  mkBackendService = extraDeps: {
    after    = [ "docker-mcp-backends-network.service" ] ++ extraDeps;
    requires = [ "docker-mcp-backends-network.service" ] ++ extraDeps;
    serviceConfig = restartCfg;
  };

  agentmemoryConfig = pkgs.replaceVars ../../templates/agentmemory.yaml {
    httpPort   = ep.ports.agentmemory;
    streamPort = ep.ports.agentmemoryStream;
  };
  searxngSettings = render ../../templates/searxng-settings.yml {
    searxngSecret = ph."searxng/secret_key";
    searxngPort   = ep.ports.searxng;
    valkeyPort    = ep.ports.valkey;
  };

  loopback = port: [ "-p" "127.0.0.1:${port}:${port}" ];

  # gatewayDep: gateway の stdio front が接続し起動を待つ backend
  backends = {
    valkey = {
      image = "valkey/valkey:latest@sha256:4963247afc4cd33c7d3b2d2816b9f7f8eeebab148d29056c2ca4d7cbc966f2d9";
      extraOptions = [ "--memory=128m" ];
      deps = [ ];
      gatewayDep = false;
    };
    searxng = {
      image = "searxng/searxng:2026.5.17-d7e8b7cd1@sha256:25ff3c045548971d12726e54bea4564b8ec3bedb3d6951aecdefd01caf840974";
      volumes = [ "/etc/searxng/settings.yml:/etc/searxng/settings.yml:ro" ];
      extraOptions = [ "--memory=512m" ] ++ loopback ep.ports.searxng;
      deps = [ "docker-valkey.service" ];
      gatewayDep = true;
    };
    crawl4ai = {
      image = "unclecode/crawl4ai:latest@sha256:a45fd08f8f15f67026c1bff0a151f0479244caf6751a0c6943b3870efafcd025";
      extraOptions = [ "--memory=2g" "--shm-size=1g" ] ++ loopback ep.ports.crawl4ai;
      deps = [ ];
      gatewayDep = true;
    };
    # app と iii engine を同梱する upstream image がない唯一の自前 build backend
    agentmemory = {
      image     = "${agentmemoryImage.imageName}:${agentmemoryImage.imageTag}";
      imageFile = agentmemoryImage;
      volumes = [
        "${agentmemoryConfig}:/app/config.yaml:ro"
        "/var/lib/agentmemory/data:/data"
      ];
      extraOptions = [ "--user=${agentmemoryUid}:${agentmemoryUid}" ] ++ loopback ep.ports.agentmemory;
      deps = [ ];
      gatewayDep = true;
    };
  };

  withNetwork = v: v // { extraOptions = [ "--network=mcp-backends" ] ++ (v.extraOptions or [ ]); };
  backendContainers = lib.mapAttrs (_: v: withNetwork (builtins.removeAttrs v [ "deps" "gatewayDep" ])) backends;
  backendServices   = lib.mapAttrs' (n: v: lib.nameValuePair "docker-${n}" (mkBackendService v.deps)) backends;

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
  my.gatewayBackendUnits =
    map (n: "docker-${n}.service") (builtins.attrNames (lib.filterAttrs (_: v: v.gatewayDep) backends));

  users.users.${cfg.username}.extraGroups = [ "docker" ];

  virtualisation = {
    docker.enable = true;
    oci-containers = {
      backend = "docker";
      containers = backendContainers;
    };
  };

  systemd.tmpfiles.settings."agentmemory" = {
    "/var/lib/agentmemory/data".d = {
      user = agentmemoryUid;
      group = agentmemoryUid;
      mode = "0755";
    };
  };

  systemd.services = { docker-mcp-backends-network = networkService; } // backendServices;

  sops.templates."searxng-settings.yml" = {
    path         = "/etc/searxng/settings.yml";
    mode         = "0400";
    owner        = "root";
    group        = "root";
    restartUnits = [ "docker-searxng.service" ];
    content      = searxngSettings;
  };
}
