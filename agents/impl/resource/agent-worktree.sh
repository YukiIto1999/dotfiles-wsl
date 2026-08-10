set -euo pipefail

program=dotfiles-agent-worktree
usage_text="usage: $program add [ADD-OPTION...] PATH [COMMIT-ISH]"
git_command=@gitCommand@
resource_command=@resourceCommand@

die() {
  printf '%s: %s\n' "$program" "$1" >&2
  exit 70
}

run_git() {
  (
    exec 8>&- 9>&-
    set +e
    "$git_command" "$@" 7>&- 8>&- 9>&-
    git_status=$?
    exit "$git_status"
  )
}

validate_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid session id: $1"
}

case "${1-}" in
--help | -h)
  printf '%s\n' "$usage_text"
  exit 0
  ;;
esac

ensure_directory() {
  local path=$1 managed=$2
  if mkdir -m 700 -- "$path" 2>/dev/null; then
    return
  fi
  [ ! -L "$path" ] || die "managed path is a symlink: $path"
  [ -d "$path" ] || die "managed path is not a directory: $path"
  [ "$(stat -c %u "$path")" = "$(id -u)" ] || die "managed path has another owner: $path"
  if [ "$managed" = true ]; then
    chmod 700 -- "$path"
  fi
}

validate_regular_file() {
  local path=$1
  [ ! -L "$path" ]
  [ -f "$path" ]
  [ "$(stat -c %u "$path")" = "$(id -u)" ]
  [ "$(stat -c %a "$path")" = 600 ]
}

ensure_lock_file() {
  local path=$1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    (
      umask 077
      set -o noclobber
      : >"$path"
    ) 2>/dev/null || true
  fi
  validate_regular_file "$path" || die "lock file is ambiguous: $path"
}

validate_snapshot_path() {
  local path=$1
  [[ $path == /* ]] || die "git reported a non-absolute worktree path: $path"
  [[ $path != *[$'\001'-$'\037'$'\177']* ]] || die 'git reported a worktree path with control characters'
}

snapshot_worktrees() {
  local output=$1 raw=$2 field path='' head=''
  run_git worktree list --porcelain -z >"$raw"
  : >"$output"
  while IFS= read -r -d '' field; do
    if [ -z "$field" ]; then
      if [ -n "$path" ]; then
        validate_snapshot_path "$path"
        [[ $head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "git reported an invalid worktree HEAD: $path"
        printf '%s\t%s\n' "$path" "$head" >>"$output"
      fi
      path=
      head=
      continue
    fi
    case "$field" in
    'worktree '*) path=${field#worktree } ;;
    'HEAD '*) head=${field#HEAD } ;;
    esac
  done <"$raw"
}

parse_add_target() {
  local option
  [ "${1-}" = add ] || die 'only worktree add is supported'
  shift

  while [ "$#" -gt 0 ]; do
    option=$1
    case "$option" in
    -b | -B | --reason)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for add option: $option"
      shift 2
      ;;
    --reason=*)
      [ -n "${option#--reason=}" ] || die 'missing value for add option: --reason'
      shift
      ;;
    --detach | --checkout | --no-checkout | --lock)
      shift
      ;;
    --)
      shift
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die 'ambiguous worktree add target'
      printf '%s\n' "$1"
      return
      ;;
    -*) die "unsupported or ambiguous worktree add option: $option" ;;
    *)
      [ "$#" -le 2 ] || die 'ambiguous worktree add target'
      printf '%s\n' "$1"
      return
      ;;
    esac
  done
  die 'worktree add target is missing'
}

[ "$#" -gt 0 ] || die "$usage_text"
[ -n "${HOME-}" ] || die 'HOME is unset'
[[ $HOME == /* ]] || die 'HOME is not absolute'
[ -d "$HOME" ] && [ ! -L "$HOME" ] || die 'HOME is ambiguous'
session_id=${DOTFILES_AGENT_SESSION_ID-}
validate_id "$session_id"
target_argument=$(parse_add_target "$@")
case "$target_argument" in
/*) target_candidate=$target_argument ;;
*) target_candidate=$PWD/$target_argument ;;
esac
target_candidate=$(realpath -m -- "$target_candidate") || die 'cannot resolve worktree add target'
validate_snapshot_path "$target_candidate"

state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"
ensure_directory "$HOME/.local" false
ensure_directory "$HOME/.local/state" false
ensure_directory "$HOME/.local/state/dotfiles-wsl" true
ensure_directory "$state_root" true
locks_root="$state_root/locks"
ensure_directory "$locks_root" true
# Every managed mutation takes the global lock before the session lock.
mutation_lock="$locks_root/.worktree-mutation.lock"
ensure_lock_file "$mutation_lock"
exec 7<>"$mutation_lock"
flock -x 7
creation_lock="$locks_root/$session_id.lock"
ensure_lock_file "$creation_lock"
exec 8<>"$creation_lock"
flock -x 8

DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
  "$resource_command" validate-session "$session_id"

scratch=$(mktemp -d)
before="$scratch/before"
before_raw="$scratch/before.raw"
after="$scratch/after"
after_raw="$scratch/after.raw"

# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup_scratch() {
  local status=$?
  trap - EXIT
  rm -f -- "$before" "$before_raw" "$after" "$after_raw" || true
  rmdir -- "$scratch" 2>/dev/null || true
  exit "$status"
}
trap cleanup_scratch EXIT

snapshot_worktrees "$before" "$before_raw"
if cut -f 1 "$before" | grep -Fxq -- "$target_candidate"; then
  die 'worktree add target already exists in the linked-worktree roster'
fi
common_dir=$(run_git rev-parse --path-format=absolute --git-common-dir)
common_dir=$(realpath -e -- "$common_dir") || die 'cannot canonicalize git common dir'

run_git worktree "$@"
snapshot_worktrees "$after" "$after_raw" || die 'cannot snapshot worktrees after git worktree add'
target_path=$(realpath -e -- "$target_argument") ||
  die 'git reported success but the add target is ambiguous'
[ "$target_path" = "$target_candidate" ] ||
  die 'git created a worktree at an unexpected canonical path'

target_rows=0
target_head=
while IFS=$'\t' read -r path initial_head; do
  [ "$path" = "$target_path" ] || continue
  target_rows=$((target_rows + 1))
  target_head=$initial_head
done <"$after"
[ "$target_rows" -eq 1 ] || die 'git add target is missing or ambiguous in the linked-worktree roster'

DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
  "$resource_command" register-worktree "$session_id" "$common_dir" "$target_path" "$target_head" ||
  die 'git created the requested worktree but ownership registration failed'
