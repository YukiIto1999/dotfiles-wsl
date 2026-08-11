set -euo pipefail

die() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
  exit 70
}

validate_managed_directory() {
  local path=$1
  test ! -L "$path" || die "managed path is a symlink: $path"
  test -d "$path" || die "managed path is not a directory: $path"
  test "$(stat -c %u "$path")" = "$(id -u)" || die "managed path has another owner: $path"
  chmod 700 "$path" || die "cannot secure managed directory: $path"
  test "$(stat -c %a "$path")" = 700 || die "managed directory mode is not 0700: $path"
}

validate_managed_file() {
  local path=$1 description=$2
  test ! -L "$path" || die "$description is a symlink: $path"
  test -f "$path" || die "$description is not a regular file: $path"
  test "$(stat -c %u "$path")" = "$(id -u)" || die "$description has another owner: $path"
  chmod 600 "$path" || die "cannot secure $description: $path"
  test "$(stat -c %a "$path")" = 600 || die "$description mode is not 0600: $path"
}

validate_project_cache() {
  local path=$1 project_id=$2 marker
  marker="$path/.dotfiles-agent-cache.json"

  test ! -L "$path" || return 1
  test -d "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 700 "$path" || return 1
  test "$(stat -c %a "$path")" = 700 || return 1
  test ! -L "$marker" || return 1
  test -f "$marker" || return 1
  test "$(stat -c %u "$marker")" = "$(id -u)" || return 1
  chmod 600 "$marker" || return 1
  test "$(stat -c %a "$marker")" = 600 || return 1
  jq --exit-status --arg project_id "$project_id" \
    '. == {version: 1, project_id: $project_id}' "$marker" >/dev/null 2>&1
}

validate_session_metadata() {
  local metadata=$1 session_id=$2
  jq --exit-status --arg session_id "$session_id" '
    keys == ["boot_id", "client", "owner_pid", "owner_start_time", "project_id", "session_id", "version"] and
    .version == 1 and
    .session_id == $session_id and
    (.client | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.project_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.boot_id | type == "string" and test("^[A-Fa-f0-9-]+$")) and
    (.owner_pid | type == "number" and . > 0 and floor == .) and
    (.owner_start_time | type == "string" and test("^[0-9]+$"))
  ' "$metadata" >/dev/null 2>&1
}

session_owner_state() {
  local metadata=$1 metadata_boot_id owner_pid owner_start_time owner_uid owner_stat current_start_time
  metadata_boot_id=$(jq -r '.boot_id' "$metadata") || {
    printf 'unknown\n'
    return
  }
  if [ "$metadata_boot_id" != "$current_boot_id" ]; then
    printf 'orphan\n'
    return
  fi
  owner_pid=$(jq -r '.owner_pid' "$metadata") || {
    printf 'unknown\n'
    return
  }
  owner_start_time=$(jq -r '.owner_start_time' "$metadata") || {
    printf 'unknown\n'
    return
  }
  if [ ! -e "/proc/$owner_pid" ]; then
    printf 'orphan\n'
    return
  fi
  owner_uid=$(stat -c %u "/proc/$owner_pid" 2>/dev/null) || {
    printf 'unknown\n'
    return
  }
  if [ "$owner_uid" != "$(id -u)" ]; then
    printf 'unknown\n'
    return
  fi
  owner_stat=$(<"/proc/$owner_pid/stat") || {
    printf 'unknown\n'
    return
  }
  current_start_time=$(awk '{print $20}' <<<"${owner_stat##*) }") || {
    printf 'unknown\n'
    return
  }
  if [ "$current_start_time" != "$owner_start_time" ]; then
    printf 'orphan\n'
    return
  fi
  printf 'live\n'
}

restore_quarantined_session() {
  local original=$1 quarantine=$2 quarantine_root=$3 reason=$4
  if [ ! -e "$original" ] && [ ! -L "$original" ] &&
    mv -T -- "$quarantine" "$original"; then
    printf 'dotfiles-agent-project-cache-gc: preserve %s: %s\n' "$reason" "$original" >&2
    if rmdir -- "$quarantine_root" 2>/dev/null; then
      return 0
    fi
    printf 'dotfiles-agent-project-cache-gc: unresolved quarantined session root: %s\n' \
      "$quarantine_root" >&2
    return 1
  fi
  printf 'dotfiles-agent-project-cache-gc: cannot restore quarantined session after %s: %s (quarantine: %s)\n' \
    "$reason" "$original" "$quarantine" >&2
  return 1
}

