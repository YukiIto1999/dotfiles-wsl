{
  lib,
  pkgs,
  agentmemoryUrl,
  upstreamRoot,
  version,
}:

let
  mkHook =
    name: extraEnv:
    pkgs.writeShellScriptBin "agentmemory-hook-${name}" ''
      export AGENTMEMORY_URL=${agentmemoryUrl}
      ${extraEnv}exec ${upstreamRoot}/dist/hooks/${name}.mjs "$@"
    '';

  hookNames = [
    "session-start"
    "session-end"
    "stop"
    "prompt-submit"
    "pre-tool-use"
    "post-tool-use"
    "post-tool-failure"
    "pre-compact"
    "notification"
    "subagent-start"
    "subagent-stop"
    "task-completed"
  ];

  hooks = pkgs.symlinkJoin {
    name = "agentmemory-hooks-${version}";
    paths = lib.map (
      name:
      mkHook name (
        lib.optionalString (name == "session-start") "export AGENTMEMORY_INJECT_CONTEXT=true\n"
      )
    ) hookNames;
  };

  opencodePlugin = "${upstreamRoot}/plugin/opencode/agentmemory-capture.ts";
in
{
  inherit
    hooks
    opencodePlugin
    version
    ;
}
