{
  mkNpmMcp,
  searxngUrl,
  serverBuilder,
}:

let
  pkg = mkNpmMcp {
    pname = "mcp-searxng";
    version = "2.5.0";
    hash = "sha256-tisW0xBf17CbGlQ4tTM6g6Cag0W6l5rhmstDxPiz+yE=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-Iwm2z+49fmtJE0N+vMbmgdbgMmL6WbI9QKGg46Rwk88=";
  };
in
serverBuilder {
  name = "searxng-mcp";
  env.SEARXNG_URL = searxngUrl;
  env.FETCH_TIMEOUT_MS = "30000";
  env.MCP_TOOL_RATE_MAX = "600";
  command = "${pkg}/bin/mcp-searxng";
}
