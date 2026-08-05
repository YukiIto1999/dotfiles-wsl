{ lib, ... }:

{
  dotfiles.containers.enabled = lib.mkForce [
    "agentmemory"
    "crawl4ai"
    "searxng"
    "sonarqube"
    "missing-container"
  ];
}
