#!/usr/bin/env bash
set -euo pipefail

images=(
  "ghcr.io/agentgateway/agentgateway:0.10.5"
  "iiidev/iii:0.11.2"
  "mcr.microsoft.com/playwright/mcp:latest"
  "searxng/searxng:2026.5.17-d7e8b7cd1"
  "valkey/valkey:latest"
  "isokoliuk/mcp-searxng:1.0.3"
  "unclecode/crawl4ai:latest"
  "sparfenyuk/mcp-proxy:v0.12.0"
)

binaries=(
  "https://github.com/probelabs/probe/releases/download/v0.6.0-rc316/probe-v0.6.0-rc316-x86_64-unknown-linux-musl.tar.gz"
  "https://github.com/github/github-mcp-server/releases/download/v1.0.5/github-mcp-server_Linux_x86_64.tar.gz"
  "https://registry.npmjs.org/@upstash/context7-mcp/-/context7-mcp-2.2.5.tgz"
)

prefetch_hash_sri() {
  nix store prefetch-file --json "$1" 2>/dev/null | jq -r .hash
}

fetch_image_digests() {
  echo "=== docker image digests ==="
  local img
  for img in "${images[@]}"; do
    echo "--- ${img} ---"
    docker pull "${img}" >/dev/null
    docker inspect "${img}" --format='{{index .RepoDigests 0}}'
  done
}

fetch_image_proxy_hash() {
  echo
  echo "=== sparfenyuk/mcp-proxy pullImage hash ==="
  nix run --extra-experimental-features 'nix-command flakes' \
    nixpkgs#nix-prefetch-docker -- \
    --image-name sparfenyuk/mcp-proxy --image-tag v0.12.0 2>&1 | tail -10
}

fetch_binary_hashes() {
  echo
  echo "=== binary tarball SRI hashes ==="
  local url
  for url in "${binaries[@]}"; do
    echo "--- ${url} ---"
    prefetch_hash_sri "${url}"
  done
}

main() {
  fetch_image_digests
  fetch_image_proxy_hash
  fetch_binary_hashes
}

main "$@"
