#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
usage: cleanup-local.sh [--delete] [--system] [--vscode-server]

Without --delete, prints cleanup targets only.
With --delete, removes local failure leftovers.
With --system, also removes /etc/nixos backup/failure leftovers.
With --vscode-server, also removes ~/.vscode-server so VS Code Remote WSL reinstalls it.
USAGE
}

delete=0
system=0
vscode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) delete=1 ;;
    --system) system=1 ;;
    --vscode-server) vscode=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

remove_path() {
  local path=$1
  [[ -e $path || -L $path ]] || return 0
  if [[ $delete -eq 1 ]]; then
    rm -rf -- "$path"
    echo "removed $path"
  else
    echo "would remove $path"
  fi
}

shopt -s nullglob globstar

# *.hm-back backups under each managed CLI root
for path in \
  "$HOME"/.claude.bak.* \
  "$HOME"/.codex.bak.* \
  "$HOME"/.claude.failed.* \
  "$HOME"/.codex.failed.* \
  "$HOME"/dotfiles-wsl.assistant-broken-*.diff \
  "$HOME"/.claude/**/*.hm-back \
  "$HOME"/.codex/**/*.hm-back \
  "$HOME"/.config/git/**/*.hm-back \
  "$HOME"/.config/gh/**/*.hm-back \
  "$HOME"/.config/opencode/**/*.hm-back \
  "$HOME"/.gemini/**/*.hm-back; do
  remove_path "$path"
done

if [[ $system -eq 1 ]]; then
  for path in /etc/nixos.bak.* /etc/nixos.failed.*; do
    remove_path "$path"
  done
fi

if [[ $vscode -eq 1 ]]; then
  remove_path "$HOME/.vscode-server"
fi
