{ pkgs, crawl4aiUrl }:

# crawl4ai MCP server: a small stdio front (server.py) over the crawl4ai HTTP API.
let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.mcp ps.httpx ]);
in
pkgs.writeShellScriptBin "crawl4ai-mcp" ''
  export CRAWL4AI_URL=${crawl4aiUrl}
  exec ${pythonEnv}/bin/python ${./server.py} "$@"
''
