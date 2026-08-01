{
  config,
  lib,
  mkMcpServer,
  ...
}:

# 本体は ~/.local/bin の upstream 配布 codex、Nix は起動 wrapper のみ持つ
# binary 未 install の間は spawn が失敗するだけで他 target に影響しない
let
  front = mkMcpServer {
    name = "codex-mcp";
    command = "${config.my.homeDir}/.local/bin/codex mcp-server";
  };
in
{
  my.mcp.targets.codex = {
    endpoint = "codex";
    transport.stdio.command = lib.getExe front;
  };
}
