#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "FATAL: $*" >&2; exit 1; }
log()  { printf '== %s\n' "$*"; }

[[ ${EUID} -ne 0 ]] || fail "run as the target user, not root"

install -d -m 0755 "$HOME/.local/bin" "$HOME/.local/share/dotfiles-wsl"

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found in PATH"
}

require curl
require jq
require tar
require gzip
require install
require uname
install_claude() {
  log "claude"
  curl -fsSL https://claude.ai/install.sh | bash

  if ! command -v claude >/dev/null 2>&1; then
    fail "claude not found after upstream installer; ensure ~/.local/bin is in PATH"
  fi

  claude --version || fail "claude installed but version check failed"
}

codex_target() {
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) printf '%s\n' "aarch64-unknown-linux-musl" ;;
    *) fail "unsupported architecture for Codex CLI: $(uname -m)" ;;
  esac
}

install_codex() {
  local target asset api url tmp member
  target="$(codex_target)"
  asset="codex-${target}.tar.gz"
  api="https://api.github.com/repos/openai/codex/releases/latest"

  log "codex"
  url="$(curl -fsSL "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n1)"
  [[ -n "$url" && "$url" != "null" ]] || fail "release asset not found: ${asset}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  curl -fL "$url" -o "$tmp/$asset"
  member="$(tar -tzf "$tmp/$asset" | head -n1)"
  [[ -n "$member" ]] || fail "empty Codex archive: ${asset}"
  tar -xzf "$tmp/$asset" -C "$tmp"

  [[ -f "$tmp/$member" ]] || fail "Codex binary not found in archive: ${member}"
  install -m 0755 "$tmp/$member" "$HOME/.local/bin/codex"

  "$HOME/.local/bin/codex" --version || fail "codex installed but version check failed"
}

opencode_asset() {
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "opencode-linux-x64.tar.gz" ;;
    aarch64|arm64) printf '%s\n' "opencode-linux-arm64.tar.gz" ;;
    *) fail "unsupported architecture for OpenCode: $(uname -m)" ;;
  esac
}

install_opencode() {
  local asset api url tmp
  asset="$(opencode_asset)"
  api="https://api.github.com/repos/anomalyco/opencode/releases/latest"

  log "opencode"
  url="$(curl -fsSL "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n1)"
  [[ -n "$url" && "$url" != "null" ]] || fail "release asset not found: ${asset}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  curl -fL "$url" -o "$tmp/$asset"
  tar -xzf "$tmp/$asset" -C "$tmp"

  [[ -f "$tmp/opencode" ]] || fail "opencode binary not found in archive"
  install -m 0755 "$tmp/opencode" "$HOME/.local/bin/opencode"

  "$HOME/.local/bin/opencode" --version || fail "opencode installed but version check failed"
}

install_antigravity() {
  log "agy"
  curl -fsSL https://antigravity.google/cli/install.sh | bash

  if ! command -v agy >/dev/null 2>&1; then
    fail "agy not found after upstream installer; ensure ~/.local/bin is in PATH"
  fi

  agy --version || fail "agy installed but version check failed"
}

install_claude
install_codex
install_opencode
install_antigravity
