{
  lib,
  pkgs,
  mkMcpServer,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit mkMcpServer; };
in
{
  my.mcp.targets.playwright = {
    endpoint = "playwright";
    # front は session ごとの出力先をここから作る。場所は endpoint が決める
    environment = endpoint: {
      PLAYWRIGHT_MCP_RUNTIME_DIR = "/run/${endpoint.runtimeDirectory}";
    };
    transport.stdio.command = lib.getExe front;
  };
}
