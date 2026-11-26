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
    cgroupParent = config.dotfiles.workstation.workload.slices.support;
  };

  repository = "ghcr.io/vectorize-io/hindsight";
  version = "0.10.3";
  digest = "sha256:5b6ef2b892703f0e82c448786349c88db60f06d8c9190432b68af00ce6dc45e3";
  image = "${repository}:${version}@${digest}";
  httpPort = "3111";

  hindsight = pkgs.callPackage ./package.nix { };
  commandCodeKey = "commandcode/api_key";
  commandCodeEnrolled = builtins.elem commandCodeKey config.dotfiles.secrets.paths;

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
    sops.secrets.${commandCodeKey} = lib.mkIf commandCodeEnrolled { };

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
        HINDSIGHT_API_LLM_BASE_URL=https://opencode.ai/inference/go/anthropic
        HINDSIGHT_API_LLM_MODEL=minimax-m3
        # Goはx-opencode-sessionの無い要求を400で拒否する。抽出は会話を持たないので配備で一つの値にする。
        HINDSIGHT_API_LLM_DEFAULT_HEADERS={"User-Agent":"hindsight/${version} (dotfiles-project-memory)","x-opencode-session":"dotfiles-project-memory"}
        HINDSIGHT_API_RETAIN_LLM_PROVIDER=openai
        HINDSIGHT_API_RETAIN_LLM_MODEL=deepseek-v4.1-flash
        HINDSIGHT_API_RETAIN_LLM_BASE_URL=https://opencode.ai/inference/go/openai/v1
        HINDSIGHT_API_FAIL_ON_EXTRACTION_ERRORS=true
        HINDSIGHT_API_EMBEDDINGS_PROVIDER=local
        HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL=/opt/hindsight/models/embedding
        HINDSIGHT_API_EMBEDDINGS_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_RERANKER_PROVIDER=local
        HINDSIGHT_API_RERANKER_LOCAL_MODEL=/opt/hindsight/models/reranker
        HINDSIGHT_API_RERANKER_LOCAL_TRUST_REMOTE_CODE=false
        HINDSIGHT_API_ENABLE_BANK_CONFIG_API=true
        HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=Japanese
        HINDSIGHT_API_WORKER_ID=dotfiles-hindsight
        HINDSIGHT_ENABLE_CP=false
        HF_HUB_OFFLINE=1
        TRANSFORMERS_OFFLINE=1
      ''
      + lib.optionalString commandCodeEnrolled ''
        HINDSIGHT_API_RETAIN_LLM_STRATEGY={"mode":"failover"}
        HINDSIGHT_API_RETAIN_LLM_MAX_RETRIES=0
        HINDSIGHT_API_RETAIN_LLM_1_PROVIDER=openai
        HINDSIGHT_API_RETAIN_LLM_1_API_KEY=${config.sops.placeholder.${commandCodeKey}}
        HINDSIGHT_API_RETAIN_LLM_1_BASE_URL=https://api.commandcode.ai/provider/v1
        HINDSIGHT_API_RETAIN_LLM_1_MODEL=deepseek/deepseek-v4.1-flash
        HINDSIGHT_API_RETAIN_LLM_1_DEFAULT_HEADERS={"User-Agent":"hindsight/${version} (dotfiles-project-memory)"}
        HINDSIGHT_API_RETAIN_LLM_1_MAX_RETRIES=1
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
