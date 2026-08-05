{
  mkNpmMcp,
  searxngUrl,
  serverBuilder,
}:

# self-hosted SearXNG への front。listen 先は module が env で渡す
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
  # 全 agent が gateway 経由で同じ IP から来るので、既定の毎分 20 回では足りない
  env.MCP_RATE_INIT_MAX = "600";
  env.MCP_RATE_SESSION_MAX = "600";
  command = "${pkg}/bin/mcp-searxng";
}
