{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedVersion = "0.9.26";
  expectedImage = "agentmemory:${expectedVersion}";
  expectedPersistentMount = "/var/lib/agentmemory/data:/data";
  expectedEnvironmentFile = "/run/secrets/rendered/agentmemory.env";
  expectedHealthPath = "/agentmemory/livez";

  service = hostConfig.dotfiles.containers.services.agentmemory;
  image = service.images.agentmemory;
  container = hostConfig.virtualisation.oci-containers.containers.agentmemory;
  engineConfig = hostConfig.dotfiles.artifacts."containers/agentmemory/config".source;
  environmentTemplate = hostConfig.sops.templates."agentmemory.env";
  environmentFile = pkgs.writeText "agentmemory.env" environmentTemplate.content;
  expectedApiKeyLine = "OPENAI_API_KEY=${hostConfig.sops.placeholder."opencode/go_api_key"}";
  environmentFiles = container.environmentFiles or [ ];
  volumes = container.volumes or [ ];
  upstreamRoot = toString hostConfig.dotfiles.containers.agentmemory.upstream.root;
  configMount = "${engineConfig}:/app/config.yaml:ro";
  dataDirectory = hostConfig.systemd.tmpfiles.settings.agentmemory."/var/lib/agentmemory/data".d;
in
{
  agentmemory-container =
    assert hostConfig.dotfiles.containers.agentmemory.upstream.version == expectedVersion;
    assert lib.hasSuffix "/node_modules/@agentmemory/agentmemory" upstreamRoot;
    assert image.image == expectedImage;
    assert image.imageFile.imageTag == expectedVersion;
    assert container.image == expectedImage;
    assert lib.count (volume: volume == expectedPersistentMount) volumes == 1;
    assert builtins.length (builtins.filter (lib.hasPrefix "/var/lib/agentmemory/data:") volumes) == 1;
    assert lib.count (volume: volume == configMount) volumes == 1;
    assert builtins.length (builtins.filter (lib.hasSuffix ":/app/config.yaml:ro") volumes) == 1;
    assert lib.count (option: option == "--user=65532:65532") container.extraOptions == 1;
    assert builtins.length (builtins.filter (lib.hasPrefix "--user=") container.extraOptions) == 1;
    assert environmentFiles == [ expectedEnvironmentFile ];
    assert environmentTemplate.restartUnits == [ "docker-agentmemory.service" ];
    assert environmentTemplate.mode == "0400";
    assert environmentTemplate.owner == "root";
    assert environmentTemplate.group == "root";
    assert
      service.health == {
        endpoint = "http";
        method = "GET";
        path = expectedHealthPath;
        timeout = 5;
      };
    assert dataDirectory.user == "65532";
    assert dataDirectory.group == "65532";
    assert dataDirectory.mode == "0750";
    pkgs.runCommandLocal "check-agentmemory-container"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.yq-go
        ];
      }
      ''
        set -euo pipefail

        test "$(yq -r '.workers[] | select(.name == "iii-http") | .config.port' ${engineConfig})" = 3111
        test "$(yq -r '.workers[] | select(.name == "iii-stream") | .config.port' ${engineConfig})" = 3112

        printf '%s\n' \
          EMBEDDING_PROVIDER \
          OPENAI_API_KEY \
          OPENAI_BASE_URL \
          OPENAI_MODEL \
          | sort > expected-keys
        cut -d= -f1 ${environmentFile} | sort > actual-keys
        diff -u expected-keys actual-keys
        grep -Fqx 'OPENAI_BASE_URL=https://opencode.ai/zen/go/v1' ${environmentFile}
        grep -Fqx 'OPENAI_MODEL=minimax-m2.7' ${environmentFile}
        grep -Fqx 'EMBEDDING_PROVIDER=none' ${environmentFile}
        grep -Fqx ${lib.escapeShellArg expectedApiKeyLine} ${environmentFile}
        jq -e --arg version '${expectedVersion}' '.version == $version' \
          ${lib.escapeShellArg upstreamRoot}/package.json >/dev/null

        touch $out
      '';
}
