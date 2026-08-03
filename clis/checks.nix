{
  pkgs,
  lib,
  hostConfig,
  variantConfig,
  ...
}:

let
  artifactSource = id: hostConfig.my.artifacts.${id}.source;
  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
  gatewayUrl = hostConfig.my.contract.gateway.endpoints.default.url;
  codexProjectHomePath = "${lib.removePrefix "${hostConfig.my.homeDir}/" hostConfig.my.dotfilesDir}/.codex/config.toml";
  managedSettings = hostConfig.environment.etc."claude-code/managed-settings.json".source;
  roster = hostConfig.my.toolchain.lsp;
in
{
  # 生成した artifact がそのまま実配備先へ渡り、どの CLI も同じ gateway を指す
  cli-artifact-contract =
    assert
      hostConfig.environment.etc."claude-code/managed-settings.json".source
      == artifactSource "clis/claude/managed-settings";
    assert
      hostConfig.environment.etc."claude-code/managed-mcp.json".source
      == artifactSource "clis/claude/managed-mcp";
    assert hostConfig.environment.etc."codex/config.toml".source == artifactSource "clis/codex/system";
    assert homeConfig.home.file.${codexProjectHomePath}.source == artifactSource "clis/codex/project";
    assert
      homeConfig.home.file.".config/opencode/opencode.json".source
      == artifactSource "clis/opencode/config";
    assert
      homeConfig.home.file.".gemini/antigravity-cli/mcp_config.json".source
      == artifactSource "clis/antigravity/mcp";
    pkgs.runCommandLocal "check-cli-artifact-contract"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.taplo
        ];
      }
      ''
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl}           '.mcpServers.gateway.url == $expected'           ${artifactSource "clis/claude/managed-mcp"} > /dev/null
        jq --exit-status --arg expected 'http://localhost:9876/mcp'           '.mcpServers.gateway.url == $expected'           ${
          variantConfig.my.artifacts."clis/claude/managed-mcp".source
        } > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl}           '.mcpServers.gateway.serverUrl == $expected'           ${artifactSource "clis/antigravity/mcp"} > /dev/null
        jq --exit-status --arg expected ${lib.escapeShellArg gatewayUrl}           '.mcp.gateway.url == $expected'           ${artifactSource "clis/opencode/config"} > /dev/null
        test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/system"} mcp_servers.gateway.url | jq -r .)" = ${lib.escapeShellArg gatewayUrl}
        test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/user-seed"} model | jq -r .)" = gpt-5.6-sol
        touch $out
      '';

  # roster と各 CLI の登録が食い違うと、片方の CLI だけ server を持つ状態になる
  lsp-registration =
    pkgs.runCommandLocal "check-lsp-registration"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.coreutils
        ];
      }
      ''
        set -euo pipefail

        jq --sort-keys 'keys' ${artifactSource "clis/claude/lsp"} > claude-names.json
        jq --sort-keys '.lsp | keys' ${artifactSource "clis/opencode/config"} > opencode-names.json
        printf '%s' ${lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster))} \
          | jq --sort-keys '.' > expected-names.json
        diff --unified expected-names.json claude-names.json
        diff --unified expected-names.json opencode-names.json

        ${lib.concatMapStrings (name: ''
          jq --exit-status \
            --arg command ${lib.escapeShellArg roster.${name}.command} \
            --argjson args ${lib.escapeShellArg (builtins.toJSON roster.${name}.args)} \
            --argjson extensions ${lib.escapeShellArg (builtins.toJSON roster.${name}.extensions)} \
            --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
            .["${name}"].command == $command and
            (.["${name}"].args // []) == $args and
            .["${name}"].extensionToLanguage == $extensions and
            (.["${name}"].initializationOptions // {}) == $options
          ' ${artifactSource "clis/claude/lsp"} > /dev/null

          jq --exit-status \
            --argjson command ${
              lib.escapeShellArg (builtins.toJSON ([ roster.${name}.command ] ++ roster.${name}.args))
            } \
            --argjson extensions ${
              lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster.${name}.extensions))
            } \
            --argjson options ${lib.escapeShellArg (builtins.toJSON roster.${name}.initializationOptions)} '
            .lsp["${name}"].command == $command and
            (.lsp["${name}"].extensions | sort) == ($extensions | sort) and
            (.lsp["${name}"].initialization // {}) == $options
          ' ${artifactSource "clis/opencode/config"} > /dev/null
        '') (builtins.attrNames roster)}

        # 同じ拡張子を二つの server が宣言すると、先に登録された片方だけが動く
        jq -r '.[].extensionToLanguage | keys[]' ${artifactSource "clis/claude/lsp"} | sort > extensions
        if [ "$(sort -u extensions | wc -l)" != "$(wc -l < extensions)" ]; then
          echo "one file extension is claimed by more than one language server:" >&2
          uniq -d extensions >&2
          exit 1
        fi

        jq --exit-status '
          .extraKnownMarketplaces.dotfiles.source.source == "directory" and
          .enabledPlugins["lsp@dotfiles"] == true
        ' ${managedSettings} > /dev/null

        # directory source の marketplace は git を持たないので、更新の判定は version だけが担う
        marketplace=$(jq -r '.extraKnownMarketplaces.dotfiles.source.path' ${managedSettings})
        jq --exit-status '
          .name == "dotfiles" and
          (.plugins | length) == 1 and
          .plugins[0].name == "lsp" and
          .plugins[0].source == "./lsp" and
          (.plugins[0].version | length) > 0
        ' "$marketplace/.claude-plugin/marketplace.json" > /dev/null
        diff --unified ${artifactSource "clis/claude/lsp"} "$marketplace/lsp/.lsp.json"
        jq --exit-status --slurpfile catalog "$marketplace/.claude-plugin/marketplace.json" '
          .name == "lsp" and .version == $catalog[0].plugins[0].version
        ' "$marketplace/lsp/.claude-plugin/plugin.json" > /dev/null

        touch $out
      '';
}
