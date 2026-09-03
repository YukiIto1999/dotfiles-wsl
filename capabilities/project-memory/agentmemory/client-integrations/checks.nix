{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  expectedVersion = "0.9.26";
  expectedHookNames = [
    "notification"
    "post-tool-failure"
    "post-tool-use"
    "pre-compact"
    "pre-tool-use"
    "prompt-submit"
    "session-end"
    "session-start"
    "stop"
    "subagent-start"
    "subagent-stop"
    "task-completed"
  ];
  agentmemory = hostConfig.dotfiles.capabilities.project-memory.agentmemory.clientIntegrations;
  plugin = toString agentmemory.opencodePlugin;
in
{
  agentmemory-client-integration =
    assert agentmemory.version == expectedVersion;
    assert lib.getVersion agentmemory.hooks == expectedVersion;
    assert lib.hasInfix "agentmemory-deploy-${expectedVersion}" plugin;
    assert lib.hasSuffix "/plugin/opencode/agentmemory-capture.ts" plugin;
    pkgs.runCommandLocal "check-agentmemory-client-integration"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        set -euo pipefail

        printf '%s\n' ${lib.escapeShellArgs (map (name: "agentmemory-hook-${name}") expectedHookNames)} \
          | sort > expected-hooks
        : > actual-hooks
        for hook in ${agentmemory.hooks}/bin/agentmemory-hook-*; do
          basename "$hook" >> actual-hooks
          grep -Fq 'agentmemory-deploy-${expectedVersion}' "$hook"
          grep -Fq 'export AGENTMEMORY_URL=http://127.0.0.1:3111' "$hook"
        done
        sort -o actual-hooks actual-hooks
        diff -u expected-hooks actual-hooks
        grep -Fq 'export AGENTMEMORY_INJECT_CONTEXT=true' \
          ${agentmemory.hooks}/bin/agentmemory-hook-session-start

        plugin=${lib.escapeShellArg plugin}
        pluginRoot=$(dirname "$(dirname "$(dirname "$plugin")")")
        test -f "$plugin"
        jq -e \
          --arg version '${expectedVersion}' \
          '.version == $version' \
          "$pluginRoot/package.json" >/dev/null
        touch $out
      '';
}
