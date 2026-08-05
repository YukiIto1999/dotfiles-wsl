{ lib, ... }:

{
  dotfiles.mcp.enabledProviders = lib.mkForce [
    "chrome-devtools"
    "codex"
    "context7"
    "crawl4ai"
    "github"
    "memory"
    "playwright"
    "searxng"
    "sonarqube"
    "missing-provider"
  ];
}