quarantined_session_root_is_valid() {
  local path=$1
  [ ! -L "$path" ] || return 1
  [ -d "$path" ] || return 1
  [ "$(stat -c %u -- "$path" 2>/dev/null)" = "$(id -u)" ] || return 1
  chmod 700 -- "$path" 2>/dev/null || return 1
  [ "$(stat -c %a -- "$path" 2>/dev/null)" = 700 ]
}

quarantined_session_root_can_restore() {
  local path=$1
  [ ! -L "$path" ] || return 1
  [ -d "$path" ] || return 1
  [ "$(stat -c %u -- "$path" 2>/dev/null)" = "$(id -u)" ]
}

retained_after_quarantine_cleanup() {
  local quarantine_root=$1
  if rmdir -- "$quarantine_root" 2>/dev/null; then
    printf 'retained\n'
    return
  fi
  printf 'dotfiles-agent-project-cache-gc: unresolved quarantined session root: %s\n' \
    "$quarantine_root" >&2
  printf 'retained-hidden\n'
}

remove_orphan_session() {
  local session=$1 session_id=$2 project_id=$3 metadata path_device quarantine_root quarantine_path state reason
  metadata="$session/metadata.json"
  path_device=$(stat -c %d -- "$session") || die "cannot inspect session device: $session"
  quarantine_root=$(mktemp -d "$sessions_root/.gc-quarantine.XXXXXXXX") || {
    printf 'dotfiles-agent-project-cache-gc: cannot create session quarantine: %s\n' \
      "$sessions_root" >&2
    printf 'retained\n'
    return
  }
  chmod 700 -- "$quarantine_root" || {
    printf 'dotfiles-agent-project-cache-gc: cannot secure session quarantine: %s\n' \
      "$quarantine_root" >&2
    retained_after_quarantine_cleanup "$quarantine_root"
    return
  }
  if [ -L "$quarantine_root" ] || [ ! -d "$quarantine_root" ] ||
    [ "$(stat -c %u -- "$quarantine_root")" != "$(id -u)" ] ||
    [ "$(stat -c %a -- "$quarantine_root")" != 700 ] ||
    [ "$(stat -c %d -- "$quarantine_root")" != "$path_device" ]; then
    printf 'dotfiles-agent-project-cache-gc: session quarantine is ambiguous: %s\n' \
      "$quarantine_root" >&2
    retained_after_quarantine_cleanup "$quarantine_root"
    return
  fi
  quarantine_path="$quarantine_root/session"
  if ! mv -T -- "$session" "$quarantine_path"; then
    printf 'dotfiles-agent-project-cache-gc: cannot quarantine session: %s\n' "$session" >&2
    retained_after_quarantine_cleanup "$quarantine_root"
    return
  fi

  if ! quarantined_session_root_is_valid "$quarantine_path"; then
    if quarantined_session_root_can_restore "$quarantine_path"; then
      if restore_quarantined_session "$session" "$quarantine_path" "$quarantine_root" \
        ambiguous-quarantine-path; then
        printf 'retained\n'
      else
        printf 'retained-hidden\n'
      fi
    else
      printf 'dotfiles-agent-project-cache-gc: cannot restore ambiguous quarantined session: %s (quarantine: %s)\n' \
        "$session" "$quarantine_path" >&2
      printf 'retained-hidden\n'
    fi
    return
  fi
  metadata="$quarantine_path/metadata.json"
  reason=
  if [ -L "$metadata" ] || [ ! -f "$metadata" ] ||
    [ "$(stat -c %u -- "$metadata" 2>/dev/null)" != "$(id -u)" ] ||
    ! chmod 600 -- "$metadata" 2>/dev/null ||
    [ "$(stat -c %a -- "$metadata" 2>/dev/null)" != 600 ] ||
    ! validate_session_metadata "$metadata" "$session_id"; then
    reason=invalid-quarantined-metadata
  elif [ "$(jq -r '.project_id' "$metadata" 2>/dev/null)" != "$project_id" ]; then
    reason=quarantined-project-changed
  fi
  if [ -n "$reason" ]; then
    if restore_quarantined_session "$session" "$quarantine_path" "$quarantine_root" "$reason"; then
      printf 'retained\n'
    else
      printf 'retained-hidden\n'
    fi
    return
  fi
  state=$(session_owner_state "$metadata")
  if [ "$state" != orphan ]; then
    if restore_quarantined_session "$session" "$quarantine_path" "$quarantine_root" \
      "quarantined-owner-$state"; then
      printf 'retained\n'
    else
      printf 'retained-hidden\n'
    fi
    return
  fi

  if ! rm -rf --one-file-system -- "$quarantine_path"; then
    printf 'dotfiles-agent-project-cache-gc: cannot remove quarantined orphan: %s\n' \
      "$quarantine_path" >&2
    printf 'retained-hidden\n'
    return
  fi
  if ! rmdir -- "$quarantine_root" 2>/dev/null; then
    printf 'dotfiles-agent-project-cache-gc: preserve quarantine root: %s\n' \
      "$quarantine_root" >&2
    printf 'deleted-hidden\n'
    return
  fi
  printf 'deleted\n'
}

