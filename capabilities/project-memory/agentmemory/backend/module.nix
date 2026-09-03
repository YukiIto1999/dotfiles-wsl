{
  config,
  lib,
  pkgs,
  ...
}:

let
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
  };
  uid = "65532";
  httpPort = "3111";
  # stream port は publish しない。engine config 内部専用で consumer はない
  streamPort = "3112";

  agentmemory = pkgs.callPackage ./package.nix { };

  agentmemoryConfig = pkgs.replaceVars ./assets/engine-config.yaml {
    inherit httpPort streamPort;
  };

  backend = mkContainerBackend "agentmemory" {
    image = "${agentmemory.image.imageName}:${agentmemory.image.imageTag}";
    imageFile = agentmemory.image;
    volumes = [
      "${agentmemoryConfig}:/app/config.yaml:ro"
      "/var/lib/agentmemory/data:/data"
    ];
    environmentFiles = [ config.sops.templates."agentmemory.env".path ];
    extraOptions = [
      "--user=${uid}:${uid}"
      "--memory=4g"
    ];
    ports = [ httpPort ];
  };
in
{
  options.dotfiles.capabilities.project-memory.agentmemory.upstream = {
    version = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
    };
    root = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
    };
  };

  config = {
    dotfiles.capabilities.project-memory.agentmemory.upstream = {
      inherit (agentmemory) version;
      root = agentmemory.upstreamRoot;
    };

    dotfiles.platform.containers.services.agentmemory = {
      endpoints.http = {
        protocol = "http";
        address = "127.0.0.1";
        port = 3111;
        url = "http://127.0.0.1:3111";
      };
      units = [ "docker-agentmemory.service" ];
      containerPolicy.secretReaders."agentmemory.env" = [ "agentmemory" ];
      images.agentmemory = {
        kind = "nix";
        container = "agentmemory";
        image = "${agentmemory.image.imageName}:${agentmemory.image.imageTag}";
        imageFile = agentmemory.image;
      };
      health = {
        endpoint = "http";
        method = "GET";
        path = "/agentmemory/livez";
        timeout = 5;
      };
    };

    dotfiles.managedArtifacts."containers/agentmemory/config" = {
      format = "yaml";
      source = agentmemoryConfig;
    };

    sops.secrets."opencode/go_api_key" = { };

    # LLM は OpenCode Go の OpenAI 互換 endpoint を使う
    sops.templates."agentmemory.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-agentmemory.service" ];
      content = ''
        OPENAI_API_KEY=${config.sops.placeholder."opencode/go_api_key"}
        OPENAI_BASE_URL=https://opencode.ai/zen/go/v1
        OPENAI_MODEL=minimax-m2.7
        EMBEDDING_PROVIDER=none
      '';
    };

    systemd.tmpfiles.settings."agentmemory" = {
      "/var/lib/agentmemory/data".d = {
        user = uid;
        group = uid;
        mode = "0750";
      };
    };

    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices;

  };
}
