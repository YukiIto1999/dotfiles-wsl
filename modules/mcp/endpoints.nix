# servers.nix と backends.nix が共有する loopback endpoint
rec {
  ports = {
    searxng           = "8080";
    valkey            = "6379";
    crawl4ai          = "11235";
    agentmemory       = "3111";
    agentmemoryStream = "3112";
  };

  searxngUrl     = "http://127.0.0.1:${ports.searxng}";
  crawl4aiUrl    = "http://127.0.0.1:${ports.crawl4ai}";
  agentmemoryUrl = "http://127.0.0.1:${ports.agentmemory}";
}
