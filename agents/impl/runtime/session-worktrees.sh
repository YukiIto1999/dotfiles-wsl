set -euo pipefail

# 標準出力: session内に保持するworktreeのpath
# 終了値: 判定不能時の70と呼出し側によるsessionの保持

die() {
  printf 'dotfiles-agent-session-worktrees: %s\n' "$1" >&2
  exit 70
}

usage() {
  printf '%s\n' 'usage: dotfiles-agent-session-worktrees [--preview] [--nested-only] SESSION-DIRECTORY' >&2
  exit 64
}

preview=false
nested_only=false
while [ "$#" -gt 1 ]; do
  case $1 in
    --preview) preview=true ;;
    --nested-only) nested_only=true ;;
    *) usage ;;
  esac
  shift
done
[ "$#" -eq 1 ] || usage
session=$1
case $session in
  /*) ;;
  *) usage ;;
esac

present() {
  [ -e "$1" ] || [ -L "$1" ]
}

if ! present "$session"; then
  exit 0
fi
{ [ ! -L "$session" ] && [ -d "$session" ]; } || die "the session is not a directory: $session"
session_real=$(realpath -e -- "$session") || die "cannot resolve the session: $session"

record=$session/worktrees
if ! present "$record"; then
  exit 0
fi
if [ -L "$record" ] || [ ! -f "$record" ] || [ "$(stat -c %u "$record")" != "$(id -u)" ]; then
  die "the worktree record is not a regular file owned by this user: $record"
fi
mapfile -d '' -t fields <"$record" || die "cannot read the worktree record: $record"
[ $((${#fields[@]} % 2)) -eq 0 ] || die "the worktree record is truncated: $record"

paths=()
heads=()
for ((index = 0; index < ${#fields[@]}; index += 2)); do
  path=${fields[index]}
  head=${fields[index + 1]}
  case $path in
    /*) ;;
    *) die "the worktree record names a path that is not absolute: $record" ;;
  esac
  case $path/ in
    *//* | */./* | */../*) die "the worktree record names a path that is not canonical: $record" ;;
  esac
  case $head in
    '' | *[!0-9a-f]*) die "the worktree record holds a HEAD that is not a commit id: $record" ;;
  esac
  paths+=("$path")
  heads+=("$head")
done

# preview では内側が消えないため、内側を先に消す順序での外側の判定は不可
encloses_recorded() {
  local index=$1 other
  for ((other = 0; other < ${#paths[@]}; other++)); do
    [ "$other" -ne "$index" ] || continue
    [[ ${paths[other]} == "${paths[index]}/"* ]] || continue
    if present "${paths[other]}"; then
      return 0
    fi
  done
  return 1
}

# git worktree remove に dry-run が無いため、preview での削除の試行は不可
removable() {
  local path=$1 head=$2 top git_dir changes
  [ "$(git -C "$path" rev-parse --verify --quiet HEAD 2>/dev/null)" = "$head" ] || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$top" = "$path" ] || return 1
  git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ ! -e "$git_dir/locked" ] || return 1
  changes=$(git --no-optional-locks -C "$path" status --porcelain --ignore-submodules=none 2>/dev/null) || return 1
  [ -z "$changes" ]
}

retained=()
for ((index = 0; index < ${#paths[@]}; index++)); do
  path=${paths[index]}
  # session を内に持つ worktree は削除が他の scratch まで消すため対象外
  [[ $session_real/ != "$path/"* ]] || continue
  present "$path" || continue
  physical=$(realpath -e -- "$path" 2>/dev/null) || physical=''
  nested=false
  if [[ $path == "$session_real/"* || $physical == "$session_real/"* ]]; then
    nested=true
  fi
  if [ "$nested_only" = true ] && [ "$nested" = false ]; then
    continue
  fi

  kept=true
  if [ "$physical" = "$path" ] && ! encloses_recorded "$index" && removable "$path" "${heads[index]}"; then
    if [ "$preview" = true ]; then
      kept=false
    else
      git -C "$path" worktree remove -- "$path" >/dev/null 2>&1 || true
      if ! present "$path"; then
        kept=false
      fi
    fi
  fi
  if [ "$kept" = true ] && [ "$nested" = true ]; then
    retained+=("$path")
  fi
done

for path in "${retained[@]}"; do
  printf '%s\n' "$path"
done
