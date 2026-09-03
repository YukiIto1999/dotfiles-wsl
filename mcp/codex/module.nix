{
  config,
  lib,
  pkgs,
  ...
}:

# agent client contract が所有する Codex 実行パスの再配布禁止
let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  clientExecutable = config.dotfiles.agents.clientExecutables.codex;
  front = mkMcpServer {
    name = "codex-mcp";
    command = "${lib.escapeShellArg clientExecutable} mcp-server";
  };
in
{
  dotfiles.mcp.targets.codex = {
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
