#!/usr/bin/env bash
set -Eeuo pipefail

fail=0
repo="${DOTFILES:-$HOME/dotfiles-wsl}"
repo="$(readlink -f "$repo")"

ok()   { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

check_file() {
  local path=$1
  [[ -e $path || -L $path ]] && ok "$path exists" || bad "missing $path"
}

check_dir() {
  local path=$1
  [[ -d $path ]] && ok "$path exists" || bad "missing directory $path"
}

check_command_upstream() {
  local cmd=$1 path version
  path=$(type -P "$cmd" 2>/dev/null || true)
  if [[ -z $path ]]; then
    bad "$cmd not found in PATH"
    return
  fi

  case "$path" in
    /nix/store/*|/run/current-system/*|/etc/profiles/*)
      bad "$cmd resolves to Nix-managed binary: $path"
      return
      ;;
  esac

  version="$($cmd --version 2>/dev/null | head -n1 || true)"
  [[ -n $version ]] && ok "$cmd -> $path ($version)" || bad "$cmd exists but version check failed: $path"
}

check_unit_not_failed() {
  local unit=$1
  if systemctl is-failed --quiet "$unit" 2>/dev/null; then
    bad "$unit is failed"
    systemctl status "$unit" --no-pager 2>/dev/null || true
  else
    ok "$unit is not failed"
  fi
}

wait_unit_active() {
  local unit=$1 tries=${2:-30} sleep_s=${3:-2} i
  for ((i = 1; i <= tries; i++)); do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      ok "$unit is active"
      return 0
    fi
    sleep "$sleep_s"
  done
  bad "$unit is not active after $((tries * sleep_s))s"
  systemctl status "$unit" --no-pager 2>/dev/null || true
}

actual_etc="$(readlink -f /etc/nixos 2>/dev/null || true)"
[[ $actual_etc == "$repo" ]] && ok "/etc/nixos -> $actual_etc" || bad "/etc/nixos -> ${actual_etc:-<none>}; expected $repo"

check_file "$repo/flake.nix"
check_file "$repo/flake.lock"
check_file "$repo/modules/default.nix"
check_file "$repo/home/default.nix"
check_file "$repo/secrets/secrets.yaml"

check_command_upstream claude
check_command_upstream codex
check_command_upstream opencode
check_command_upstream agy

check_file "$HOME/.claude/settings.json"
check_file "$HOME/.claude/CLAUDE.md"
check_file "$HOME/.codex/config.toml"
check_file "$HOME/.codex/AGENTS.md"
check_file "$HOME/.config/opencode/opencode.json"
check_file "$HOME/.config/opencode/AGENTS.md"
check_file "$HOME/.gemini/AGENTS.md"
check_file "$HOME/.gemini/antigravity-cli/mcp_config.json"
check_file "$HOME/.config/git/identity.conf"
check_file "$HOME/.config/gh/hosts.yml"
check_dir "$HOME/.claude/agents"
check_dir "$HOME/.codex/agents"
check_dir "$HOME/.config/opencode/agents"
check_dir "$HOME/.gemini/agents"
check_dir "$HOME/.claude/skills"
check_dir "$HOME/.codex/skills"
check_dir "$HOME/.config/opencode/skills"
check_dir "$HOME/.gemini/antigravity-cli/skills"

claude mcp get gateway 2>/dev/null | grep -q 'http://localhost:8765/mcp' \
  && ok "Claude gateway registered" \
  || bad "Claude gateway not registered"

if [[ -f /etc/codex/config.toml ]]; then
  grep -q 'http://localhost:8765/mcp' /etc/codex/config.toml \
    && ok "Codex gateway URL configured" \
    || bad "Codex gateway URL missing"
fi

if [[ -f "$HOME/.config/opencode/opencode.json" ]]; then
  grep -q 'http://localhost:8765/mcp' "$HOME/.config/opencode/opencode.json" \
    && ok "OpenCode gateway URL configured" \
    || bad "OpenCode gateway URL missing"
fi

if [[ -f "$HOME/.gemini/antigravity-cli/mcp_config.json" ]]; then
  grep -q 'http://localhost:8765/mcp' "$HOME/.gemini/antigravity-cli/mcp_config.json" \
    && ok "Antigravity gateway URL configured" \
    || bad "Antigravity gateway URL missing"
fi

check_file /etc/agentgateway/config.yaml
check_file /etc/searxng/settings.yml
check_file /etc/claude-code/managed-settings.json
check_file /etc/codex/config.toml

check_unit_not_failed home-manager-nixos.service
wait_unit_active docker.service
wait_unit_active docker-mcp-backends-network.service
wait_unit_active agentgateway.service

if docker network inspect mcp-backends >/dev/null 2>&1; then
  ok "docker network mcp-backends exists"
else
  bad "docker network mcp-backends missing"
fi

command -v wslview >/dev/null 2>&1 && ok "wslview exists" || bad "wslview missing"

if [[ -e /lib64/ld-linux-x86-64.so.2 || -e /lib/ld-linux-x86-64.so.2 ]]; then
  ok "nix-ld dynamic linker path exists"
else
  warn "nix-ld dynamic linker path not found at standard location"
fi

exit "$fail"
