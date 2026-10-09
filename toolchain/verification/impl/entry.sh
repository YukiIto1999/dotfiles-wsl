#!/usr/bin/env bash
set -euo pipefail

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

nix_declaration_of() {
  local repo=$1 name=$2 metadata store_path nar_hash
  metadata=$(nix flake metadata --json --no-write-lock-file --no-update-lock-file "$repo") || return $?
  store_path=$(jq -er '.path' <<<"$metadata") || return $?
  nar_hash=$(jq -er '.locked.narHash' <<<"$metadata") || return $?
  nix-instantiate --eval --strict --json \
    --option pure-eval true --option allow-import-from-derivation false \
    --argstr source "$store_path" --argstr narHash "$nar_hash" \
    --argstr system "@system@" --argstr name "$name" \
    --expr '
      { source, narHash, system, name }:
      let
        flake = builtins.getFlake ("path:" + source + "?narHash=" + narHash);
        systems = flake.apps or {};
        apps = if builtins.hasAttr system systems then builtins.getAttr system systems else {};
        stages = [ "verify" "verify-push" "verify-full" ];
      in {
        authoritative = builtins.any (stage: builtins.hasAttr stage apps) stages;
        declared = builtins.hasAttr name apps;
      }
    '
}

entry_of() {
  local repo=$1 name=$2 script declaration untracked
  if [ -f "$repo/flake.nix" ]; then
    declaration=$(nix_declaration_of "$repo" "$name") || return $?
    if jq -e '.authoritative' <<<"$declaration" >/dev/null; then
      if jq -e '.declared' <<<"$declaration" >/dev/null; then
        untracked=$(git -C "$repo" ls-files --others --exclude-standard) || return $?
        if [ -n "$untracked" ]; then
          printf 'Nix検証のsourceに含まれない未追跡fileがあるため、先に追跡してから検証する:\n%s\n' "$untracked" >&2
          return 1
        fi
        printf 'nix run --no-write-lock-file .#%s' "$name"
      fi
      return 0
    fi
  fi
  if [ -f "$repo/devenv.nix" ] && grep -qE "scripts\\.${name}([^A-Za-z0-9_'-]|\$)" "$repo/devenv.nix"; then
    printf 'devenv shell -- %s' "$name"
    return 0
  fi
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
