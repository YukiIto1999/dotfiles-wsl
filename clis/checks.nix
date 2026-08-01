{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  artifactSource = id: hostConfig.my.artifacts.${id}.source;
  managedSettings = hostConfig.environment.etc."claude-code/managed-settings.json".source;
  roster = hostConfig.my.toolchain.lsp;
in
{
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
            --argjson extensions ${lib.escapeShellArg (builtins.toJSON roster.${name}.extensions)} '
            .["${name}"].command == $command and
            (.["${name}"].args // []) == $args and
            .["${name}"].extensionToLanguage == $extensions
          ' ${artifactSource "clis/claude/lsp"} > /dev/null

          jq --exit-status \
            --argjson command ${
              lib.escapeShellArg (builtins.toJSON ([ roster.${name}.command ] ++ roster.${name}.args))
            } \
            --argjson extensions ${
              lib.escapeShellArg (builtins.toJSON (builtins.attrNames roster.${name}.extensions))
            } '
            .lsp["${name}"].command == $command and
            (.lsp["${name}"].extensions | sort) == ($extensions | sort)
          ' ${artifactSource "clis/opencode/config"} > /dev/null
        '') (builtins.attrNames roster)}

        # 同じ拡張子を二つの server が宣言すると、先に登録された片方だけが動く
        jq -r '.[].extensionToLanguage | keys[]' ${artifactSource "clis/claude/lsp"} | sort > extensions
        if [ "$(sort -u extensions | wc -l)" != "$(wc -l < extensions)" ]; then
          echo "one file extension is claimed by more than one language server:" >&2
          uniq -d extensions >&2
          exit 1
        fi

        # directory source の marketplace は git を持たないので、更新の判定は version だけが担う
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
