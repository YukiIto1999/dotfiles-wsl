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

zero_oid_for_git_context() {
  local context_type=$1 context=$2 object_format
  local -a git_context
  case "$context_type" in
  worktree) git_context=(-C "$context") ;;
  git-dir) git_context=(--git-dir="$context") ;;
  *) return 1 ;;
  esac
  object_format=$(run_git "${git_context[@]}" rev-parse --show-object-format=storage 2>/dev/null) ||
    return 1
  case "$object_format" in
  sha1) printf '%040d\n' 0 ;;
  sha256) printf '%064d\n' 0 ;;
  *) return 1 ;;
  esac
}

unborn_zero_oid_for_git_context() {
  local context_type=$1 context=$2 head_ref ref_status zero_oid
  local -a git_context
  case "$context_type" in
  worktree) git_context=(-C "$context") ;;
  git-dir) git_context=(--git-dir="$context") ;;
  *) return 1 ;;
  esac
  if run_git "${git_context[@]}" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    return 1
  fi
  head_ref=$(run_git "${git_context[@]}" symbolic-ref -q HEAD 2>/dev/null) || return 1
  case "$head_ref" in
  refs/heads/*) ;;
  *) return 1 ;;
  esac
  run_git "${git_context[@]}" check-ref-format "$head_ref" >/dev/null 2>&1 || return 1
  if run_git "${git_context[@]}" show-ref --exists "$head_ref" >/dev/null 2>&1; then
    return 1
  else
    ref_status=$?
  fi
  [ "$ref_status" -eq 2 ] || return 1
  zero_oid=$(zero_oid_for_git_context "$context_type" "$context") || return 1
  printf '%s\n' "$zero_oid"
}

resolve_git_context_head_identity() {
  local context_type=$1 context=$2 current_head
  local -a git_context
  case "$context_type" in
  worktree) git_context=(-C "$context") ;;
  git-dir) git_context=(--git-dir="$context") ;;
  *) return 1 ;;
  esac
  if current_head=$(run_git "${git_context[@]}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
    [[ $current_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
    printf '%s\n' "$current_head"
    return
  fi
  unborn_zero_oid_for_git_context "$context_type" "$context"
}

snapshot_worktrees() {
  local output=$1 raw=$2 field path='' head=''
  local resolved_head
  run_git worktree list --porcelain -z >"$raw"
  : >"$output"
  while IFS= read -r -d '' field; do
    if [ -z "$field" ]; then
      if [ -n "$path" ]; then
        validate_snapshot_path "$path"
        [[ $head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "git reported an invalid worktree HEAD: $path"
        if [[ $head =~ ^(0{40}|0{64})$ ]]; then
          resolved_head=$(resolve_git_context_head_identity worktree "$path") ||
            die "git reported an unproven unborn worktree HEAD: $path"
          [ "$resolved_head" = "$head" ] ||
            die "git reported a mismatched unborn worktree HEAD: $path"
        fi
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

parse_add_arguments() {
  local option
  target_argument=
  requested_head_argument=
  requested_head_is_explicit=false
  explicit_branch_mode=false
  explicit_branch_argument=
  detach_mode=false
  no_checkout_mode=false
  [ "${1-}" = add ] || die 'only worktree add is supported'
  shift

  while [ "$#" -gt 0 ]; do
    option=$1
    case "$option" in
    -b | -B)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for add option: $option"
      explicit_branch_mode=true
      explicit_branch_argument=$2
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for add option: $option"
      shift 2
      ;;
    --reason=*)
      [ -n "${option#--reason=}" ] || die 'missing value for add option: --reason'
      shift
      ;;
    --detach)
      detach_mode=true
      shift
      ;;
    --checkout)
      no_checkout_mode=false
      shift
      ;;
    --no-checkout)
      no_checkout_mode=true
      shift
      ;;
    --lock)
      shift
      ;;
    --)
      shift
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die 'ambiguous worktree add target'
      target_argument=$1
      if [ "$#" -eq 2 ]; then
        requested_head_argument=$2
        requested_head_is_explicit=true
      fi
      return
      ;;
    -*) die "unsupported or ambiguous worktree add option: $option" ;;
    *)
      [ "$#" -le 2 ] || die 'ambiguous worktree add target'
      target_argument=$1
      if [ "$#" -eq 2 ]; then
        requested_head_argument=$2
        requested_head_is_explicit=true
      fi
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
parse_add_arguments "$@"
if [ "$requested_head_is_explicit" = true ]; then
  [ -n "$requested_head_argument" ] || die 'requested worktree HEAD is empty'
  [[ $requested_head_argument != *[$'\001'-$'\037'$'\177']* ]] ||
    die 'requested worktree HEAD contains control characters'
fi
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

# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup_scratch() {
  local status=$?
  trap - EXIT
  rm -f -- "$before" "$before_raw" "$after" "$after_raw" || true
  rmdir -- "$scratch" 2>/dev/null || true
  exit "$status"
}

select_matching_remote_ref() {
  local branch_name=$1 candidate_ref default_remote remote_ref remote_ref_output config_status
  local -a remote_refs=()
  if remote_ref_output=$(run_git for-each-ref --format='%(refname)' \
    "refs/remotes/*/$branch_name"); then
    :
  else
    # Status 1 is reserved by this helper for a successful scan with no match.
    return 2
  fi
  if [ -n "$remote_ref_output" ]; then
    mapfile -t remote_refs <<<"$remote_ref_output"
  fi
  if [ "${#remote_refs[@]}" -eq 1 ]; then
    printf '%s\n' "${remote_refs[0]}"
    return
  fi
  if [ "${#remote_refs[@]}" -gt 1 ]; then
    if default_remote=$(run_git config --get checkout.defaultRemote 2>/dev/null); then
      if [ -n "$default_remote" ]; then
        candidate_ref="refs/remotes/$default_remote/$branch_name"
        for remote_ref in "${remote_refs[@]}"; do
          if [ "$remote_ref" = "$candidate_ref" ]; then
            printf '%s\n' "$candidate_ref"
            return
          fi
        done
      fi
    else
      config_status=$?
      [ "$config_status" -eq 1 ] || return 2
    fi
  fi
  return 1
}

