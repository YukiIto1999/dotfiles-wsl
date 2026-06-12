#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
usage:
  fetch-mcp-info.sh url <URL>
  fetch-mcp-info.sh image <IMAGE>

Examples:
  fetch-mcp-info.sh url https://github.com/agentgateway/agentgateway/releases/download/v1.2.1/agentgateway-linux-amd64
  fetch-mcp-info.sh image mcr.microsoft.com/playwright/mcp:latest
USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: required command not found: $1" >&2
    exit 1
  }
}

prefetch_url() {
  local url=$1
  need nix
  nix store prefetch-file --hash-type sha256 --json "$url"
}

inspect_image() {
  local image=$1
  need docker
  need jq
  docker manifest inspect "$image" | jq -r '
    if .Descriptor.digest then
      .Descriptor.digest
    elif .manifests then
      .manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux") | .digest
    else
      empty
    end
  '
}

main() {
  [[ $# -eq 2 ]] || { usage; exit 2; }

  case "$1" in
    url)   prefetch_url "$2" ;;
    image) inspect_image "$2" ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
