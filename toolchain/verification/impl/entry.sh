#!/usr/bin/env bash
set -euo pipefail

# repository が宣言する検証の段の入口を、呼び出しの綴りで答える。
# 段は verify(T1)、verify-push(T2)、verify-full(T3)の三つで、宣言が無ければ空を返す。
# 宣言は devenv の script、just の recipe、package.json の script、Makefile の target の順に探す。

usage() {
  printf 'usage: dotfiles-verify-entry [--repo DIR] verify|verify-push|verify-full\n' >&2
  exit 64
}

# package.json の script 名は段の区切りを `:` で書く
script_name_of() {
  case $1 in
  verify) printf 'verify' ;;
  verify-push) printf 'verify:push' ;;
  verify-full) printf 'verify:full' ;;
  esac
}

entry_of() {
  local repo=$1 name=$2 recipe script
  # 名前の直後を区切りに限り、`scripts.verify-push` を `scripts.verify` の宣言と読まない
  if [ -f "$repo/devenv.nix" ] && grep -qE "scripts\\.${name}([^A-Za-z0-9_'-]|\$)" "$repo/devenv.nix"; then
    printf 'devenv shell -- %s' "$name"
    return 0
  fi
  for recipe in justfile Justfile; do
    if [ -f "$repo/$recipe" ] && grep -qE "^${name}[[:space:]]*:" "$repo/$recipe"; then
      printf 'just %s' "$name"
      return 0
    fi
  done
  script=$(script_name_of "$name")
  if [ -f "$repo/package.json" ] \
    && jq -e --arg script "$script" '.scripts[$script]' "$repo/package.json" >/dev/null 2>&1; then
    if [ -f "$repo/pnpm-lock.yaml" ]; then
      printf 'pnpm %s' "$script"
    else
      printf 'npm run %s' "$script"
    fi
    return 0
  fi
  if [ -f "$repo/Makefile" ] && grep -qE "^${name}[[:space:]]*:" "$repo/Makefile"; then
    printf 'make %s' "$name"
  fi
}

main() {
  local repo=$PWD name="" top
  while [ "$#" -gt 0 ]; do
    case $1 in
    --repo)
      [ "$#" -ge 2 ] || usage
      repo=$2
      shift 2
      ;;
    verify | verify-push | verify-full)
      [ -z "$name" ] || usage
      name=$1
      shift
      ;;
    *) usage ;;
    esac
  done
  [ -n "$name" ] || usage
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 0
  entry_of "$top" "$name"
}

main "$@"
