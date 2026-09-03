{
  pkgs,
  crawl4aiUrl,
  tokenFile,
  serverBuilder,
}:

# ルート単位の backendAuth が inline target へ届かず全上流へトークンを流す native MCP 直結の不採用
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
