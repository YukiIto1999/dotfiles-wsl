{
  config,
  lib,
  pkgs,
  ...
}:

let
  projectMemoryEnabled = builtins.elem "project-memory" config.dotfiles.capabilities.resolved;
  enabled =
    projectMemoryEnabled
    && config.dotfiles.capabilities.registry."project-memory".implementation == "hindsight";
  mkContainerBackend = import ../../../../platform/containers/impl/container-backend.nix {
    inherit lib;
  };

  repository = "ghcr.io/vectorize-io/hindsight";
  version = "0.10.1";
  digest = "sha256:ba46d6f4ecadb93f71747428e39fd429df0e0adfc0c066b76a365c06b219db8b";
  image = "${repository}:${version}@${digest}";
  httpPort = "3111";

  hindsight = pkgs.callPackage ./package.nix { };

  backend = mkContainerBackend "hindsight" {
    inherit image;
    environmentFiles = [ config.sops.templates."hindsight.env".path ];
    volumes = [
      "hindsight-data:/home/hindsight/.pg0"
      "${hindsight.embeddingRoot}:/opt/hindsight/models/embedding:ro"
      "${hindsight.rerankerRoot}:/opt/hindsight/models/reranker:ro"
    ];
    extraOptions = [
      "--memory=4g"
      "--shm-size=1g"
      "--stop-timeout=45"
    ];
    ports = [ httpPort ];
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.containers.services.hindsight = {
      endpoints.http = {
        protocol = "http";
        address = "127.0.0.1";
        port = 3111;
        url = "http://127.0.0.1:3111";
      };
      units = [ "docker-hindsight.service" ];
      containerPolicy = {
        secretReaders."hindsight.env" = [ "hindsight" ];
        volumeOwners.hindsight = [ "hindsight-data" ];
      };
      images.hindsight = {
        kind = "upstream";
        container = "hindsight";
        inherit image repository digest;
      };
      health = {
        endpoint = "http";
        method = "GET";
        path = "/health/ready";
        timeout = 5;
      };
    };

    sops.secrets."opencode/go_api_key" = { };

    sops.templates."hindsight.env" = {
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "docker-hindsight.service" ];
      content = ''
        HINDSIGHT_API_HOST=0.0.0.0
        HINDSIGHT_API_PORT=3111
        HINDSIGHT_API_HEALTH_URL=http://localhost:3111/health/ready
        HINDSIGHT_API_DATABASE_URL=pg0
        # GoのMiniMaxはChat CompletionsではなくMessages APIを使う。
        HINDSIGHT_API_LLM_PROVIDER=anthropic
        HINDSIGHT_API_LLM_API_KEY=${config.sops.placeholder."opencode/go_api_key"}
        HINDSIGHT_API_LLM_BASE_URL=https://opencode.ai/zen/go
        HINDSIGHT_API_LLM_MODEL=minimax-m2.7
        HINDSIGHT_API_LLM_DEFAULT_HEADERS={"User-Agent":"hindsight/${version} (dotfiles-project-memory)"}
        HINDSIGHT_API_EMBEDDINGS_PROVIDER=local
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL=/opt/hindsight/models/embedding
        HINDSIGHT_API_EMBEDDINGS_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_RERANKER_PROVIDER=local
        HINDSIGHT_API_RERANKER_LOCAL_MODEL=/opt/hindsight/models/reranker
        HINDSIGHT_API_RERANKER_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_ENABLE_BANK_CONFIG_API=true
        HINDSIGHT_API_ENABLE_DOCUMENT_IMPORT_API=true
        HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=Japanese
        HINDSIGHT_API_WORKER_ID=dotfiles-hindsight
        HINDSIGHT_ENABLE_CP=false
        HF_HUB_OFFLINE=1
        TRANSFORMERS_OFFLINE=1
      '';
    };

    virtualisation.oci-containers.containers = backend.containers;
    systemd.services = backend.systemdServices // {
      "docker-hindsight" = backend.systemdServices."docker-hindsight" // {
        serviceConfig = backend.systemdServices."docker-hindsight".serviceConfig // {
          TimeoutStopSec = lib.mkForce "60s";
        };
      };
    };
  };
}
