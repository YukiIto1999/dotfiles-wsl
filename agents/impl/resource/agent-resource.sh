set -euo pipefail
shopt -s nullglob

program=dotfiles-agent-resource
usage_text="usage: $program begin-session SESSION | validate-session SESSION | cleanup-session SESSION | register-worktree SESSION COMMON-DIR PATH INITIAL-HEAD | reap"
git_command=@gitCommand@

die() {
  printf '%s: %s\n' "$program" "$1" >&2
  exit 70
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
      keys == ["common_dir", "initial_head", "last_reason", "path", "session_id", "status", "version"]
      or keys == ["common_dir", "initial_head", "last_reason", "path", "session_id", "status", "updated_at", "version"]
    )
    and .version == 1
    and (.session_id | type == "string")
    and (.common_dir | type == "string" and startswith("/"))
    and (.path | type == "string" and startswith("/"))
    and (.initial_head | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
    and (.status == "owned" or .status == "preserved" or .status == "removed")
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
    '.status = $status | .last_reason = $reason | .updated_at = $now' "$record")
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
  local path=$1 process_dir process_stat process_fields process_state process_start final_start
  local reference reason reference_status
  local -a process_dirs fd_references
  process_dirs=(/proc/[0-9]*)

  for process_dir in "${process_dirs[@]}"; do
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

restore_quarantined_worktree() {
  local record=$1 common_dir=$2 original_path=$3 quarantine_path=$4 quarantine_root=$5 reason=$6
  if [ ! -e "$original_path" ] && [ ! -L "$original_path" ] &&
    [ -d "$quarantine_path" ] && [ ! -L "$quarantine_path" ] &&
    "$git_command" --git-dir="$common_dir" worktree move -- \
      "$quarantine_path" "$original_path"; then
    rmdir -- "$quarantine_root" 2>/dev/null || true
    preserve_worktree "$record" "$reason"
    return
  fi

  mark_worktree "$record" preserved "$reason-restore-failed"
  printf '%s: preserve %s-restore-failed: %s (quarantine: %s)\n' \
    "$program" "$reason" "$original_path" "$quarantine_path" >&2
}

