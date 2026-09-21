#!/usr/bin/env bash
set -euo pipefail

# 検証入口を通していない木で agent が仕事を終えられないようにする門。
#
# dotfiles-agent-verify は成功した走行の指紋を控えるが、その控えを読む者がいなかった。
# 読む者をここに置く。agent が編集した repository ごとに、検証入口が「いまの木」に対して
# 通っているかを stop の時点で問い、通っていなければ理由と入口の綴りを返して止める。

usage() {
  cat >&2 <<'USAGE'
usage: dotfiles-agent-gate <command> [options]

  record [--repo DIR] [--command TEXT]  検証入口が通った木の控えを書く
  arm --session ID [--path PATH]        その session が編集した repository を控える
  check [--repo DIR] [--session ID]     未検証なら理由を出して 1 で終わる
  waive --reason TEXT [--repo DIR]      理由を残していまの木を一度だけ通す
  hook <arm|stop>                       client の hook から stdin の JSON で起こす
  entry [--repo DIR]                    その repository の検証入口の綴りを答える
USAGE
  exit 64
}

cache_root="$HOME/@cacheRootRelative@"
verification_root="$cache_root/verification"
sessions_root="$verification_root/sessions"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

repo_top_of() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

project_id_of() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(realpath -e -- "$common") || return 1
  printf '%s' "$common" | sha256sum | cut -d ' ' -f 1
}

# いまの木の指紋。HEAD と追跡済みの差分と未追跡の中身だけから採る。
# verify の指紋と違い環境も argv も混ぜない。同じ木なら誰が測っても同じ値になることが要る。
source_fingerprint() {
  local repo=$1 head path
  head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf 'none')
  {
    printf 'dotfiles-agent-gate-v1\0head\0%s\0tracked\0' "$head"
    git -C "$repo" -c color.ui=false diff --binary --full-index --no-ext-diff --no-textconv HEAD --
    printf '\0untracked\0'
    while IFS= read -r -d '' path; do
      printf 'path\0%s\0' "$path"
      if [ -L "$repo/$path" ]; then
        printf 'symlink\0'
        readlink --zero -- "$repo/$path"
      elif [ -f "$repo/$path" ]; then
        printf 'regular\0'
        sha256sum <"$repo/$path"
      else
        printf 'other\0'
      fi
    done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  } | sha256sum | cut -d ' ' -f 1
}

# その repository が宣言する検証入口。宣言が無ければ空を返し、門は何も要求しない。
entry_of() {
  local repo=$1
  if [ -f "$repo/devenv.nix" ] && grep -q 'scripts\.verify' "$repo/devenv.nix"; then
    printf 'devenv shell -- verify'
    return 0
  fi
  local recipe
  for recipe in justfile Justfile; do
    if [ -f "$repo/$recipe" ] && grep -qE '^verify[[:space:]]*:' "$repo/$recipe"; then
      printf 'just verify'
      return 0
    fi
  done
  if [ -f "$repo/package.json" ] && jq -e '.scripts.verify' "$repo/package.json" >/dev/null 2>&1; then
    if [ -f "$repo/pnpm-lock.yaml" ]; then printf 'pnpm verify'; else printf 'npm run verify'; fi
    return 0
  fi
  if [ -f "$repo/Makefile" ] && grep -qE '^verify[[:space:]]*:' "$repo/Makefile"; then
    printf 'make verify'
    return 0
  fi
  printf ''
}

state_dir_of() {
  local repo=$1 id
  id=$(project_id_of "$repo") || return 1
  printf '%s/%s' "$verification_root" "$id"
}

ensure_dir() {
  mkdir -p "$1"
  chmod 700 "$1"
}

command_record() {
  local repo=${1:-$PWD} text=${2:-} top state fingerprint
  top=$(repo_top_of "$repo") || return 0
  state=$(state_dir_of "$top") || return 0
  ensure_dir "$state"
  fingerprint=$(source_fingerprint "$top")
  printf 'version=1\nsource=%s\ncommand=%s\nat=%s\n' \
    "$fingerprint" "$text" "$(date -Iseconds)" >"$state/$fingerprint.verified"
}