create_shared_cache() {
  local cache_root=$1 shared_root marker marker_tmp created=false
  shared_root="$cache_root/shared"
  marker="$shared_root/.dotfiles-agent-cache.json"

  if mkdir -m 700 "$shared_root" 2>/dev/null; then
    created=true
  else
    validate_managed_directory "$shared_root"
  fi
  if [ "$created" = true ]; then
    marker_tmp=$(mktemp "$shared_root/.owner.XXXXXXXX")
    jq -cn '{version: 1, kind: "shared-cache"}' > "$marker_tmp"
    chmod 600 "$marker_tmp"
    mv -T "$marker_tmp" "$marker"
  fi

  validate_managed_file "$marker" 'shared cache marker'
  jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$marker" >/dev/null 2>&1 \
    || die "shared cache marker is invalid: $marker"
  for path in "$shared_root/cargo-home" "$shared_root/xdg-cache"; do
    if ! mkdir -m 700 "$path" 2>/dev/null; then
      validate_managed_directory "$path"
    fi
  done

  printf '%s\n' "$shared_root"
}

validate_shared_cache() {
  local shared_root=$1 marker="$1/.dotfiles-agent-cache.json"
  validate_managed_directory "$shared_root"
  validate_managed_file "$marker" 'shared cache marker'
  jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$marker" >/dev/null 2>&1 \
    || die "shared cache marker is invalid: $marker"
  validate_managed_directory "$shared_root/cargo-home"
  validate_managed_directory "$shared_root/xdg-cache"
}

allocated_bytes() {
  local path=$1 bytes
  bytes=$(du -s -B1 -- "$path" | cut -f 1) \
    || die "cannot measure allocated cache bytes: $path"
  [[ "$bytes" =~ ^[0-9]+$ ]] || die "allocated cache size is invalid: $path"
  printf '%s\n' "$bytes"
}

high_bytes=${DOTFILES_AGENT_GC_HIGH_BYTES:-@gcHighBytes@}
low_bytes=${DOTFILES_AGENT_GC_LOW_BYTES:-@gcLowBytes@}
case "$high_bytes:$low_bytes" in
  *[!0-9:]*|:*|*:) die 'GC byte thresholds must be non-negative integers' ;;
esac
test "$low_bytes" -le "$high_bytes" || die 'GC low watermark exceeds high watermark'

cache_root="$HOME/@cacheRootRelative@"
sessions_root="$cache_root/sessions"
builds_root="$cache_root/builds"
mkdir -p "$HOME/.cache"
for path in "$cache_root" "$sessions_root" "$builds_root"; do
  if ! mkdir -m 700 "$path" 2>/dev/null; then
    validate_managed_directory "$path"
  fi
done

