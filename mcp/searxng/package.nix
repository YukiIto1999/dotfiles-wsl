{
  mkMcpServer,
  mkNpmMcp,
  searxngUrl,
}:

# self-hosted SearXNG への stdio front
let
  pkg = mkNpmMcp {
    pname = "mcp-searxng";
    version = "1.4.0";
    hash = "sha256-XZhYgbpNjtAvcM72j4EUHvlABk4eaNbFdvG4mbKvLKc=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-Lh1UoM8zSMFji/TkqDAOiRtFRrQ/jqn5TbONySj9ckg=";
  };
in
mkMcpServer {
  name = "searxng-mcp";
  env.SEARXNG_URL = searxngUrl;
  env.FETCH_TIMEOUT_MS = "30000";
  command = "${pkg}/bin/mcp-searxng";
}
