{ lib, ... }:

{
  dotfiles.capabilities.enabled = lib.mkForce [
    "agent-session"
    "browser-automation"
    "browser-diagnostics"
    "browser-runtime"
    "code-quality"
    "github-resources"
    "library-documentation"
    "project-memory"
    "repository-search"
    "unknown-capability"
    "web-content"
    "web-discovery"
  ];
}