lock_file="$cache_root/gc.lock"
if (set -o noclobber; : > "$lock_file") 2>/dev/null; then
  chmod 600 "$lock_file"
fi
validate_managed_file "$lock_file" 'GC lock'
exec {lock_fd}<>"$lock_file"
flock -x "$lock_fd"

shared_root=$(create_shared_cache "$cache_root")

scan_file=$(mktemp "$cache_root/.gc-scan.XXXXXXXX")
# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup_scan() {
  local status=$?
  trap - EXIT
  if [[ "$scan_file" == "$cache_root/"* ]] && [ ! -L "$scan_file" ] && [ -f "$scan_file" ]; then
    rm -f -- "$scan_file" || true
  fi
  exit "$status"
}
trap cleanup_scan EXIT

current_boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
declare -A active_projects=()
active_session_count=0
declare -a orphan_sessions=() orphan_session_ids=() orphan_project_ids=()
cache_gc_suppressed=false
gc_owner_uid=$(id -u)

: > "$scan_file"
find "$sessions_root" -mindepth 1 -maxdepth 1 \
  -name '.gc-quarantine.*' -print0 > "$scan_file" \
  || die 'cannot enumerate quarantined agent sessions'
while IFS= read -r -d '' quarantine_root; do
  if [ -L "$quarantine_root" ] || [ ! -d "$quarantine_root" ] ||
    [ "$(stat -c %u -- "$quarantine_root" 2>/dev/null)" != "$gc_owner_uid" ] ||
    [ "$(stat -c %a -- "$quarantine_root" 2>/dev/null)" != 700 ]; then
    cache_gc_suppressed=true
    printf 'dotfiles-agent-project-cache-gc: skip cache GC: unresolved quarantined session root: %s\n' \
      "$quarantine_root" >&2
    continue
  fi
  quarantine_contents=$(find "$quarantine_root" -mindepth 1 -maxdepth 1 \
    -print -quit 2>/dev/null) || {
    cache_gc_suppressed=true
    printf 'dotfiles-agent-project-cache-gc: skip cache GC: cannot inspect quarantined session root: %s\n' \
      "$quarantine_root" >&2
    continue
  }
  if [ -n "$quarantine_contents" ]; then
    cache_gc_suppressed=true
    printf 'dotfiles-agent-project-cache-gc: skip cache GC: unresolved quarantined session: %s\n' \
      "$quarantine_root" >&2
    continue
  fi
  if ! rmdir -- "$quarantine_root" 2>/dev/null; then
    cache_gc_suppressed=true
    printf 'dotfiles-agent-project-cache-gc: skip cache GC: quarantined session root changed during resolution: %s\n' \
      "$quarantine_root" >&2
    continue
  fi
  printf 'dotfiles-agent-project-cache-gc: resolved empty quarantined session root: %s\n' \
    "$quarantine_root" >&2
done < "$scan_file"

find "$sessions_root" -mindepth 1 -maxdepth 1 \
  ! -name '.gc-quarantine.*' -print0 > "$scan_file" \
  || die 'cannot enumerate agent sessions'
while IFS= read -r -d '' session; do
  session_id=${session##*/}
  metadata="$session/metadata.json"
  validate_managed_directory "$session"
  validate_managed_file "$metadata" 'session metadata'
  validate_session_metadata "$metadata" "$session_id" || die "session metadata is invalid: $metadata"
  project_id=$(jq -r '.project_id' "$metadata")
  session_state=$(session_owner_state "$metadata")
  if [ "$session_state" = orphan ]; then
    orphan_sessions+=("$session")
    orphan_session_ids+=("$session_id")
    orphan_project_ids+=("$project_id")
  else
    active_projects[$project_id]=1
    active_session_count=$((active_session_count + 1))
  fi
done < "$scan_file"

for index in "${!orphan_sessions[@]}"; do
  removal_result=$(remove_orphan_session "${orphan_sessions[$index]}" \
    "${orphan_session_ids[$index]}" "${orphan_project_ids[$index]}")
  case "$removal_result" in
  deleted) ;;
  deleted-hidden)
    cache_gc_suppressed=true
    printf 'dotfiles-agent-project-cache-gc: skip cache GC: unresolved quarantined session created while handling: %s\n' \
      "${orphan_sessions[$index]}" >&2
    ;;
  retained | retained-hidden)
    active_projects[${orphan_project_ids[$index]}]=1
    active_session_count=$((active_session_count + 1))
    if [ "$removal_result" = retained-hidden ]; then
      cache_gc_suppressed=true
      printf 'dotfiles-agent-project-cache-gc: skip cache GC: unresolved quarantined session created while handling: %s\n' \
        "${orphan_sessions[$index]}" >&2
    fi
    ;;
  *) die "invalid orphan removal result: $removal_result" ;;
  esac
