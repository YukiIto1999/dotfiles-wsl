{ lib, ... }:

{
  dotfiles.capabilities.enabled = lib.mkForce [
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
