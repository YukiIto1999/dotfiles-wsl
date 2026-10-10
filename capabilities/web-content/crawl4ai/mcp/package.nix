{
  pkgs,
  crawl4aiUrl,
  tokenFile,
  serverBuilder,
}:

# native MCP の SSE・WebSocket が platform の対応 transport 外のため直結は不可
let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.mcp
    ps.httpx
  ]);
in
serverBuilder {
  name = "crawl4ai-mcp";
  env.CRAWL4AI_URL = crawl4aiUrl;
  env.CRAWL4AI_TOKEN_FILE = tokenFile;
  command = "${pythonEnv}/bin/python ${./package/server.py}";
}