read_guess_remote_config() {
  local guess_remote config_status
  if guess_remote=$(run_git config --type=bool --get worktree.guessRemote 2>/dev/null); then
    printf '%s\n' "$guess_remote"
    return
  else
    config_status=$?
  fi
  if [ "$config_status" -eq 1 ]; then
    printf 'false\n'
    return
  fi
  return "$config_status"
}

select_effective_requested_head() {
  local target_basename candidate_ref guess_remote requested_head_for_prediction remote_status
  if [ "$requested_head_is_explicit" = true ]; then
    requested_head_for_prediction=$requested_head_argument
    if [ "$requested_head_for_prediction" = - ]; then
      requested_head_for_prediction='@{-1}'
    fi
    if run_git rev-parse --verify "${requested_head_for_prediction}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$requested_head_for_prediction"
      return
    fi
    if [ "$explicit_branch_mode" = false ] && [ "$detach_mode" = false ] &&
      run_git check-ref-format --branch "$requested_head_for_prediction" >/dev/null 2>&1; then
      if candidate_ref=$(select_matching_remote_ref "$requested_head_for_prediction"); then
        printf '%s\n' "$candidate_ref"
        return
      else
        remote_status=$?
        [ "$remote_status" -eq 1 ] || return "$remote_status"
      fi
    fi
    printf '%s\n' "$requested_head_for_prediction"
    return
  fi
  if [ "$explicit_branch_mode" = true ] || [ "$detach_mode" = true ]; then
    printf 'HEAD\n'
    return
  fi
  target_basename=${target_candidate##*/}
  candidate_ref="refs/heads/$target_basename"
  if ! run_git check-ref-format --branch "$target_basename" >/dev/null 2>&1; then
    printf 'HEAD\n'
    return
  fi
  if run_git show-ref --verify --quiet "$candidate_ref"; then
    printf '%s\n' "$candidate_ref"
    return
  fi
  guess_remote=$(read_guess_remote_config) || return 1
  if [ "$guess_remote" = true ]; then
    if candidate_ref=$(select_matching_remote_ref "$target_basename"); then
      printf '%s\n' "$candidate_ref"
      return
    else
      remote_status=$?
      [ "$remote_status" -eq 1 ] || return "$remote_status"
    fi
  fi
  printf 'HEAD\n'
}

can_infer_unborn_add() {
  local branch_name local_ref guess_remote remotes
  [ "$requested_head_is_explicit" = false ] || return 1
  [ "$detach_mode" = false ] || return 1
  [ "$no_checkout_mode" = false ] || return 1
  if [ "$explicit_branch_mode" = true ]; then
    branch_name=$explicit_branch_argument
  else
    branch_name=${target_candidate##*/}
  fi
  run_git check-ref-format --branch "$branch_name" >/dev/null 2>&1 || return 1
  local_ref=$(run_git for-each-ref --format='%(refname)' --count=1 refs/heads) || return 1
  [ -z "$local_ref" ] || return 1
  if [ "$explicit_branch_mode" = true ]; then
    return 0
  fi
  guess_remote=$(read_guess_remote_config) || return 1
  if [ "$guess_remote" = true ]; then
    remotes=$(run_git remote) || return 1
    [ -z "$remotes" ] || return 1
  fi
}

add_transaction() {
  local common_dir effective_requested_head resolved_initial_head roster_fingerprint
  local parent_path parent_identity parent_device parent_inode
  local target_path target_rows target_head path initial_head transaction_status
  scratch=$(mktemp -d)
  before="$scratch/before"
  before_raw="$scratch/before.raw"
  after="$scratch/after"
  after_raw="$scratch/after.raw"
  trap cleanup_scratch EXIT

  DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
    "$resource_command" validate-session "$session_id"
  snapshot_worktrees "$before" "$before_raw"
  if cut -f 1 "$before" | grep -Fxq -- "$target_candidate"; then
    die 'worktree add target already exists in the linked-worktree roster'
  fi
  [ ! -e "$target_candidate" ] && [ ! -L "$target_candidate" ] ||
    die 'worktree add target already exists'
  common_dir=$(run_git rev-parse --path-format=absolute --git-common-dir)
  common_dir=$(realpath -e -- "$common_dir") || die 'cannot canonicalize git common dir'
  effective_requested_head=$(select_effective_requested_head)
  if resolved_initial_head=$(run_git rev-parse --verify "${effective_requested_head}^{commit}"); then
    :
  else
    transaction_status=$?
    if [ "$effective_requested_head" = HEAD ] && can_infer_unborn_add &&
      resolved_initial_head=$(unborn_zero_oid_for_git_context worktree .); then
      :
    else
      return "$transaction_status"
    fi
  fi
  [[ $resolved_initial_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] ||
    die 'git resolved an invalid worktree HEAD'
  roster_fingerprint=$(sha256sum "$before_raw" | cut -d ' ' -f 1)
  parent_path=$(dirname -- "$target_candidate")
  [ -d "$parent_path" ] && [ ! -L "$parent_path" ] || die 'worktree parent is ambiguous'
  [ "$(realpath -e -- "$parent_path")" = "$parent_path" ] ||
    die 'worktree parent is not canonical'
  parent_identity=$(stat -c '%d:%i' -- "$parent_path") || die 'cannot inspect worktree parent'
  parent_device=${parent_identity%%:*}
  parent_inode=${parent_identity#*:}

  DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
    "$resource_command" begin-worktree-add "$session_id" "$common_dir" "$target_candidate" \
    "$resolved_initial_head" "$effective_requested_head" "$roster_fingerprint" \
    "$parent_device" "$parent_inode"

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
  [ "$target_head" = "$resolved_initial_head" ] || die 'git add target HEAD differs from requested commit'

  DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
    "$resource_command" record-worktree-add-identity "$session_id" "$common_dir" \
    "$target_path" "$target_head" ||
    die 'git created the requested worktree but stable identity registration failed'
  DOTFILES_AGENT_MUTATION_LOCK_FD=7 DOTFILES_AGENT_CREATION_LOCK_FD=8 \
    "$resource_command" complete-worktree-add "$session_id" "$common_dir" \
    "$target_path" "$target_head" ||
    die 'git created the requested worktree but ownership publication failed'

  transaction_status=0
  return "$transaction_status"
}

set +e
(
  set -e
  add_transaction "$@"
  guardian_status=$?
  exit "$guardian_status"
)
guardian_status=$?
set -e
exit "$guardian_status"
