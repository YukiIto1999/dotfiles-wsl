{
  config,
  lib,
  pkgs,
  ...
}:

# 本体は ~/.local/bin の upstream 配布 codex、Nix は起動 wrapper のみ持つ
# binary 未 install の間は spawn が失敗するだけで他 target に影響しない
let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = mkMcpServer {
    name = "codex-mcp";
    command = "${config.dotfiles.host.homeDir}/.local/bin/codex mcp-server";
  };
in
{
  dotfiles.mcp.targets.codex = {
    provider = "codex";
    port = 8777;
    # agent が外部の LLM API へ出る
    needsNetwork = true;
    serve = serveOverProxy (lib.getExe front);
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