command_arm() {
  local session=$1 path=${2:-$PWD} top id
  [ -n "$session" ] || fail 'arm には --session が要る'
  [ -e "$path" ] || path=$(dirname -- "$path")
  [ -d "$path" ] || path=$(dirname -- "$path")
  top=$(repo_top_of "$path") || return 0
  id=$(project_id_of "$top") || return 0
  ensure_dir "$sessions_root/$session"
  printf '%s\n' "$top" >"$sessions_root/$session/$id"
}

# 未検証なら理由を stdout と stderr の両方へ出して 1 で終わる。
# claude は stderr を、omp の拡張は stdout を読む。
command_check() {
  local repo=$1 top state entry fingerprint reason
  top=$(repo_top_of "$repo") || return 0
  entry=$(entry_of "$top")
  [ -n "$entry" ] || return 0
  state=$(state_dir_of "$top") || return 0
  fingerprint=$(source_fingerprint "$top")
  if [ -f "$state/$fingerprint.verified" ]; then
    return 0
  fi
  if [ -f "$state/$fingerprint.waived" ]; then
    printf '%s を未検証のまま通した理由: %s\n' \
      "$top" "$(sed -n 's/^reason=//p' "$state/$fingerprint.waived")" >&2
    return 0
  fi
  reason=$(
    printf '%s の検証入口が、いまの木に対して通っていない。\n' "$top"
    printf '  通す: cd %s && dotfiles-agent-verify -- %s\n' "$top" "$entry"
    printf '  通せない事情があるなら理由を残して抜ける: dotfiles-agent-gate waive --repo %s --reason "<理由>"\n' "$top"
  )
  printf '%s\n' "$reason"
  printf '%s\n' "$reason" >&2
  return 1
}

command_waive() {
  local repo=${1:-$PWD} reason=$2 top state fingerprint
  [ -n "$reason" ] || fail 'waive には --reason が要る'
  top=$(repo_top_of "$repo") || fail 'git の木の中で呼ぶ'
  state=$(state_dir_of "$top") || fail 'git の木の中で呼ぶ'
  ensure_dir "$state"
  fingerprint=$(source_fingerprint "$top")
  printf 'version=1\nsource=%s\nreason=%s\nat=%s\n' \
    "$fingerprint" "$reason" "$(date -Iseconds)" >"$state/$fingerprint.waived"
  printf '%s を未検証のまま通す理由を控えた: %s\n' "$top" "$reason"
}

command_hook() {
  local kind=$1 payload session cwd path marker held status=0
  payload=$(cat)
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty')
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
  [ -n "$cwd" ] || cwd=$PWD

  case $kind in
  arm)
    path=$(printf '%s' "$payload" |
      jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filePath // empty')
    [ -n "$path" ] || path=$cwd
    case $path in /*) ;; *) path="$cwd/$path" ;; esac
    command_arm "$session" "$path" || true
    ;;
  stop)
    # この session が編集した repository だけを問う。読むだけの周は素通りする。
    if [ -n "$session" ] && [ -d "$sessions_root/$session" ]; then
      for marker in "$sessions_root/$session"/*; do
        [ -f "$marker" ] || continue
        held=$(cat "$marker")
        [ -d "$held" ] || continue
        command_check "$held" || status=2
      done
    fi
    exit "$status"
    ;;
  *) usage ;;
  esac
}

main() {
  local command=${1-}
  [ -n "$command" ] || usage
  shift || true

  local repo=$PWD session="" reason="" text="" path=""
  while [ "$#" -gt 0 ]; do
    case $1 in
    --repo)
      repo=$2
      shift 2
      ;;
    --session)
      session=$2
      shift 2
      ;;
    --reason)
      reason=$2
      shift 2
      ;;
    --command)
      text=$2
      shift 2
      ;;
    --path)
      path=$2
      shift 2
      ;;
    arm | stop) break ;;
    *) usage ;;
    esac
  done

  case $command in
  record) command_record "$repo" "$text" ;;
  arm) command_arm "$session" "${path:-$repo}" ;;
  check) command_check "$repo" ;;
  waive) command_waive "$repo" "$reason" ;;
  entry) entry_of "$(repo_top_of "$repo")" ;;
  hook) command_hook "${1-}" ;;
  *) usage ;;
  esac
}

main "$@"
