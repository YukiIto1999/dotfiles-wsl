{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  config = hostConfig.my.artifacts."mcp/memory/config".source;
  template = hostConfig.sops.templates."agentmemory.env";
  templateFile = pkgs.writeText "agentmemory.env" template.content;
  apiKeyLine = "OPENAI_API_KEY=${hostConfig.sops.placeholder."opencode/go_api_key"}";
in
{
  # engine の待ち受け port は front の接続先と同じ宣言から出る
  agentmemory-config =
    assert lib.elem "${config}:/app/config.yaml:ro"
      hostConfig.virtualisation.oci-containers.containers.agentmemory.volumes;
    pkgs.runCommandLocal "check-agentmemory-config" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      test "$(yq -r '.workers[] | select(.name == "iii-http") | .config.port' ${config})" = ${hostConfig.my.contract.memory.ports.http}
      test "$(yq -r '.workers[] | select(.name == "iii-stream") | .config.port' ${config})" = ${hostConfig.my.contract.memory.ports.stream}
      touch $out
    '';

  # engine の LLM 設定は secret template 経由でしか実機に現れないので、生成結果を直接検査する
  agentmemory-env =
    assert
      hostConfig.virtualisation.oci-containers.containers.agentmemory.environmentFiles
      == [ template.path ];
    pkgs.runCommandLocal "check-agentmemory-env" { } ''
      set -eu

      printf '%s\n' \
        EMBEDDING_PROVIDER \
        OPENAI_API_KEY \
        OPENAI_BASE_URL \
        OPENAI_MODEL \
        | sort > expected-keys
      cut -d= -f1 ${templateFile} | sort > actual-keys
      diff -u expected-keys actual-keys

      grep -Fqx 'OPENAI_BASE_URL=https://opencode.ai/zen/go/v1' ${templateFile}
      grep -Fqx 'OPENAI_MODEL=minimax-m2.7' ${templateFile}
      grep -Fqx 'EMBEDDING_PROVIDER=none' ${templateFile}
      grep -Fqx ${lib.escapeShellArg apiKeyLine} ${templateFile}
      touch $out
    '';
}
