{
  pkgs,
  mkMcpServer,
  crawl4aiUrl,
}:

# crawl4ai HTTP engine への stdio front、実体は server.py
let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.mcp
    ps.httpx
  ]);
in
mkMcpServer {
  name = "crawl4ai-mcp";
  env.CRAWL4AI_URL = crawl4aiUrl;
  command = "${pythonEnv}/bin/python ${./server.py}";
}
