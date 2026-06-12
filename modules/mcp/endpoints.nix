# Constants shared by servers.nix and backends.nix.
# Backends publish these ports to loopback; the native stdio fronts dial them.
rec {
  ports = {
    searxng     = "8080";
    valkey      = "6379";
    crawl4ai    = "11235";
    agentmemory = "3111";
    agentmemoryStream = "3112";
    cdp         = "9222";
  };

  searxngUrl     = "http://127.0.0.1:${ports.searxng}";
  crawl4aiUrl    = "http://127.0.0.1:${ports.crawl4ai}";
  agentmemoryUrl = "http://127.0.0.1:${ports.agentmemory}";
  cdpEndpoint    = "http://127.0.0.1:${ports.cdp}";

  userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
}
