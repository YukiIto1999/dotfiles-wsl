{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  template = hostConfig.sops.templates."agentmemory.env";
  templateFile = pkgs.writeText "agentmemory.env" template.content;
  apiKeyLine = "OPENAI_API_KEY=${hostConfig.sops.placeholder."opencode/go_api_key"}";
in
{
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
