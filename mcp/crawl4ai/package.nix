{
  pkgs,
  mkMcpServer,
  crawl4aiUrl,
  tokenFile,
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
  env.CRAWL4AI_TOKEN_FILE = tokenFile;
  command = "${pythonEnv}/bin/python ${./package/server.py}";
}
