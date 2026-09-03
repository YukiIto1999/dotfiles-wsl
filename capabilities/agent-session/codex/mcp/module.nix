{
  config,
  lib,
  pkgs,
  ...
}:

# agent client contract が所有する Codex 実行パスの再配布禁止
let
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  clientExecutable = config.dotfiles.capabilities.agent-session.codex.runtime.executable;
  front = mkMcpServer {
    name = "codex-mcp";
    command = "${lib.escapeShellArg clientExecutable} mcp-server";
  };
in
{
  dotfiles.platform.mcp.targets.codex = {
    provider = "codex";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8777;
    needsNetwork = true;
    probe = {
      tool = "codex";
      args = {
        prompt = "Reply with exactly OK.";
        sandbox = "read-only";
        "approval-policy" = "never";
        cwd = "/tmp";
      };
      timeout = 120;
    };
  };
}
