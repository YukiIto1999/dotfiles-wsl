{
  pkgs,
  mkMcpServer,
  crawl4aiUrl,
  tokenFile,
}:

# crawl4ai HTTP engine への stdio front、実体は server.py。
# container の native MCP は /mcp/sse にあり gateway の sse target で繋がるが、
# Bearer を渡す backendAuth は route 単位でしか効かず、backend を名指しした
# policy は inline target へ届かない。直結すると token が全 upstream へ流れる
let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.mcp
    ps.httpx
  ]);
in
mkMcpServer {
  name = "crawl4ai-mcp";
  env.CRAWL4AI_URL = crawl4aiUrl;
  env.CRAWL4AI_TOKEN_FILE = tokenFile;
  command = "${pythonEnv}/bin/python ${./package/server.py}";
}
