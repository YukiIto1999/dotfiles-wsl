set -euo pipefail
shopt -s nullglob

program=dotfiles-agent-resource
usage_text="usage: $program begin-session SESSION | validate-session SESSION | cleanup-session SESSION | begin-worktree-add SESSION COMMON-DIR PATH INITIAL-HEAD REQUESTED-HEAD ROSTER-FINGERPRINT PARENT-DEVICE PARENT-INODE | record-worktree-add-identity SESSION COMMON-DIR PATH INITIAL-HEAD | complete-worktree-add SESSION COMMON-DIR PATH INITIAL-HEAD | register-worktree SESSION COMMON-DIR PATH INITIAL-HEAD | reap"
git_command=@gitCommand@
quarantine_transaction_record=

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

validate_id() {
  local label=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid $label: $value"
}

validate_absolute_path() {
  local label=$1 value=$2
  [[ $value == /* ]] || die "$label is not absolute: $value"
  [[ $value != *[$'\001'-$'\037'$'\177']* ]] || die "$label contains control characters"
}

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
  [ ! -L "$path" ] || return 1
  [ -f "$path" ] || return 1
  [ "$(stat -c %u "$path")" = "$(id -u)" ] || return 1
  [ "$(stat -c %a "$path")" = 600 ] || return 1
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

acquire_mutation_lock() {
  local inherited_target
  if [ "${DOTFILES_AGENT_CREATION_LOCK_FD-}" = 8 ] &&
    [ "${DOTFILES_AGENT_MUTATION_LOCK_FD-}" != 7 ]; then
    die 'inherited creation lock requires the managed mutation lock'
  fi
  ensure_lock_file "$mutation_lock_file"

  if [ "${DOTFILES_AGENT_MUTATION_LOCK_FD-}" = 7 ]; then
    inherited_target=$(readlink -e -- /proc/self/fd/7 2>/dev/null) ||
      die 'inherited mutation lock descriptor is ambiguous'
    [ "$inherited_target" = "$mutation_lock_file" ] ||
      die 'inherited mutation lock does not match the managed lock'
  else
    exec 7<>"$mutation_lock_file"
  fi
  flock -x 7
}

acquire_creation_lock() {
  local session_id=$1 expected_lock inherited_target
  validate_id session "$session_id"
  expected_lock="$locks_root/$session_id.lock"
  ensure_lock_file "$expected_lock"

  if [ "${DOTFILES_AGENT_CREATION_LOCK_FD-}" = 8 ]; then
    inherited_target=$(readlink -e -- /proc/self/fd/8 2>/dev/null) ||
      die 'inherited creation lock descriptor is ambiguous'
    [ "$inherited_target" = "$expected_lock" ] ||
      die 'inherited creation lock does not match the session'
  else
    exec 8<>"$expected_lock"
  fi
  flock -x 8
}

acquire_ledger_lock() {
  ensure_lock_file "$lock_file"
  exec 9<>"$lock_file"
  flock -x 9
}

release_locks() {
  exec 9>&-
  exec 8>&-
}

atomic_write() {
  local target=$1 json=$2 directory temporary
  directory=${target%/*}
  if [ -e "$target" ] || [ -L "$target" ]; then
    validate_regular_file "$target" || die "ledger file is ambiguous: $target"
  fi
  temporary=$(mktemp "$directory/.ledger.XXXXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$json" >"$temporary"
  jq --exit-status . "$temporary" >/dev/null || die "refusing invalid ledger JSON"
  mv -T -- "$temporary" "$target"
}

session_schema_is_valid() {
  local path=$1
  jq --exit-status '
    type == "object"
    and (
      keys == ["boot_id", "client", "owner_pid", "owner_start_time", "reason", "session_id", "status", "version"]
      or keys == ["boot_id", "client", "owner_pid", "owner_start_time", "reason", "session_id", "status", "updated_at", "version"]
    )
    and .version == 1
    and (.session_id | type == "string")
    and (.client | type == "string")
    and (.boot_id | type == "string")
    and (.owner_pid | type == "number" and . > 0 and floor == .)
    and (.owner_start_time | type == "string" and test("^[0-9]+$"))
    and (.status == "active" or .status == "ended")
    and (.reason | type == "string" and length > 0)
    and ((has("updated_at") | not) or (.updated_at | type == "number" and . >= 0 and floor == .))
  ' "$path" >/dev/null
}

worktree_schema_is_valid() {
  local path=$1
  jq --exit-status '
    type == "object"
    and (
      (
        .status == "adding"
        and (
          keys == ["common_dir", "initial_head", "last_reason", "parent_device", "parent_inode", "path", "requested_head", "roster_fingerprint", "session_id", "status", "updated_at", "version"]
          or keys == ["common_dir", "git_dir", "initial_head", "last_reason", "parent_device", "parent_inode", "path", "requested_head", "roster_fingerprint", "session_id", "status", "updated_at", "version", "worktree_device", "worktree_inode"]
        )
      )
      or (
        (.status == "quarantining" or .status == "removing")
        and keys == ["common_dir", "git_dir", "initial_head", "last_reason", "path", "quarantine_path", "session_id", "status", "updated_at", "version", "worktree_device", "worktree_inode"]
      )
      or (
        .status == "owned"
        and keys == ["common_dir", "git_dir", "initial_head", "last_reason", "path", "session_id", "status", "updated_at", "version", "worktree_device", "worktree_inode"]
      )
      or (
        (.status != "quarantining" and .status != "removing")
        and (
          keys == ["common_dir", "initial_head", "last_reason", "path", "session_id", "status", "version"]
          or keys == ["common_dir", "initial_head", "last_reason", "path", "session_id", "status", "updated_at", "version"]
        )
      )
    )
    and .version == 1
    and (.session_id | type == "string")
    and (.common_dir | type == "string" and startswith("/"))
    and (.path | type == "string" and startswith("/"))
    and ((.status != "adding") or (
      (.requested_head | type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not))
      and (.roster_fingerprint | type == "string" and test("^[0-9a-f]{64}$"))
      and (.parent_device | type == "string" and test("^[0-9]+$"))
      and (.parent_inode | type == "string" and test("^[0-9]+$"))
    ))
    and (((.status != "quarantining") and (.status != "removing")) or (.quarantine_path | type == "string" and startswith("/")))
    and ((has("git_dir") | not) or (.git_dir | type == "string" and startswith("/")))
    and ((has("worktree_device") | not) or (.worktree_device | type == "string" and test("^[0-9]+$")))
    and ((has("worktree_inode") | not) or (.worktree_inode | type == "string" and test("^[0-9]+$")))
    and (.initial_head | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
    and (.status == "adding" or .status == "owned" or .status == "quarantining" or .status == "removing" or .status == "preserved" or .status == "removed")
    and (.last_reason | type == "string" and length > 0)
    and ((has("updated_at") | not) or (.updated_at | type == "number" and . >= 0 and floor == .))
  ' "$path" >/dev/null
}

preflight_ledgers() {
  local entry name session_id session_file common_dir path expected_id

  for entry in "$sessions_root"/* "$worktrees_root"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
    *.json) ;;
    *)
      printf '%s: preserve unexpected-ledger: %s\n' "$program" "$entry" >&2
      return 1
      ;;
    esac
    if [ -L "$entry" ]; then
      printf '%s: preserve symlink-ledger: %s\n' "$program" "$entry" >&2
      return 1
    fi
    if ! validate_regular_file "$entry"; then
      printf '%s: preserve ambiguous-ledger: %s\n' "$program" "$entry" >&2
      return 1
    fi
    case "$entry" in
    "$sessions_root"/*)
      if ! session_schema_is_valid "$entry"; then
        printf '%s: preserve malformed-ledger: %s\n' "$program" "$entry" >&2
        return 1
      fi
      session_id=$(jq -r '.session_id' "$entry")
      if [ "$name" != "$session_id.json" ]; then
        printf '%s: preserve malformed-ledger: %s\n' "$program" "$entry" >&2
        return 1
      fi
      ;;
    "$worktrees_root"/*)
      if ! worktree_schema_is_valid "$entry"; then
        printf '%s: preserve malformed-ledger: %s\n' "$program" "$entry" >&2
        return 1
      fi
      session_id=$(jq -r '.session_id' "$entry")
      if ! [[ $session_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        printf '%s: preserve malformed-ledger: %s\n' "$program" "$entry" >&2
        return 1
      fi
      common_dir=$(jq -r '.common_dir' "$entry")
      path=$(jq -r '.path' "$entry")
      expected_id=$(printf '%s\0%s' "$common_dir" "$path" | sha256sum | cut -d ' ' -f 1)
      if [ "$name" != "$expected_id.json" ]; then
        printf '%s: preserve malformed-ledger: %s\n' "$program" "$entry" >&2
        return 1
      fi
      session_file="$sessions_root/$session_id.json"
      if [ ! -f "$session_file" ] || [ -L "$session_file" ]; then
        printf '%s: preserve missing-session: %s\n' "$program" "$entry" >&2
        return 1
      fi
      ;;
    esac
  done
}

process_start_time() {
  local pid=$1 process_stat
  process_stat=$(<"/proc/$pid/stat") || return 1
  awk '{print $20}' <<<"${process_stat##*) }"
}

orphan_reason() {
  local session_file=$1 recorded_boot owner_pid recorded_start current_start
  recorded_boot=$(jq -r '.boot_id' "$session_file")
  owner_pid=$(jq -r '.owner_pid' "$session_file")
  recorded_start=$(jq -r '.owner_start_time' "$session_file")

  if [ "$recorded_boot" != "$current_boot_id" ]; then
    printf 'orphan-boot-mismatch\n'
    return 0
  fi
  if [ ! -r "/proc/$owner_pid/stat" ]; then
    printf 'orphan-dead\n'
    return 0
  fi
  if ! current_start=$(process_start_time "$owner_pid"); then
    printf 'orphan-dead\n'
    return 0
  fi
  if [ "$current_start" != "$recorded_start" ]; then
    printf 'orphan-owner-mismatch\n'
    return 0
  fi
  return 1
}

mark_session() {
  local session_file=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    '.status = "ended" | .reason = $reason | .updated_at = $now' "$session_file")
  atomic_write "$session_file" "$updated"
}

mark_worktree() {
  local record=$1 status=$2 reason=$3 updated now
  now=$(date +%s)
  updated=$(jq -c --arg status "$status" --arg reason "$reason" --argjson now "$now" \
    'del(.git_dir, .quarantine_path, .worktree_device, .worktree_inode) |
      .status = $status | .last_reason = $reason | .updated_at = $now' \
    "$record")
  atomic_write "$record" "$updated"
}

mark_worktree_quarantining() {
  local record=$1 quarantine_path=$2 git_dir=$3 worktree_device=$4 worktree_inode=$5
  local updated now
  now=$(date +%s)
  updated=$(jq -c --arg quarantine_path "$quarantine_path" --arg git_dir "$git_dir" \
    --arg worktree_device "$worktree_device" --arg worktree_inode "$worktree_inode" \
    --argjson now "$now" \
    '.status = "quarantining" | .quarantine_path = $quarantine_path | .git_dir = $git_dir |
      .worktree_device = $worktree_device | .worktree_inode = $worktree_inode |
      .last_reason = "quarantining" | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

mark_worktree_recovered_owned() {
  local record=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    'del(.quarantine_path) |
      .status = "owned" | .last_reason = $reason | .updated_at = $now' \
    "$record")
  atomic_write "$record" "$updated"
}

mark_adding_reason() {
  local record=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    '.status = "adding" | .last_reason = $reason | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

mark_adding_owned() {
  local record=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    'del(.requested_head, .roster_fingerprint, .parent_device, .parent_inode) |
      .status = "owned" | .last_reason = $reason | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

mark_quarantining_reason() {
  local record=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    '.status = "quarantining" | .last_reason = $reason | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

mark_worktree_removing() {
  local record=$1 updated now
  now=$(date +%s)
  updated=$(jq -c --argjson now "$now" \
    '.status = "removing" | .last_reason = "removing" | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

mark_removing_reason() {
  local record=$1 reason=$2 updated now
  now=$(date +%s)
  updated=$(jq -c --arg reason "$reason" --argjson now "$now" \
    '.status = "removing" | .last_reason = $reason | .updated_at = $now' "$record")
  atomic_write "$record" "$updated"
}

preserve_worktree() {
  local record=$1 reason=$2 path
  path=$(jq -r '.path' "$record")
  mark_worktree "$record" preserved "$reason"
  printf '%s: preserve %s: %s\n' "$program" "$reason" "$path" >&2
}

proc_reference_reason() {
  local reference=$1 path=$2 reason=$3 raw final_raw canonical=
  raw=$(readlink -- "$reference" 2>/dev/null) || {
    printf '%s: cannot inspect process reference: %s\n' "$program" "$reference" >&2
    return 2
  }
  if [ "$raw" = "$path" ] || [[ $raw == "$path/"* ]]; then
    printf '%s\n' "$reason"
    return 0
  fi
  canonical=$(readlink -e -- "$reference" 2>/dev/null) || true
  final_raw=$(readlink -- "$reference" 2>/dev/null) || {
    printf '%s: process reference changed during inspection: %s\n' \
      "$program" "$reference" >&2
    return 2
  }
  if [ "$final_raw" != "$raw" ]; then
    printf '%s: process reference changed during inspection: %s\n' \
      "$program" "$reference" >&2
    return 2
  fi
  case "$raw" in
  pipe:* | socket:* | anon_inode:* | /memfd:* | /dev/*) return 1 ;;
  esac
  if [ -z "$canonical" ]; then
    printf '%s: cannot canonicalize process reference: %s -> %s\n' \
      "$program" "$reference" "$raw" >&2
    return 2
  fi
  if [ "$canonical" = "$path" ] || [[ $canonical == "$path/"* ]]; then
    printf '%s\n' "$reason"
    return 0
  fi
  return 1
}

process_reference_reason() {
  local path=$1 process_dir process_owner process_stat process_fields process_state process_start final_start
  local reference reason reference_status
  local -a process_dirs fd_references
  process_dirs=(/proc/[0-9]*)

  for process_dir in "${process_dirs[@]}"; do
    process_owner=$(stat -c %u -- "$process_dir" 2>/dev/null) || {
      printf '%s: cannot inspect process owner: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    }
    if [ "$process_owner" != "$resource_owner_uid" ]; then
      continue
    fi
    if [ ! -d "$process_dir" ] || [ ! -r "$process_dir/stat" ]; then
      printf '%s: cannot inspect process: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    fi
    process_stat=$(<"$process_dir/stat") || {
      printf '%s: process changed during inspection: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    }
    process_fields=${process_stat##*) }
    process_state=$(awk '{print $1}' <<<"$process_fields") || {
      printf '%s: process state is ambiguous: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    }
    process_start=$(awk '{print $20}' <<<"$process_fields") || {
      printf '%s: process identity is ambiguous: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    }
    if [ "$process_state" != Z ]; then
      for reference in "$process_dir/cwd:active-cwd" "$process_dir/exe:active-exe"; do
        reason=${reference##*:}
        reference=${reference%:*}
        if reason=$(proc_reference_reason "$reference" "$path" "$reason"); then
          printf '%s\n' "$reason"
          return 0
        else
          reference_status=$?
          if [ "$reference_status" -eq 2 ]; then
            printf 'ambiguous-process-reference\n'
            return 0
          fi
        fi
      done
      if [ ! -d "$process_dir/fd" ] || [ ! -r "$process_dir/fd" ] ||
        [ ! -x "$process_dir/fd" ]; then
        printf '%s: cannot enumerate process descriptors: %s\n' "$program" "$process_dir" >&2
        printf 'ambiguous-process-reference\n'
        return 0
      fi
      fd_references=("$process_dir"/fd/*)
      for reference in "${fd_references[@]}"; do
        if reason=$(proc_reference_reason "$reference" "$path" active-fd); then
          printf '%s\n' "$reason"
          return 0
        else
          reference_status=$?
          if [ "$reference_status" -eq 2 ]; then
            printf 'ambiguous-process-reference\n'
            return 0
          fi
        fi
      done
    fi
    final_start=$(process_start_time "${process_dir##*/}") || {
      printf '%s: process changed during inspection: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    }
    if [ "$final_start" != "$process_start" ]; then
      printf '%s: process identity changed during inspection: %s\n' "$program" "$process_dir" >&2
      printf 'ambiguous-process-reference\n'
      return 0
    fi
  done
  return 1
}

quarantine_root_for_worktree() {
  local original_path=$1 quarantine_path=$2 parent_path quarantine_root quarantine_name
  [ "${quarantine_path##*/}" = worktree ] || return 1
  parent_path=$(dirname -- "$original_path")
  quarantine_root=${quarantine_path%/worktree}
  [ "${quarantine_root%/*}" = "$parent_path" ] || return 1
  quarantine_name=${quarantine_root##*/}
  [[ $quarantine_name =~ ^[.]dotfiles-agent-quarantine[.][A-Za-z0-9]+$ ]] || return 1
  printf '%s\n' "$quarantine_root"
}

original_parent_is_valid() {
  local original_path=$1 parent_path canonical_parent
  parent_path=$(dirname -- "$original_path")
  [ ! -L "$parent_path" ] || return 1
  [ -d "$parent_path" ] || return 1
  [ "$(stat -c %u -- "$parent_path" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
  canonical_parent=$(realpath -e -- "$parent_path" 2>/dev/null) || return 1
  [ "$canonical_parent" = "$parent_path" ]
}

quarantine_root_is_valid() {
  local original_path=$1 quarantine_path=$2 quarantine_root parent_path
  quarantine_root=$(quarantine_root_for_worktree "$original_path" "$quarantine_path") || return 1
  parent_path=$(dirname -- "$original_path")
  original_parent_is_valid "$original_path" || return 1
  [ ! -L "$quarantine_root" ] || return 1
  [ -d "$quarantine_root" ] || return 1
  [ "$(stat -c %u -- "$quarantine_root" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
  [ "$(stat -c %a -- "$quarantine_root" 2>/dev/null)" = 700 ] || return 1
  [ "$(realpath -e -- "$quarantine_root" 2>/dev/null)" = "$quarantine_root" ] || return 1
  [ "$(stat -c %d -- "$quarantine_root" 2>/dev/null)" = \
    "$(stat -c %d -- "$parent_path" 2>/dev/null)" ]
}

worktree_directory_identity_is_valid() {
  local path=$1 expected_device=$2 expected_inode=$3 actual_identity
  [ ! -L "$path" ] || return 1
  [ -d "$path" ] || return 1
  actual_identity=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || return 1
  [ "$actual_identity" = "$expected_device:$expected_inode" ]
}

worktree_link_identity_is_valid() {
  local path=$1 common_dir=$2 expected_git_dir=$3 expected_device=$4 expected_inode=$5
  local canonical_path canonical_common git_dir current_common
  worktree_directory_identity_is_valid "$path" "$expected_device" "$expected_inode" || return 1
  [ "$(stat -c %u -- "$path" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
  canonical_path=$(realpath -e -- "$path" 2>/dev/null) || return 1
  [ "$canonical_path" = "$path" ] || return 1
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || return 1
  [ "$canonical_common" = "$common_dir" ] || return 1
  git_dir=$(run_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  git_dir=$(realpath -e -- "$git_dir" 2>/dev/null) || return 1
  [ "$git_dir" = "$expected_git_dir" ] || return 1
  current_common=$(run_git -C "$path" rev-parse \
    --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  current_common=$(realpath -e -- "$current_common" 2>/dev/null) || return 1
  [ "$current_common" = "$common_dir" ] || return 1
}

worktree_identity_is_valid() {
  local path=$1 common_dir=$2 initial_head=$3 expected_git_dir=$4 expected_device=$5 expected_inode=$6
  local current_head
  worktree_link_identity_is_valid "$path" "$common_dir" "$expected_git_dir" \
    "$expected_device" "$expected_inode" || return 1
  current_head=$(resolve_git_context_head_identity worktree "$path") || return 1
  [ "$current_head" = "$initial_head" ]
}

remove_empty_transaction_root() {
  local original_path=$1 quarantine_path=$2 quarantine_root
  quarantine_root=$(quarantine_root_for_worktree "$original_path" "$quarantine_path") || return 1
  if [ ! -e "$quarantine_root" ] && [ ! -L "$quarantine_root" ]; then
    return 0
  fi
  quarantine_root_is_valid "$original_path" "$quarantine_path" || return 1
  rmdir -- "$quarantine_root" 2>/dev/null
}

git_admin_entry_is_absent() {
  local common_dir=$1 git_dir=$2 canonical_common admin_root entry_name
  [ ! -L "$common_dir" ] || return 1
  [ -d "$common_dir" ] || return 1
  [ "$(stat -c %u -- "$common_dir" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || return 1
  [ "$canonical_common" = "$common_dir" ] || return 1
  admin_root="$common_dir/worktrees"
  case "$git_dir" in
  "$admin_root"/*) ;;
  *) return 1 ;;
  esac
  entry_name=${git_dir#"$admin_root/"}
  [ -n "$entry_name" ] && [[ $entry_name != */* ]] || return 1
  [[ $entry_name != *[$'\001'-$'\037'$'\177']* ]] || return 1
  [ ! -e "$git_dir" ] && [ ! -L "$git_dir" ] || return 1
  if [ -e "$admin_root" ] || [ -L "$admin_root" ]; then
    [ ! -L "$admin_root" ] || return 1
    [ -d "$admin_root" ] || return 1
    [ "$(stat -c %u -- "$admin_root" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
    [ "$(realpath -e -- "$admin_root" 2>/dev/null)" = "$admin_root" ] || return 1
  fi
}

complete_removing_transaction() {
  local record=$1 original_path=$2 quarantine_path=$3 common_dir=$4 git_dir=$5
  if ! git_admin_entry_is_absent "$common_dir" "$git_dir"; then
    mark_removing_reason "$record" removing-admin-present
    printf '%s: preserve removing-admin-present: %s (admin: %s)\n' \
      "$program" "$original_path" "$git_dir" >&2
    return 1
  fi
  if ! remove_empty_transaction_root "$original_path" "$quarantine_path"; then
    mark_removing_reason "$record" removing-root-unresolved
    printf '%s: preserve removing-root-unresolved: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  mark_worktree "$record" removed clean-unchanged-inactive
  printf '%s: completed managed worktree removal: %s\n' "$program" "$original_path" >&2
}

current_worktree_roster_fingerprint() {
  local common_dir=$1
  run_git --git-dir="$common_dir" worktree list --porcelain -z |
    sha256sum | cut -d ' ' -f 1
}

recover_adding_worktree() {
  local record=$1 path common_dir initial_head expected_roster current_roster
  local expected_git_dir expected_device expected_inode
  path=$(jq -r '.path' "$record") || return 1
  common_dir=$(jq -r '.common_dir' "$record") || return 1
  initial_head=$(jq -r '.initial_head' "$record") || return 1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    expected_roster=$(jq -r '.roster_fingerprint' "$record") || return 1
    if current_roster=$(current_worktree_roster_fingerprint "$common_dir") &&
      [ "$current_roster" = "$expected_roster" ]; then
      rm -f -- "$record"
      printf '%s: aborted incomplete worktree add: %s\n' "$program" "$path" >&2
      return 0
    fi
    mark_adding_reason "$record" adding-absent-roster-changed
    printf '%s: preserve adding-absent-roster-changed: %s\n' "$program" "$path" >&2
    return 1
  fi
  if ! jq --exit-status \
    'has("git_dir") and has("worktree_device") and has("worktree_inode")' \
    "$record" >/dev/null; then
    mark_adding_reason "$record" adding-target-unproven
    printf '%s: preserve adding-target-unproven: %s\n' "$program" "$path" >&2
    return 1
  fi
  expected_git_dir=$(jq -r '.git_dir' "$record") || return 1
  expected_device=$(jq -r '.worktree_device' "$record") || return 1
  expected_inode=$(jq -r '.worktree_inode' "$record") || return 1
  if ! worktree_identity_is_valid "$path" "$common_dir" "$initial_head" \
    "$expected_git_dir" "$expected_device" "$expected_inode"; then
    mark_adding_reason "$record" adding-target-ambiguous
    printf '%s: preserve adding-target-ambiguous: %s\n' "$program" "$path" >&2
    return 1
  fi
  mark_adding_owned "$record" adding-recovered
  printf '%s: recovered managed worktree add: %s\n' "$program" "$path" >&2
}

recover_removing_worktree() {
  local record=$1 original_path quarantine_path common_dir initial_head git_dir
  local worktree_device worktree_inode status_output process_reason
  original_path=$(jq -r '.path' "$record") || return 1
  quarantine_path=$(jq -r '.quarantine_path' "$record") || return 1
  common_dir=$(jq -r '.common_dir' "$record") || return 1
  initial_head=$(jq -r '.initial_head' "$record") || return 1
  git_dir=$(jq -r '.git_dir' "$record") || return 1
  worktree_device=$(jq -r '.worktree_device' "$record") || return 1
  worktree_inode=$(jq -r '.worktree_inode' "$record") || return 1
  if [ -e "$original_path" ] || [ -L "$original_path" ]; then
    mark_removing_reason "$record" removing-original-present
    printf '%s: preserve removing-original-present: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if [ ! -e "$quarantine_path" ] && [ ! -L "$quarantine_path" ]; then
    complete_removing_transaction "$record" "$original_path" "$quarantine_path" \
      "$common_dir" "$git_dir"
    return
  fi
  if ! quarantine_root_is_valid "$original_path" "$quarantine_path" ||
    ! worktree_identity_is_valid "$quarantine_path" "$common_dir" "$initial_head" \
      "$git_dir" "$worktree_device" "$worktree_inode"; then
    mark_removing_reason "$record" removing-quarantine-ambiguous
    printf '%s: preserve removing-quarantine-ambiguous: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  status_output=$(run_git -C "$quarantine_path" status \
    --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    mark_removing_reason "$record" removing-status-failed
    printf '%s: preserve removing-status-failed: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  }
  if [ -n "$status_output" ]; then
    mark_removing_reason "$record" removing-dirty
    printf '%s: preserve removing-dirty: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if process_reason=$(process_reference_reason "$quarantine_path"); then
    mark_removing_reason "$record" "removing-$process_reason"
    printf '%s: preserve removing-%s: %s (quarantine: %s)\n' \
      "$program" "$process_reason" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if ! worktree_identity_is_valid "$quarantine_path" "$common_dir" "$initial_head" \
    "$git_dir" "$worktree_device" "$worktree_inode"; then
    mark_removing_reason "$record" removing-quarantine-ambiguous
    printf '%s: preserve removing-quarantine-ambiguous: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  mark_worktree_removing "$record"
  if ! run_git --git-dir="$common_dir" worktree remove -- "$quarantine_path"; then
    mark_removing_reason "$record" removing-remove-failed
    printf '%s: preserve removing-remove-failed: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  complete_removing_transaction "$record" "$original_path" "$quarantine_path" \
    "$common_dir" "$git_dir"
}

recover_quarantining_worktree() {
  local record=$1 original_path quarantine_path common_dir initial_head git_dir
  local worktree_device worktree_inode last_reason quarantine_root
  local original_present=false quarantine_present=false
  original_path=$(jq -r '.path' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  quarantine_path=$(jq -r '.quarantine_path' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  common_dir=$(jq -r '.common_dir' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  initial_head=$(jq -r '.initial_head' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  git_dir=$(jq -r '.git_dir' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  worktree_device=$(jq -r '.worktree_device' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  worktree_inode=$(jq -r '.worktree_inode' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  last_reason=$(jq -r '.last_reason' "$record") || {
    printf '%s: preserve unreadable-quarantine-ledger: %s\n' "$program" "$record" >&2
    return 1
  }
  if [ -e "$original_path" ] || [ -L "$original_path" ]; then
    original_present=true
  fi
  if [ -e "$quarantine_path" ] || [ -L "$quarantine_path" ]; then
    quarantine_present=true
  fi

  if [ "$last_reason" = quarantine-remove-root-unresolved ]; then
    if [ "$quarantine_present" = false ] &&
      remove_empty_transaction_root "$original_path" "$quarantine_path"; then
      mark_worktree "$record" removed clean-unchanged-inactive
      printf '%s: completed quarantined worktree removal: %s\n' \
        "$program" "$original_path" >&2
      return 0
    fi
    mark_quarantining_reason "$record" quarantine-remove-root-unresolved
    printf '%s: preserve quarantine-remove-root-unresolved: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if [ "$original_present" = true ] && [ "$quarantine_present" = true ]; then
    mark_quarantining_reason "$record" quarantine-both-paths
    printf '%s: preserve quarantine-both-paths: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if [ "$original_present" = true ]; then
    if ! worktree_identity_is_valid "$original_path" "$common_dir" "$initial_head" "$git_dir" \
      "$worktree_device" "$worktree_inode" ||
      ! remove_empty_transaction_root "$original_path" "$quarantine_path"; then
      mark_quarantining_reason "$record" quarantine-original-ambiguous
      printf '%s: preserve quarantine-original-ambiguous: %s (quarantine: %s)\n' \
        "$program" "$original_path" "$quarantine_path" >&2
      return 1
    fi
    mark_worktree_recovered_owned "$record" quarantine-recovered-original
    printf '%s: recovered quarantined worktree at original path: %s\n' \
      "$program" "$original_path" >&2
    return 0
  fi
  if [ "$quarantine_present" = false ]; then
    mark_quarantining_reason "$record" quarantine-both-missing
    printf '%s: preserve quarantine-both-missing: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if ! quarantine_root_is_valid "$original_path" "$quarantine_path" ||
    ! worktree_identity_is_valid "$quarantine_path" "$common_dir" "$initial_head" "$git_dir" \
      "$worktree_device" "$worktree_inode"; then
    mark_quarantining_reason "$record" quarantine-path-ambiguous
    printf '%s: preserve quarantine-path-ambiguous: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if ! run_git --git-dir="$common_dir" worktree move -- \
    "$quarantine_path" "$original_path"; then
    mark_quarantining_reason "$record" quarantine-restore-failed
    printf '%s: preserve quarantine-restore-failed: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  if ! worktree_identity_is_valid "$original_path" "$common_dir" "$initial_head" "$git_dir" \
    "$worktree_device" "$worktree_inode"; then
    mark_quarantining_reason "$record" quarantine-restored-ambiguous
    printf '%s: preserve quarantine-restored-ambiguous: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  quarantine_root=$(quarantine_root_for_worktree "$original_path" "$quarantine_path") || return 1
  if ! rmdir -- "$quarantine_root" 2>/dev/null; then
    mark_quarantining_reason "$record" quarantine-root-unresolved
    printf '%s: preserve quarantine-root-unresolved: %s (quarantine: %s)\n' \
      "$program" "$original_path" "$quarantine_path" >&2
    return 1
  fi
  mark_worktree_recovered_owned "$record" quarantine-recovered-move
  printf '%s: restored quarantined worktree: %s\n' "$program" "$original_path" >&2
}

recover_quarantine_on_exit() {
  local exit_status=$1 record=${quarantine_transaction_record-} status
  trap - EXIT TERM
  if [ -n "$record" ] && [ -f "$record" ] && [ ! -L "$record" ]; then
    status=$(jq -r '.status' "$record" 2>/dev/null) || status=
    case "$status" in
    quarantining) recover_quarantining_worktree "$record" || true ;;
    esac
  fi
  exit "$exit_status"
}

handle_transaction_term() {
  exit 143
}

finish_quarantine_transaction() {
  trap - EXIT TERM
  quarantine_transaction_record=
}

restore_quarantined_worktree() {
  local record=$1 common_dir=$2 original_path=$3 quarantine_path=$4 quarantine_root=$5 reason=$6
  local expected_git_dir expected_device expected_inode
  expected_git_dir=$(jq -r '.git_dir' "$record") || {
    printf '%s: preserve %s-unreadable-ledger: %s (quarantine: %s)\n' \
      "$program" "$reason" "$original_path" "$quarantine_path" >&2
    return
  }
  expected_device=$(jq -r '.worktree_device' "$record") || {
    printf '%s: preserve %s-unreadable-ledger: %s (quarantine: %s)\n' \
      "$program" "$reason" "$original_path" "$quarantine_path" >&2
    return
  }
  expected_inode=$(jq -r '.worktree_inode' "$record") || {
    printf '%s: preserve %s-unreadable-ledger: %s (quarantine: %s)\n' \
      "$program" "$reason" "$original_path" "$quarantine_path" >&2
    return
  }
  if ! worktree_link_identity_is_valid "$quarantine_path" "$common_dir" "$expected_git_dir" \
    "$expected_device" "$expected_inode"; then
    mark_quarantining_reason "$record" "$reason-identity-ambiguous"
    printf '%s: preserve %s-identity-ambiguous: %s (quarantine: %s)\n' \
      "$program" "$reason" "$original_path" "$quarantine_path" >&2
    return
  fi
  if [ ! -e "$original_path" ] && [ ! -L "$original_path" ] &&
    run_git --git-dir="$common_dir" worktree move -- \
      "$quarantine_path" "$original_path"; then
    if ! worktree_link_identity_is_valid "$original_path" "$common_dir" "$expected_git_dir" \
      "$expected_device" "$expected_inode"; then
      mark_quarantining_reason "$record" "$reason-restored-identity-ambiguous"
      printf '%s: preserve %s-restored-identity-ambiguous: %s (quarantine: %s)\n' \
        "$program" "$reason" "$original_path" "$quarantine_path" >&2
      return
    fi
    if ! rmdir -- "$quarantine_root" 2>/dev/null; then
      mark_quarantining_reason "$record" "$reason-quarantine-root-unresolved"
      printf '%s: preserve %s-quarantine-root-unresolved: %s (quarantine: %s)\n' \
        "$program" "$reason" "$original_path" "$quarantine_path" >&2
      return
    fi
    preserve_worktree "$record" "$reason"
    return
  fi

  mark_quarantining_reason "$record" "$reason-restore-failed"
  printf '%s: preserve %s-restore-failed: %s (quarantine: %s)\n' \
    "$program" "$reason" "$original_path" "$quarantine_path" >&2
}

cleanup_worktree_record() {
  local record=$1 path common_dir initial_head canonical_path canonical_common git_dir initial_git_dir
  local expected_git_dir expected_device expected_inode
  local current_head status_output
  local parent_path canonical_parent path_identity path_device path_inode parent_device
  local quarantine_root quarantine_path
  local process_reason recovered_identity=false
  path=$(jq -r '.path' "$record")
  common_dir=$(jq -r '.common_dir' "$record")
  initial_head=$(jq -r '.initial_head' "$record")

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    preserve_worktree "$record" missing
    return
  fi
  if jq --exit-status 'has("worktree_device")' "$record" >/dev/null; then
    recovered_identity=true
    expected_git_dir=$(jq -r '.git_dir' "$record")
    expected_device=$(jq -r '.worktree_device' "$record")
    expected_inode=$(jq -r '.worktree_inode' "$record")
    if ! worktree_link_identity_is_valid "$path" "$common_dir" "$expected_git_dir" \
      "$expected_device" "$expected_inode"; then
      preserve_worktree "$record" recovered-identity-changed
      return
    fi
  fi

  if [ -L "$path" ] || [ ! -d "$path" ]; then
    preserve_worktree "$record" ambiguous-path
    return
  fi
  canonical_path=$(realpath -e -- "$path") || {
    preserve_worktree "$record" ambiguous-path
    return
  }
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) ||
    {
      preserve_worktree "$record" missing-common-dir
      return
    }
  if [ "$canonical_path" != "$path" ] || [ "$canonical_common" != "$common_dir" ]; then
    preserve_worktree "$record" noncanonical-path
    return
  fi
  if [ "$path" = / ] || [ "$path" = "$common_dir" ] || [[ $common_dir == "$path/"* ]]; then
    preserve_worktree "$record" common-dir-protected
    return
  fi
  if [ "$(stat -c %u -- "$path")" != "$(id -u)" ]; then
    preserve_worktree "$record" nonowned-path
    return
  fi
  parent_path=$(dirname -- "$path")
  if [ -L "$parent_path" ] || [ ! -d "$parent_path" ] ||
    [ "$(stat -c %u -- "$parent_path")" != "$(id -u)" ]; then
    preserve_worktree "$record" ambiguous-parent
    return
  fi
  canonical_parent=$(realpath -e -- "$parent_path") || {
    preserve_worktree "$record" ambiguous-parent
    return
  }
  if [ "$canonical_parent" != "$parent_path" ]; then
    preserve_worktree "$record" ambiguous-parent
    return
  fi
  path_identity=$(stat -c '%d:%i' -- "$path") || {
    preserve_worktree "$record" ambiguous-path
    return
  }
  path_device=${path_identity%%:*}
  path_inode=${path_identity#*:}
  parent_device=$(stat -c %d -- "$parent_path") || {
    preserve_worktree "$record" ambiguous-parent
    return
  }
  if [ "$path_device" != "$parent_device" ]; then
    preserve_worktree "$record" cross-filesystem-path
    return
  fi
  git_dir=$(run_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    {
      preserve_worktree "$record" not-a-worktree
      return
    }
  git_dir=$(realpath -e -- "$git_dir" 2>/dev/null) ||
    {
      preserve_worktree "$record" ambiguous-git-dir
      return
    }
  if [ "$git_dir" = "$common_dir" ]; then
    preserve_worktree "$record" main-worktree
    return
  fi
  initial_git_dir=$git_dir
  if [ "$(run_git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$common_dir" ]; then
    preserve_worktree "$record" common-dir-changed
    return
  fi
  status_output=$(run_git -C "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null) ||
    {
      preserve_worktree "$record" status-failed
      return
    }
  if [ -n "$status_output" ]; then
    preserve_worktree "$record" dirty
    return
  fi
  current_head=$(resolve_git_context_head_identity worktree "$path") ||
    {
      preserve_worktree "$record" head-missing
      return
    }
  if [ "$current_head" != "$initial_head" ]; then
    preserve_worktree "$record" head-changed
    return
  fi
  if process_reason=$(process_reference_reason "$path"); then
    preserve_worktree "$record" "$process_reason"
    return
  fi

  if [ "$recovered_identity" = true ]; then
    if ! worktree_link_identity_is_valid "$path" "$common_dir" "$expected_git_dir" \
      "$expected_device" "$expected_inode"; then
      preserve_worktree "$record" recovered-identity-changed
      return
    fi
    initial_git_dir=$expected_git_dir
    path_device=$expected_device
    path_inode=$expected_inode
  fi

  quarantine_root=$(mktemp -d "$parent_path/.dotfiles-agent-quarantine.XXXXXXXX") || {
    preserve_worktree "$record" quarantine-create-failed
    return
  }
  chmod 700 -- "$quarantine_root"
  quarantine_path="$quarantine_root/worktree"
  if [ -L "$quarantine_root" ] || [ ! -d "$quarantine_root" ] ||
    [ "$(stat -c %u -- "$quarantine_root")" != "$(id -u)" ] ||
    [ "$(stat -c %a -- "$quarantine_root")" != 700 ] ||
    [ "$(stat -c %d -- "$quarantine_root")" != "$path_device" ]; then
    rmdir -- "$quarantine_root" 2>/dev/null || true
    preserve_worktree "$record" ambiguous-quarantine
    return
  fi
  mark_worktree_quarantining "$record" "$quarantine_path" "$initial_git_dir" \
    "$path_device" "$path_inode"
  quarantine_transaction_record=$record
  trap 'recover_quarantine_on_exit $?' EXIT
  trap handle_transaction_term TERM
  if ! run_git --git-dir="$common_dir" worktree move -- "$path" "$quarantine_path"; then
    if rmdir -- "$quarantine_root" 2>/dev/null; then
      preserve_worktree "$record" quarantine-move-failed
    else
      mark_quarantining_reason "$record" quarantine-move-failed-root-unresolved
      printf '%s: preserve quarantine-move-failed-root-unresolved: %s (quarantine: %s)\n' \
        "$program" "$path" "$quarantine_path" >&2
    fi
    finish_quarantine_transaction
    return
  fi

  if [ -L "$quarantine_path" ] || [ ! -d "$quarantine_path" ] ||
    [ "$(stat -c %u -- "$quarantine_path")" != "$(id -u)" ] ||
    [ "$(realpath -e -- "$quarantine_path" 2>/dev/null)" != "$quarantine_path" ] ||
    ! worktree_directory_identity_is_valid "$quarantine_path" "$path_device" "$path_inode"; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" ambiguous-quarantine-path
    finish_quarantine_transaction
    return
  fi
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" missing-common-dir
    finish_quarantine_transaction
    return
  }
  if [ "$canonical_common" != "$common_dir" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" common-dir-changed
    finish_quarantine_transaction
    return
  fi
  git_dir=$(run_git -C "$quarantine_path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" not-a-worktree
    finish_quarantine_transaction
    return
  }
  git_dir=$(realpath -e -- "$git_dir" 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" ambiguous-git-dir
    finish_quarantine_transaction
    return
  }
  if [ "$git_dir" != "$initial_git_dir" ] ||
    [ "$(run_git -C "$quarantine_path" rev-parse \
      --path-format=absolute --git-common-dir 2>/dev/null)" != "$common_dir" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" common-dir-changed
    finish_quarantine_transaction
    return
  fi
  status_output=$(run_git -C "$quarantine_path" status \
    --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" status-failed
    finish_quarantine_transaction
    return
  }
  if [ -n "$status_output" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" dirty
    finish_quarantine_transaction
    return
  fi
  current_head=$(resolve_git_context_head_identity worktree "$quarantine_path") || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" head-missing
    finish_quarantine_transaction
    return
  }
  if [ "$current_head" != "$initial_head" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" head-changed
    finish_quarantine_transaction
    return
  fi
  if process_reason=$(process_reference_reason "$quarantine_path"); then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" "$process_reason"
    finish_quarantine_transaction
    return
  fi
  if ! worktree_identity_is_valid "$quarantine_path" "$common_dir" "$initial_head" \
    "$initial_git_dir" "$path_device" "$path_inode"; then
    mark_quarantining_reason "$record" quarantine-identity-changed-before-remove
    printf '%s: preserve quarantine-identity-changed-before-remove: %s (quarantine: %s)\n' \
      "$program" "$path" "$quarantine_path" >&2
    finish_quarantine_transaction
    return
  fi
  mark_worktree_removing "$record"
  if ! run_git --git-dir="$common_dir" worktree remove -- "$quarantine_path"; then
    mark_removing_reason "$record" removing-remove-failed
    finish_quarantine_transaction
    return
  fi
  if ! complete_removing_transaction "$record" "$path" "$quarantine_path" \
    "$common_dir" "$initial_git_dir"; then
    finish_quarantine_transaction
    return
  fi
  printf '%s: removed managed worktree: %s\n' "$program" "$path"
  finish_quarantine_transaction
}

cleanup_session_records() {
  local session_id=$1 record status
  for record in "$worktrees_root"/*.json; do
    [ "$(jq -r '.session_id' "$record")" = "$session_id" ] || continue
    status=$(jq -r '.status' "$record")
    case "$status" in
    adding) recover_adding_worktree "$record" || true ;;
    owned) cleanup_worktree_record "$record" ;;
    quarantining) recover_quarantining_worktree "$record" || true ;;
    removing) recover_removing_worktree "$record" || true ;;
    esac
  done
}

begin_session() {
  local session_id=$1 client owner_pid owner_start boot_id session_file json actual_start now
  validate_id session "$session_id"
  [ "${DOTFILES_AGENT_SESSION_ID-}" = "$session_id" ] || die 'session argument does not match environment'
  client=${DOTFILES_AGENT_CLIENT-}
  validate_id client "$client"
  owner_pid=${DOTFILES_AGENT_OWNER_PID-}
  owner_start=${DOTFILES_AGENT_OWNER_START_TIME-}
  boot_id=${DOTFILES_AGENT_BOOT_ID-}
  [[ $owner_pid =~ ^[1-9][0-9]*$ ]] || die 'invalid owner pid'
  [[ $owner_start =~ ^[0-9]+$ ]] || die 'invalid owner process start time'
  [[ $boot_id =~ ^[A-Fa-f0-9-]+$ ]] || die 'invalid boot id'
  [ "$boot_id" = "$current_boot_id" ] || die 'owner boot id does not match current boot'
  actual_start=$(process_start_time "$owner_pid") || die 'owner process is not live'
  [ "$actual_start" = "$owner_start" ] || die 'owner process start time does not match'
  now=$(date +%s)

  session_file="$sessions_root/$session_id.json"
  json=$(jq -cn \
    --arg session_id "$session_id" \
    --arg client "$client" \
    --arg boot_id "$boot_id" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start_time "$owner_start" \
    --argjson now "$now" \
    '{version: 1, session_id: $session_id, client: $client, boot_id: $boot_id,
      owner_pid: $owner_pid, owner_start_time: $owner_start_time, status: "active", reason: "active",
      updated_at: $now}')
  if [ -e "$session_file" ] || [ -L "$session_file" ]; then
    validate_regular_file "$session_file" || die "session ledger is ambiguous: $session_file"
    session_schema_is_valid "$session_file" || die "session ledger is malformed: $session_file"
    jq --exit-status --argjson expected "$json" \
      'del(.updated_at) == ($expected | del(.updated_at))' "$session_file" >/dev/null ||
      die "session id is already owned: $session_id"
    return
  fi
  atomic_write "$session_file" "$json"
}

require_live_session() {
  local session_id=$1 session_file
  validate_id session "$session_id"
  if [ -n "${DOTFILES_AGENT_SESSION_ID-}" ] && [ "$DOTFILES_AGENT_SESSION_ID" != "$session_id" ]; then
    die 'session argument does not match environment'
  fi
  preflight_ledgers || die 'ledger preflight failed'
  session_file="$sessions_root/$session_id.json"
  [ -f "$session_file" ] && [ ! -L "$session_file" ] || die "session is not registered: $session_id"
  [ "$(jq -r '.status' "$session_file")" = active ] || die "session is not active: $session_id"
  if orphan_reason "$session_file" >/dev/null; then
    die "session owner is not live: $session_id"
  fi
}

worktree_record_path() {
  local common_dir=$1 path=$2 record_id
  record_id=$(printf '%s\0%s' "$common_dir" "$path" | sha256sum | cut -d ' ' -f 1)
  printf '%s/%s.json\n' "$worktrees_root" "$record_id"
}

validate_added_worktree_identity() {
  local common_dir=$1 path=$2 initial_head=$3 canonical_common canonical_path current_common current_head
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(stat -c %u -- "$path" 2>/dev/null)" = "$resource_owner_uid" ] || return 1
  canonical_path=$(realpath -e -- "$path" 2>/dev/null) || return 1
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || return 1
  [ "$canonical_path" = "$path" ] || return 1
  [ "$canonical_common" = "$common_dir" ] || return 1
  [ "$path" != / ] || return 1
  [ "$path" != "$common_dir" ] || return 1
  [[ $common_dir != "$path/"* ]] || return 1

  validated_git_dir=$(run_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    return 1
  validated_git_dir=$(realpath -e -- "$validated_git_dir" 2>/dev/null) || return 1
  [ "$validated_git_dir" != "$common_dir" ] || return 1
  current_common=$(run_git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    return 1
  current_common=$(realpath -e -- "$current_common" 2>/dev/null) || return 1
  [ "$current_common" = "$common_dir" ] || return 1
  current_head=$(resolve_git_context_head_identity worktree "$path") || return 1
  [ "$current_head" = "$initial_head" ] || return 1
  validated_worktree_device=$(stat -c %d -- "$path" 2>/dev/null) || return 1
  validated_worktree_inode=$(stat -c %i -- "$path" 2>/dev/null) || return 1
}

begin_worktree_add() {
  local session_id=$1 common_dir=$2 path=$3 initial_head=$4 requested_head=$5
  local roster_fingerprint=$6 parent_device=$7 parent_inode=$8
  local canonical_common canonical_parent parent_path record_file json now existing_status
  validate_id session "$session_id"
  validate_absolute_path common-dir "$common_dir"
  validate_absolute_path worktree-path "$path"
  [[ $initial_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die 'invalid initial HEAD'
  [ -n "$requested_head" ] &&
    [[ $requested_head != *[$'\001'-$'\037'$'\177']* ]] || die 'invalid requested HEAD'
  [[ $roster_fingerprint =~ ^[0-9a-f]{64}$ ]] || die 'invalid roster fingerprint'
  [[ $parent_device =~ ^[0-9]+$ ]] || die 'invalid parent device'
  [[ $parent_inode =~ ^[0-9]+$ ]] || die 'invalid parent inode'
  require_live_session "$session_id"

  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || die 'cannot canonicalize common dir'
  [ "$canonical_common" = "$common_dir" ] || die 'common dir is not canonical'
  if [[ $initial_head =~ ^(0{40}|0{64})$ ]]; then
    [ "$(zero_oid_for_git_context git-dir "$common_dir")" = "$initial_head" ] ||
      die 'zero initial HEAD does not match the repository object format'
  fi
  [ ! -e "$path" ] && [ ! -L "$path" ] || die 'worktree add target already exists'
  parent_path=$(dirname -- "$path")
  [ -d "$parent_path" ] && [ ! -L "$parent_path" ] || die 'worktree parent is ambiguous'
  canonical_parent=$(realpath -e -- "$parent_path" 2>/dev/null) || die 'cannot canonicalize worktree parent'
  [ "$canonical_parent" = "$parent_path" ] || die 'worktree parent is not canonical'
  [ "$(stat -c %u -- "$parent_path" 2>/dev/null)" = "$resource_owner_uid" ] ||
    die 'worktree parent has another owner'
  [ "$(stat -c %d -- "$parent_path" 2>/dev/null)" = "$parent_device" ] ||
    die 'worktree parent device changed'
  [ "$(stat -c %i -- "$parent_path" 2>/dev/null)" = "$parent_inode" ] ||
    die 'worktree parent inode changed'

  record_file=$(worktree_record_path "$common_dir" "$path")
  now=$(date +%s)
  json=$(jq -cn \
    --arg session_id "$session_id" --arg common_dir "$common_dir" --arg path "$path" \
    --arg initial_head "$initial_head" --arg requested_head "$requested_head" \
    --arg roster_fingerprint "$roster_fingerprint" --arg parent_device "$parent_device" \
    --arg parent_inode "$parent_inode" --argjson now "$now" \
    '{version: 1, session_id: $session_id, common_dir: $common_dir, path: $path,
      initial_head: $initial_head, requested_head: $requested_head,
      roster_fingerprint: $roster_fingerprint, parent_device: $parent_device,
      parent_inode: $parent_inode, status: "adding", last_reason: "adding",
      updated_at: $now}')
  if [ -e "$record_file" ] || [ -L "$record_file" ]; then
    validate_regular_file "$record_file" || die "worktree ledger is ambiguous: $record_file"
    worktree_schema_is_valid "$record_file" || die "worktree ledger is malformed: $record_file"
    existing_status=$(jq -r '.status' "$record_file")
    [ "$existing_status" = removed ] || die "worktree is already owned: $path"
  fi
  atomic_write "$record_file" "$json"
}

record_worktree_add_identity() {
  local session_id=$1 common_dir=$2 path=$3 initial_head=$4 record_file updated now
  validate_id session "$session_id"
  validate_absolute_path common-dir "$common_dir"
  validate_absolute_path worktree-path "$path"
  [[ $initial_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die 'invalid initial HEAD'
  preflight_ledgers || die 'ledger preflight failed'
  record_file=$(worktree_record_path "$common_dir" "$path")
  [ -f "$record_file" ] && [ ! -L "$record_file" ] || die 'adding intent is missing'
  jq --exit-status --arg session_id "$session_id" --arg common_dir "$common_dir" \
    --arg path "$path" --arg initial_head "$initial_head" \
    '.status == "adding" and .session_id == $session_id and .common_dir == $common_dir
      and .path == $path and .initial_head == $initial_head' "$record_file" >/dev/null ||
    die 'adding intent identity changed'
  validate_added_worktree_identity "$common_dir" "$path" "$initial_head" ||
    die 'added worktree identity is ambiguous'
  now=$(date +%s)
  updated=$(jq -c --arg git_dir "$validated_git_dir" \
    --arg worktree_device "$validated_worktree_device" \
    --arg worktree_inode "$validated_worktree_inode" --argjson now "$now" \
    '.git_dir = $git_dir | .worktree_device = $worktree_device |
      .worktree_inode = $worktree_inode | .last_reason = "adding-validated" |
      .updated_at = $now' "$record_file")
  atomic_write "$record_file" "$updated"
}

complete_worktree_add() {
  local session_id=$1 common_dir=$2 path=$3 initial_head=$4 record_file
  local expected_git_dir expected_device expected_inode updated now
  validate_id session "$session_id"
  validate_absolute_path common-dir "$common_dir"
  validate_absolute_path worktree-path "$path"
  [[ $initial_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die 'invalid initial HEAD'
  preflight_ledgers || die 'ledger preflight failed'
  record_file=$(worktree_record_path "$common_dir" "$path")
  [ -f "$record_file" ] && [ ! -L "$record_file" ] || die 'adding intent is missing'
  jq --exit-status --arg session_id "$session_id" --arg common_dir "$common_dir" \
    --arg path "$path" --arg initial_head "$initial_head" \
    '.status == "adding" and .session_id == $session_id and .common_dir == $common_dir
      and .path == $path and .initial_head == $initial_head
      and has("git_dir") and has("worktree_device") and has("worktree_inode")' \
    "$record_file" >/dev/null || die 'validated adding intent is missing'
  expected_git_dir=$(jq -r '.git_dir' "$record_file") || die 'cannot read adding git dir'
  expected_device=$(jq -r '.worktree_device' "$record_file") || die 'cannot read adding device'
  expected_inode=$(jq -r '.worktree_inode' "$record_file") || die 'cannot read adding inode'
  worktree_identity_is_valid "$path" "$common_dir" "$initial_head" "$expected_git_dir" \
    "$expected_device" "$expected_inode" || die 'added worktree identity changed before ownership'
  now=$(date +%s)
  updated=$(jq -c --argjson now "$now" \
    'del(.requested_head, .roster_fingerprint, .parent_device, .parent_inode) |
      .status = "owned" | .last_reason = "registered" | .updated_at = $now' "$record_file")
  atomic_write "$record_file" "$updated"
}

register_worktree() {
  local session_id=$1 common_dir=$2 path=$3 initial_head=$4 canonical_common canonical_path
  local git_dir current_common current_head record_id record_file json existing_status now
  validate_id session "$session_id"
  validate_absolute_path common-dir "$common_dir"
  validate_absolute_path worktree-path "$path"
  [[ $initial_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die 'invalid initial HEAD'
  require_live_session "$session_id"

  [ -d "$path" ] && [ ! -L "$path" ] || die "worktree path is ambiguous: $path"
  canonical_path=$(realpath -e -- "$path") || die "cannot canonicalize worktree path: $path"
  canonical_common=$(realpath -e -- "$common_dir") || die "cannot canonicalize common dir: $common_dir"
  [ "$canonical_path" = "$path" ] || die "worktree path is not canonical: $path"
  [ "$canonical_common" = "$common_dir" ] || die "common dir is not canonical: $common_dir"
  [ "$path" != / ] || die 'refusing root as a worktree'
  [ "$path" != "$common_dir" ] || die 'worktree path equals common git dir'
  [[ $common_dir != "$path/"* ]] || die 'common git dir is inside worktree path'

  git_dir=$(run_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    die "path is not a git worktree: $path"
  git_dir=$(realpath -e -- "$git_dir") || die 'cannot canonicalize git dir'
  [ "$git_dir" != "$common_dir" ] || die 'refusing to register the main worktree'
  current_common=$(run_git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    die 'cannot resolve worktree common dir'
  current_common=$(realpath -e -- "$current_common") || die 'cannot canonicalize current common dir'
  [ "$current_common" = "$common_dir" ] || die 'worktree common dir changed'
  current_head=$(resolve_git_context_head_identity worktree "$path") ||
    die 'worktree HEAD is missing or ambiguous'
  [ "$current_head" = "$initial_head" ] || die 'worktree HEAD changed before registration'

  record_id=$(printf '%s\0%s' "$common_dir" "$path" | sha256sum | cut -d ' ' -f 1)
  record_file="$worktrees_root/$record_id.json"
  now=$(date +%s)
  json=$(jq -cn \
    --arg session_id "$session_id" \
    --arg common_dir "$common_dir" \
    --arg path "$path" \
    --arg initial_head "$initial_head" \
    --argjson now "$now" \
    '{version: 1, session_id: $session_id, common_dir: $common_dir, path: $path,
      initial_head: $initial_head, status: "owned", last_reason: "registered", updated_at: $now}')
  if [ -e "$record_file" ] || [ -L "$record_file" ]; then
    validate_regular_file "$record_file" || die "worktree ledger is ambiguous: $record_file"
    worktree_schema_is_valid "$record_file" || die "worktree ledger is malformed: $record_file"
    existing_status=$(jq -r '.status' "$record_file")
    if [ "$existing_status" != removed ]; then
      jq --exit-status --argjson expected "$json" \
        'del(.updated_at) == ($expected | del(.updated_at))' "$record_file" >/dev/null ||
        die "worktree is already owned: $path"
      return
    fi
  fi
  atomic_write "$record_file" "$json"
}

cleanup_session() {
  local session_id=$1 session_file
  validate_id session "$session_id"
  if [ -n "${DOTFILES_AGENT_SESSION_ID-}" ] && [ "$DOTFILES_AGENT_SESSION_ID" != "$session_id" ]; then
    die 'session argument does not match environment'
  fi
  preflight_ledgers || die 'ledger preflight failed'
  session_file="$sessions_root/$session_id.json"
  [ -f "$session_file" ] && [ ! -L "$session_file" ] || die "session is not registered: $session_id"
  mark_session "$session_file" cleanup
  cleanup_session_records "$session_id"
}

reap_one_session() {
  local session_id=$1 session_file reason status
  preflight_ledgers || die 'ledger preflight failed'
  session_file="$sessions_root/$session_id.json"
  [ -f "$session_file" ] && [ ! -L "$session_file" ] || return
  status=$(jq -r '.status' "$session_file")
  if [ "$status" = active ]; then
    if ! reason=$(orphan_reason "$session_file"); then
      return
    fi
    mark_session "$session_file" "$reason"
    printf '%s: reaping %s: %s\n' "$program" "$reason" "$session_id" >&2
  fi
  cleanup_session_records "$session_id"
}

ledger_timestamp() {
  local ledger=$1 timestamp
  if jq --exit-status 'has("updated_at")' "$ledger" >/dev/null; then
    timestamp=$(jq -r '.updated_at' "$ledger") || return 1
  else
    timestamp=$(stat -c %Y -- "$ledger") || return 1
  fi
  [[ $timestamp =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$timestamp"
}

ledger_is_expired() {
  local ledger=$1 timestamp elapsed_days timestamp_length now_length
  timestamp=$(ledger_timestamp "$ledger") || return 1
  timestamp_length=${#timestamp}
  now_length=${#ledger_retention_now}
  if [ "$timestamp_length" -gt "$now_length" ] ||
    { [ "$timestamp_length" -eq "$now_length" ] && [[ $timestamp > "$ledger_retention_now" ]]; }; then
    return 1
  fi
  elapsed_days=$(((ledger_retention_now - timestamp) / 86400))
  [ "$elapsed_days" -ge "$ledger_retention_days" ]
}

session_has_worktree_record() {
  local session_id=$1 record
  for record in "$worktrees_root"/*.json; do
    [ "$(jq -r '.session_id' "$record")" != "$session_id" ] || return 0
  done
  return 1
}

prune_terminal_ledgers() {
  local record session_file session_id
  for record in "$worktrees_root"/*.json; do
    case "$(jq -r '.status' "$record")" in
    preserved | removed)
      ledger_is_expired "$record" || continue
      rm -f -- "$record"
      ;;
    esac
  done
  for session_file in "$sessions_root"/*.json; do
    [ "$(jq -r '.status' "$session_file")" = ended ] || continue
    ledger_is_expired "$session_file" || continue
    session_id=$(jq -r '.session_id' "$session_file")
    session_has_worktree_record "$session_id" && continue
    rm -f -- "$session_file"
  done
}

reap_sessions() {
  local entry name session_id
  local -a session_ids=()

  acquire_creation_lock reaper-scan
  acquire_ledger_lock
  preflight_ledgers || die 'ledger preflight failed'
  for entry in "$sessions_root"/*.json; do
    name=${entry##*/}
    session_id=${name%.json}
    validate_id session "$session_id"
    session_ids+=("$session_id")
  done
  release_locks

  for session_id in "${session_ids[@]}"; do
    acquire_creation_lock "$session_id"
    acquire_ledger_lock
    reap_one_session "$session_id"
    release_locks
  done

  acquire_ledger_lock
  preflight_ledgers || die 'ledger preflight failed'
  prune_terminal_ledgers
  release_locks
}

usage() {
  printf '%s\n' "$usage_text" >&2
  exit 64
}

case "${1-}" in
--help | -h)
  printf '%s\n' "$usage_text"
  exit 0
  ;;
esac

[ -n "${HOME-}" ] || die 'HOME is unset'
validate_absolute_path HOME "$HOME"
[ -d "$HOME" ] && [ ! -L "$HOME" ] || die 'HOME is ambiguous'
resource_owner_uid=$(id -u) || die 'cannot determine resource owner'
[[ $resource_owner_uid =~ ^[0-9]+$ ]] || die 'invalid resource owner'
[ "$(stat -c %u "$HOME")" = "$resource_owner_uid" ] || die 'HOME has another owner'

state_root="$HOME/@resourceStateRootRelative@"
sessions_root="$state_root/sessions"
worktrees_root="$state_root/worktrees"
locks_root="$state_root/locks"
ensure_directory "$HOME/.local" false
ensure_directory "$HOME/.local/state" false
ensure_directory "$HOME/@stateRootRelative@" true
ensure_directory "$state_root" true
ensure_directory "$sessions_root" true
ensure_directory "$worktrees_root" true
ensure_directory "$locks_root" true

mutation_lock_file="$locks_root/.worktree-mutation.lock"
lock_file="$state_root/ledger.lock"
current_boot_id=$(</proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
[[ $current_boot_id =~ ^[A-Fa-f0-9-]+$ ]] || die 'invalid current boot id'
ledger_retention_days=@ledgerRetentionDays@
[[ $ledger_retention_days =~ ^[1-9][0-9]*$ ]] || die 'invalid ledger retention days'
ledger_retention_now=$(date +%s)
[[ $ledger_retention_now =~ ^[0-9]+$ ]] || die 'invalid ledger retention reference time'

case "${1-}" in
begin-session)
  [ "$#" -eq 2 ] || usage
  acquire_creation_lock "$2"
  acquire_ledger_lock
  begin_session "$2"
  ;;
validate-session)
  [ "$#" -eq 2 ] || usage
  if [ "${DOTFILES_AGENT_MUTATION_LOCK_FD-}" = 7 ]; then
    acquire_mutation_lock
  fi
  acquire_creation_lock "$2"
  acquire_ledger_lock
  require_live_session "$2"
  ;;
cleanup-session)
  [ "$#" -eq 2 ] || usage
  # Mutating commands keep the global -> session -> ledger order.
  acquire_mutation_lock
  acquire_creation_lock "$2"
  acquire_ledger_lock
  cleanup_session "$2"
  ;;
begin-worktree-add)
  [ "$#" -eq 9 ] || usage
  acquire_mutation_lock
  acquire_creation_lock "$2"
  acquire_ledger_lock
  begin_worktree_add "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
  ;;
record-worktree-add-identity)
  [ "$#" -eq 5 ] || usage
  acquire_mutation_lock
  acquire_creation_lock "$2"
  acquire_ledger_lock
  record_worktree_add_identity "$2" "$3" "$4" "$5"
  ;;
complete-worktree-add)
  [ "$#" -eq 5 ] || usage
  acquire_mutation_lock
  acquire_creation_lock "$2"
  acquire_ledger_lock
  complete_worktree_add "$2" "$3" "$4" "$5"
  ;;
register-worktree)
  [ "$#" -eq 5 ] || usage
  acquire_mutation_lock
  acquire_creation_lock "$2"
  acquire_ledger_lock
  register_worktree "$2" "$3" "$4" "$5"
  ;;
reap)
  [ "$#" -eq 1 ] || usage
  acquire_mutation_lock
  reap_sessions
  ;;
*) usage ;;
esac
