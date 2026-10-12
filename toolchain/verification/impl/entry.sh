#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: dotfiles-verify-entry [--repo DIR] [--policy FILE] [--budget | --candidates | --snapshot] verify|verify-push|verify-full\n' >&2
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


native_entry_of() {
  printf 'nix run --no-write-lock-file .#%s' "$1"
}

parse_policy() {
  local allow_absent=$1
  shift
  jq -cs --argjson allow_absent "$allow_absent" '
    if length == 1 then .[0] else error("expected one metadata object") end |
    if $allow_absent and . == null or type == "object" and .version == 1
      and (
        (has("frontend") | not) and (has("entries") | not)
        or .frontend == "nix" and (.entries | type == "array")
          and all(.entries[]; . == "verify" or . == "verify-push" or . == "verify-full")
      )
    then . else error("invalid verification metadata") end
  ' "$@"
}

read_policy() {
  local top=$1 file=$1/verification-budget.json
  if [ -e "$file" ] || [ -L "$file" ]; then
    if ! parse_policy false "$file"; then
      printf '%s の検証宣言が不正である\n' "$file" >&2
      return 1
    fi
    return
  fi
  if git -C "$top" ls-files --error-unmatch -- verification-budget.json >/dev/null 2>&1 \
    || git -C "$top" cat-file -e HEAD:verification-budget.json 2>/dev/null; then
    printf '%s が追跡中の宣言から削除されているため、入口未宣言として扱わない\n' "$file" >&2
    return 1
  fi
  printf 'null\n'
}
policy_of() {
  if [ -n "$policy_file" ]; then
    if ! parse_policy true "$policy_file"; then
      printf '%s の検証宣言snapshotが読めない、または不正である\n' "$policy_file" >&2
      return 1
    fi
    return
  fi
  read_policy "$1"
}


static_entry_of() {
  local repo=$1 name=$2 script
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

# 時間予算が無い宣言を評価して入口の有無を決める方式の不採用: 上限の確定前の任意コード実行
entry_of() {
  local repo=$1 name=$2 policy untracked
  policy=$(policy_of "$repo") || return $?
  if jq -e '.frontend == "nix"' <<<"$policy" >/dev/null; then
    if jq -e --arg name "$name" '.entries | index($name) != null' <<<"$policy" >/dev/null; then
      if [ ! -f "$repo/flake.nix" ]; then
        printf '%s が登録する Nix の入口に flake.nix が無い\n' "$repo" >&2
        return 1
      fi
      untracked=$(git -C "$repo" ls-files --others --exclude-standard) || return $?
      if [ -n "$untracked" ]; then
        printf 'Nix検証のsourceに含まれない未追跡fileがあるため、先に追跡してから検証する:\n%s\n' "$untracked" >&2
        return 1
      fi
      native_entry_of "$name"
    fi
    return 0
  fi
  static_entry_of "$repo" "$name"
}

candidates_of() {
  local repo=$1 name=$2 static
  static=$(static_entry_of "$repo" "$name")
  if [ -n "$static" ]; then
    printf '%s\n' "$static"
  fi
  if [ -f "$repo/flake.nix" ]; then
    printf '%s\n' "$(native_entry_of "$name")"
  fi
}

# 予算の正本が project の宣言のため、宣言の無い段への既定値と無制限の補完は不可
budget_of() {
  local top=$1 name=$2 file policy seconds
  file=$top/verification-budget.json
  policy=$(policy_of "$top") || return $?
  if ! seconds=$(jq -e --arg stage "$name" '
    if type == "object" and (.[$stage] | type == "object")
      and (.[$stage].seconds | type == "number" and . >= 1 and . <= 2147483647 and . == floor)
    then .[$stage].seconds | floor
    else empty end
  ' <<<"$policy"); then
    printf '%s に %s の時間予算が宣言されていない、または不正である(version は 1、%s の seconds は 1 以上の整数)\n' \
      "$file" "$name" "$name" >&2
    return 1
  fi
  printf '%s\n' "$seconds"
}


main() {
  local repo=$PWD name="" top mode=entry policy_file=
  while [ "$#" -gt 0 ]; do
    case $1 in
    --repo)
      [ "$#" -ge 2 ] || usage
      repo=$2
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] && [ -z "$policy_file" ] || usage
      policy_file=$2
      [ -n "$policy_file" ] || usage
      shift 2
      ;;
    --budget | --candidates | --snapshot)
      [ "$mode" = entry ] || usage
      mode=${1#--}
      shift
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
  if [ -n "$policy_file" ] && [ "$mode" != entry ] && [ "$mode" != budget ]; then
    usage
  fi
  if ! top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null); then
    [ "$mode" != budget ] || {
      printf '%s は git の木の外にあり、時間予算の宣言が無い\n' "$repo" >&2
      return 1
    }
    [ "$mode" != snapshot ] || printf 'null\n'
    return 0
  fi
  case $mode in
  budget) budget_of "$top" "$name" ;;
  entry) entry_of "$top" "$name" ;;
  candidates) candidates_of "$top" "$name" ;;
  snapshot) read_policy "$top" ;;
  esac
}

main "$@"