cleanup_worktree_record() {
  local record=$1 path common_dir initial_head canonical_path canonical_common git_dir current_head status_output
  local parent_path canonical_parent path_device parent_device quarantine_root quarantine_path process_reason
  path=$(jq -r '.path' "$record")
  common_dir=$(jq -r '.common_dir' "$record")
  initial_head=$(jq -r '.initial_head' "$record")

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    preserve_worktree "$record" missing
    return
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
  path_device=$(stat -c %d -- "$path") || {
    preserve_worktree "$record" ambiguous-path
    return
  }
  parent_device=$(stat -c %d -- "$parent_path") || {
    preserve_worktree "$record" ambiguous-parent
    return
  }
  if [ "$path_device" != "$parent_device" ]; then
    preserve_worktree "$record" cross-filesystem-path
    return
  fi
  git_dir=$("$git_command" -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
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
  if [ "$("$git_command" -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$common_dir" ]; then
    preserve_worktree "$record" common-dir-changed
    return
  fi
  status_output=$("$git_command" -C "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null) ||
    {
      preserve_worktree "$record" status-failed
      return
    }
  if [ -n "$status_output" ]; then
    preserve_worktree "$record" dirty
    return
  fi
  current_head=$("$git_command" -C "$path" rev-parse --verify HEAD 2>/dev/null) ||
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
  if ! "$git_command" --git-dir="$common_dir" worktree move -- "$path" "$quarantine_path"; then
    rmdir -- "$quarantine_root" 2>/dev/null || true
    preserve_worktree "$record" quarantine-move-failed
    return
  fi

  if [ -L "$quarantine_path" ] || [ ! -d "$quarantine_path" ] ||
    [ "$(stat -c %u -- "$quarantine_path")" != "$(id -u)" ] ||
    [ "$(realpath -e -- "$quarantine_path" 2>/dev/null)" != "$quarantine_path" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" ambiguous-quarantine-path
    return
  fi
  canonical_common=$(realpath -e -- "$common_dir" 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" missing-common-dir
    return
  }
  if [ "$canonical_common" != "$common_dir" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" common-dir-changed
    return
  fi
  git_dir=$("$git_command" -C "$quarantine_path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" not-a-worktree
    return
  }
  git_dir=$(realpath -e -- "$git_dir" 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" ambiguous-git-dir
    return
  }
  if [ "$git_dir" = "$common_dir" ] ||
    [ "$("$git_command" -C "$quarantine_path" rev-parse \
      --path-format=absolute --git-common-dir 2>/dev/null)" != "$common_dir" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" common-dir-changed
    return
  fi
  status_output=$("$git_command" -C "$quarantine_path" status \
    --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" status-failed
    return
  }
  if [ -n "$status_output" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" dirty
    return
  fi
  current_head=$("$git_command" -C "$quarantine_path" rev-parse --verify HEAD 2>/dev/null) || {
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" head-missing
    return
  }
  if [ "$current_head" != "$initial_head" ]; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" head-changed
    return
  fi
  if process_reason=$(process_reference_reason "$quarantine_path"); then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" "$process_reason"
    return
  fi
  if ! "$git_command" --git-dir="$common_dir" worktree remove -- "$quarantine_path"; then
    restore_quarantined_worktree "$record" "$common_dir" "$path" \
      "$quarantine_path" "$quarantine_root" remove-failed
    return
  fi
  rmdir -- "$quarantine_root" 2>/dev/null ||
    printf '%s: preserve quarantine-root: %s\n' "$program" "$quarantine_root" >&2
  mark_worktree "$record" removed clean-unchanged-inactive
  printf '%s: removed managed worktree: %s\n' "$program" "$path"
}

cleanup_session_records() {
  local session_id=$1 record
  for record in "$worktrees_root"/*.json; do
    [ "$(jq -r '.session_id' "$record")" = "$session_id" ] || continue
    [ "$(jq -r '.status' "$record")" = owned ] || continue
    cleanup_worktree_record "$record"
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

  git_dir=$("$git_command" -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    die "path is not a git worktree: $path"
  git_dir=$(realpath -e -- "$git_dir") || die 'cannot canonicalize git dir'
  [ "$git_dir" != "$common_dir" ] || die 'refusing to register the main worktree'
  current_common=$("$git_command" -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    die 'cannot resolve worktree common dir'
  current_common=$(realpath -e -- "$current_common") || die 'cannot canonicalize current common dir'
  [ "$current_common" = "$common_dir" ] || die 'worktree common dir changed'
  if current_head=$("$git_command" -C "$path" rev-parse --verify HEAD 2>/dev/null); then
    [ "$current_head" = "$initial_head" ] || die 'worktree HEAD changed before registration'
  else
    [[ $initial_head =~ ^0{40}$|^0{64}$ ]] || die 'worktree HEAD is missing'
  fi

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
  local ledger=$1 timestamp elapsed_days elapsed_remainder timestamp_length now_length
  timestamp=$(ledger_timestamp "$ledger") || return 1
  timestamp_length=${#timestamp}
  now_length=${#ledger_retention_now}
  if [ "$timestamp_length" -gt "$now_length" ] ||
    { [ "$timestamp_length" -eq "$now_length" ] && [[ $timestamp > "$ledger_retention_now" ]]; }; then
    return 1
  fi
  elapsed_days=$(((ledger_retention_now - timestamp) / 86400))
  elapsed_remainder=$(((ledger_retention_now - timestamp) % 86400))
  [ "$elapsed_days" -gt "$ledger_retention_days" ] ||
    { [ "$elapsed_days" -eq "$ledger_retention_days" ] &&
      [ "$elapsed_remainder" -gt 0 ]; }
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
[ "$(stat -c %u "$HOME")" = "$(id -u)" ] || die 'HOME has another owner'

state_root="$HOME/.local/state/dotfiles-wsl/agent-resources"
sessions_root="$state_root/sessions"
worktrees_root="$state_root/worktrees"
locks_root="$state_root/locks"
ensure_directory "$HOME/.local" false
ensure_directory "$HOME/.local/state" false
ensure_directory "$HOME/.local/state/dotfiles-wsl" true
ensure_directory "$state_root" true
ensure_directory "$sessions_root" true
ensure_directory "$worktrees_root" true
ensure_directory "$locks_root" true

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
  acquire_creation_lock "$2"
  acquire_ledger_lock
  require_live_session "$2"
  ;;
cleanup-session)
  [ "$#" -eq 2 ] || usage
  acquire_creation_lock "$2"
  acquire_ledger_lock
  cleanup_session "$2"
  ;;
register-worktree)
  [ "$#" -eq 5 ] || usage
  acquire_creation_lock "$2"
  acquire_ledger_lock
  register_worktree "$2" "$3" "$4" "$5"
  ;;
reap)
  [ "$#" -eq 1 ] || usage
  reap_sessions
  ;;
*) usage ;;
esac