done

# No cache is removed until every managed root and entry has passed validation.
validate_shared_cache "$shared_root"
shared_size=$(allocated_bytes "$shared_root")

declare -a cache_ids=() cache_paths=() cache_sizes=() cache_mtimes=()
total_bytes=$shared_size
: > "$scan_file"
find "$builds_root" -mindepth 1 -maxdepth 1 -print0 > "$scan_file" \
  || die 'cannot enumerate project caches'
while IFS= read -r -d '' cache; do
  project_id=${cache##*/}
  if [[ ! "$project_id" =~ ^[0-9a-f]{64}$ ]] || ! validate_project_cache "$cache" "$project_id"; then
    die "project cache is not managed: $cache"
  fi

  size=$(allocated_bytes "$cache")
  mtime=$(stat -c %Y "$cache/.dotfiles-agent-cache.json") \
    || die "cannot read project cache age: $cache"
  cache_ids+=("$project_id")
  cache_paths+=("$cache")
  cache_sizes+=("$size")
  cache_mtimes+=("$mtime")
  total_bytes=$((total_bytes + size))
done < "$scan_file"

now=$(date +%s)
inactive_before=$((now - @gcInactiveDays@ * 24 * 60 * 60))
declare -A removed=()

remove_cache() {
  local index=$1 project_id cache
  [ "$cache_gc_suppressed" = false ] || return 0
  project_id=${cache_ids[$index]}
  cache=${cache_paths[$index]}
  test -z "${active_projects[$project_id]+x}" || return 0
  validate_project_cache "$cache" "$project_id" \
    || die "project cache changed during GC: $cache"
  rm -rf --one-file-system -- "$cache"
  removed[$index]=1
  total_bytes=$((total_bytes - cache_sizes[index]))
}

for index in "${!cache_ids[@]}"; do
  if [ "${cache_mtimes[$index]}" -lt "$inactive_before" ]; then
    remove_cache "$index"
  fi
done

if [ "$total_bytes" -gt "$high_bytes" ]; then
  while IFS=' ' read -r _mtime _project_id index; do
    test "$total_bytes" -gt "$low_bytes" || break
    test -z "${removed[$index]+x}" || continue
    remove_cache "$index"
  done < <(
    for index in "${!cache_ids[@]}"; do
      printf '%s %s %s\n' "${cache_mtimes[$index]}" "${cache_ids[$index]}" "$index"
    done | sort -n -k1,1 -k2,2
  )
fi

if [ "$cache_gc_suppressed" = false ] && [ "$total_bytes" -gt "$high_bytes" ] &&
  [ "$active_session_count" -eq 0 ]; then
  validate_shared_cache "$shared_root"
  rm -rf --one-file-system -- "$shared_root/cargo-home" "$shared_root/xdg-cache"
  mkdir -m 700 "$shared_root/cargo-home" "$shared_root/xdg-cache"
  validate_shared_cache "$shared_root"
  total_bytes=$(allocated_bytes "$shared_root")
  for index in "${!cache_ids[@]}"; do
    test -n "${removed[$index]+x}" && continue
    validate_project_cache "${cache_paths[$index]}" "${cache_ids[$index]}" \
      || die "project cache changed during final measurement: ${cache_paths[$index]}"
    size=$(allocated_bytes "${cache_paths[$index]}")
    total_bytes=$((total_bytes + size))
  done
  test "$total_bytes" -le "$high_bytes" \
    || die "allocated cache bytes remain above the high watermark after shared purge"
fi
