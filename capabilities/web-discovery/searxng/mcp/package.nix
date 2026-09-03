{
  mkNpmMcp,
  searxngUrl,
  serverBuilder,
}:

let
  pkg = mkNpmMcp {
    pname = "mcp-searxng";
    version = "1.4.0";
    hash = "sha256-XZhYgbpNjtAvcM72j4EUHvlABk4eaNbFdvG4mbKvLKc=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-Lh1UoM8zSMFji/TkqDAOiRtFRrQ/jqn5TbONySj9ckg=";
  };
in
serverBuilder {
  name = "searxng-mcp";
  env.SEARXNG_URL = searxngUrl;
  env.FETCH_TIMEOUT_MS = "30000";
  # gateway の送信元 IP 集約では不足する既定の毎分 20 回制限
  env.MCP_RATE_INIT_MAX = "600";
  env.MCP_RATE_SESSION_MAX = "600";
  command = "${pkg}/bin/mcp-searxng";
}
