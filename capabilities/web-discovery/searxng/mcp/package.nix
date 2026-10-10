{
  fetchurl,
  mkNpmMcp,
  searxngUrl,
  serverBuilder,
}:

let
  version = "2.5.0";
  pkg = mkNpmMcp {
    pname = "mcp-searxng";
    inherit version;
    src = fetchurl {
      url = "https://registry.npmjs.org/mcp-searxng/-/mcp-searxng-${version}.tgz";
      hash = "sha256-tisW0xBf17CbGlQ4tTM6g6Cag0W6l5rhmstDxPiz+yE=";
    };
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
