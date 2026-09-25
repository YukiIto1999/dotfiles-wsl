#!/usr/bin/env bash
set -euo pipefail

make_cache() {
  local home=$1 project_id=$2 age=$3 file_count=$4 index
  local cache="$home/.cache/dotfiles-wsl/builds/$project_id"
  mkdir -p "$cache/payload"
  jq -cn --arg project_id "$project_id" '{version: 1, project_id: $project_id}' \
    > "$cache/.dotfiles-agent-cache.json"
  for ((index = 0; index < file_count; index++)); do
    printf 'allocated\n' > "$cache/payload/file-$index"
  done
  touch -d "$age days ago" "$cache/.dotfiles-agent-cache.json"
  chmod 0777 "$cache"
  chmod 0666 "$cache/.dotfiles-agent-cache.json"
}

make_session_metadata() {
  local home=$1 project_id=$2 session_id=$3 owner_pid=$4 boot_id=$5 owner_start_time=$6
  local session="$home/.cache/dotfiles-wsl/sessions/$session_id"
  mkdir -p "$session/tmp"
  jq -cn \
    --arg session_id "$session_id" \
    --arg client fixture \
    --arg project_id "$project_id" \
    --arg boot_id "$boot_id" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start_time "$owner_start_time" \
    '{version: 1, session_id: $session_id, client: $client, project_id: $project_id,
      boot_id: $boot_id, owner_pid: $owner_pid, owner_start_time: $owner_start_time}' \
    > "$session/metadata.json"
  chmod 0777 "$session"
  chmod 0666 "$session/metadata.json"
}

make_session() {
  local home=$1 project_id=$2
  local owner_start_time
  owner_start_time=$(awk '{print $22}' "/proc/$$/stat")
  make_session_metadata "$home" "$project_id" "session-$project_id" "$$" \
    "$(cat /proc/sys/kernel/random/boot_id)" "$owner_start_time"
}

make_shared_cache() {
  local home=$1 file_count=$2 index
  local shared="$home/.cache/dotfiles-wsl/shared"
  mkdir -p "$shared/cargo-home/payload" "$shared/xdg-cache"
  jq -cn '{version: 1, kind: "shared-cache"}' > "$shared/.dotfiles-agent-cache.json"
  for ((index = 0; index < file_count; index++)); do
    printf 'allocated\n' > "$shared/cargo-home/payload/file-$index"
  done
  chmod 0777 "$shared" "$shared/cargo-home" "$shared/xdg-cache"
  chmod 0666 "$shared/.dotfiles-agent-cache.json"
}

allocated_bytes() {
  du -s -B1 -- "$1" | cut -f 1
}

expect_unresolved() {
  local log=$1
  shift
  if "$@" 2>"$log"; then
    echo "GC reported success while orphan sessions remained unresolved: $log" >&2
    exit 1
  fi
  grep -Fq 'orphan sessions remain unresolved' "$log"
}

stale_id=$(printf stale | sha256sum | cut -d ' ' -f 1)
recent_id=$(printf recent | sha256sum | cut -d ' ' -f 1)
active_id=$(printf active | sha256sum | cut -d ' ' -f 1)
retained_id=$(printf retained | sha256sum | cut -d ' ' -f 1)
deleted_orphan_id=$(printf deleted-orphan | sha256sum | cut -d ' ' -f 1)
pressure_old_id=$(printf pressure-old | sha256sum | cut -d ' ' -f 1)
pressure_new_id=$(printf pressure-new | sha256sum | cut -d ' ' -f 1)

fixture=$PWD/gc-fixture
home=$fixture/home
mkdir -p "$home/.cache/dotfiles-wsl/sessions" "$home/.cache/dotfiles-wsl/builds"
chmod 0777 "$home/.cache/dotfiles-wsl" \
  "$home/.cache/dotfiles-wsl/sessions" \
  "$home/.cache/dotfiles-wsl/builds"
make_cache "$home" "$stale_id" 40 2
make_cache "$home" "$recent_id" 1 2
make_cache "$home" "$active_id" 40 2
make_session "$home" "$active_id"
make_shared_cache "$home" 2

HOME=$home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test ! -e "$home/.cache/dotfiles-wsl/builds/$stale_id"
test -d "$home/.cache/dotfiles-wsl/builds/$recent_id"
test -d "$home/.cache/dotfiles-wsl/builds/$active_id"
test "$(stat -c %a "$home/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/cargo-home")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/xdg-cache")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/gc.lock")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds/$recent_id")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds/$recent_id/.dotfiles-agent-cache.json")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions/session-$active_id")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions/session-$active_id/metadata.json")" = 600

orphan_home=$fixture/orphan-home
mkdir -p "$orphan_home/.cache/dotfiles-wsl/sessions" \
  "$orphan_home/.cache/dotfiles-wsl/builds"
current_boot_id=$(cat /proc/sys/kernel/random/boot_id)
current_start_time=$(awk '{print $22}' "/proc/$$/stat")
missing_pid=999999999
test ! -e "/proc/$missing_pid"
make_session_metadata "$orphan_home" "$active_id" missing-owner "$missing_pid" \
  "$current_boot_id" 0
make_session_metadata "$orphan_home" "$active_id" boot-mismatch "$$" \
  00000000-0000-0000-0000-000000000000 "$current_start_time"
make_session_metadata "$orphan_home" "$active_id" start-mismatch "$$" \
  "$current_boot_id" 0
make_session_metadata "$orphan_home" "$active_id" live-owner "$$" \
  "$current_boot_id" "$current_start_time"
HOME=$orphan_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
for orphan_session in missing-owner boot-mismatch start-mismatch; do
  if [ -e "$orphan_home/.cache/dotfiles-wsl/sessions/$orphan_session" ] ||
    [ -L "$orphan_home/.cache/dotfiles-wsl/sessions/$orphan_session" ]; then
    echo "GC retained orphan session: $orphan_session" >&2
    exit 1
  fi
done
test -d "$orphan_home/.cache/dotfiles-wsl/sessions/live-owner"
test -z "$(find "$orphan_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"

# An orphan that becomes live after quarantine is retained and continues to
# protect both its initially validated project cache and the shared cache.
retained_home=$fixture/retained-home
mkdir -p "$retained_home/.cache/dotfiles-wsl/sessions" \
  "$retained_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$retained_home" "$retained_id" retained-session "$missing_pid" \
  "$current_boot_id" 0
make_cache "$retained_home" "$retained_id" 1 32
make_shared_cache "$retained_home" 32
retained_high=$(($(allocated_bytes "$retained_home/.cache/dotfiles-wsl/shared") - 1))
retained_marker=$retained_home/mutated
HOME=$retained_home DOTFILES_AGENT_TEST_GC_MUTATION_MODE=live-owner \
  DOTFILES_AGENT_TEST_GC_LIVE_PID="$$" \
  DOTFILES_AGENT_TEST_GC_LIVE_START_TIME="$current_start_time" \
  DOTFILES_AGENT_TEST_GC_MUTATION_MARKER="$retained_marker" \
  DOTFILES_AGENT_GC_HIGH_BYTES=$retained_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$MUTATION_GC"
test -e "$retained_marker"
test -d "$retained_home/.cache/dotfiles-wsl/sessions/retained-session"
if [ ! -e "$retained_home/.cache/dotfiles-wsl/builds/$retained_id/payload/file-0" ]; then
  echo 'GC removed the cache of a session retained after quarantine' >&2
  exit 1
fi
if [ ! -e "$retained_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0" ]; then
  echo 'GC purged the shared cache while a retained session was live' >&2
  exit 1
fi
test -z "$(find "$retained_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"

# A truly deleted orphan does not protect its project or shared cache.
deleted_orphan_home=$fixture/deleted-orphan-home
mkdir -p "$deleted_orphan_home/.cache/dotfiles-wsl/sessions" \
  "$deleted_orphan_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$deleted_orphan_home" "$deleted_orphan_id" deleted-session \
  "$missing_pid" "$current_boot_id" 0
make_cache "$deleted_orphan_home" "$deleted_orphan_id" 1 32
make_shared_cache "$deleted_orphan_home" 32
deleted_orphan_high=$(($(allocated_bytes \
  "$deleted_orphan_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$deleted_orphan_home DOTFILES_AGENT_GC_HIGH_BYTES=$deleted_orphan_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$deleted_orphan_home/.cache/dotfiles-wsl/sessions/deleted-session"
test ! -e "$deleted_orphan_home/.cache/dotfiles-wsl/builds/$deleted_orphan_id"
test ! -e "$deleted_orphan_home/.cache/dotfiles-wsl/shared/cargo-home/payload"

mutation_project_id=$(printf mutation-project | sha256sum | cut -d ' ' -f 1)
mutation_home=$fixture/mutation-home
mkdir -p "$mutation_home/.cache/dotfiles-wsl/sessions" \
  "$mutation_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$mutation_home" "$active_id" mutated-session "$missing_pid" \
  "$current_boot_id" 0
make_cache "$mutation_home" "$active_id" 1 32
make_shared_cache "$mutation_home" 32
mutation_high=$(($(allocated_bytes "$mutation_home/.cache/dotfiles-wsl/shared") - 1))
mutation_marker=$mutation_home/mutated
HOME=$mutation_home DOTFILES_AGENT_TEST_GC_MUTATION_MODE=restore \
  DOTFILES_AGENT_TEST_GC_MUTATION_PROJECT_ID="$mutation_project_id" \
  DOTFILES_AGENT_TEST_GC_MUTATION_MARKER="$mutation_marker" \
  DOTFILES_AGENT_GC_HIGH_BYTES=$mutation_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$mutation_home/gc.log" "$MUTATION_GC"
test -e "$mutation_marker"
if [ ! -d "$mutation_home/.cache/dotfiles-wsl/sessions/mutated-session" ]; then
  echo "GC stranded a session after quarantine revalidation failure" >&2
  exit 1
fi
test "$(jq -r '.project_id' \
  "$mutation_home/.cache/dotfiles-wsl/sessions/mutated-session/metadata.json")" = \
  "$mutation_project_id"
test -e "$mutation_home/.cache/dotfiles-wsl/builds/$active_id/payload/file-0"
test -e "$mutation_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
test -z "$(find "$mutation_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"
HOME=$mutation_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test ! -e "$mutation_home/.cache/dotfiles-wsl/sessions/mutated-session"

blocked_restore_home=$fixture/blocked-restore-home
mkdir -p "$blocked_restore_home/.cache/dotfiles-wsl/sessions" \
  "$blocked_restore_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$blocked_restore_home" "$active_id" blocked-session "$missing_pid" \
  "$current_boot_id" 0
make_cache "$blocked_restore_home" "$active_id" 1 32
make_shared_cache "$blocked_restore_home" 32
blocked_restore_high=$(($(allocated_bytes \
  "$blocked_restore_home/.cache/dotfiles-wsl/shared") - 1))
blocked_restore_marker=$blocked_restore_home/mutated
HOME=$blocked_restore_home DOTFILES_AGENT_TEST_GC_MUTATION_MODE=block-restore \
  DOTFILES_AGENT_TEST_GC_MUTATION_PROJECT_ID="$mutation_project_id" \
  DOTFILES_AGENT_TEST_GC_MUTATION_MARKER="$blocked_restore_marker" \
  DOTFILES_AGENT_GC_HIGH_BYTES=$blocked_restore_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$blocked_restore_home/gc.log" "$MUTATION_GC"
test -e "$blocked_restore_marker"
test -d "$blocked_restore_home/.cache/dotfiles-wsl/sessions/blocked-session"
test ! -e "$blocked_restore_home/.cache/dotfiles-wsl/sessions/blocked-session/metadata.json"
test -n "$(find "$blocked_restore_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"
test -e "$blocked_restore_home/.cache/dotfiles-wsl/builds/$active_id/payload/file-0"
test -e "$blocked_restore_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
grep -Fq 'cannot restore quarantined session' "$blocked_restore_home/gc.log" || {
  echo "GC omitted the failed-restore diagnostic" >&2
  exit 1
}
rmdir "$blocked_restore_home/.cache/dotfiles-wsl/sessions/blocked-session"
HOME=$blocked_restore_home DOTFILES_AGENT_GC_HIGH_BYTES=$blocked_restore_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$blocked_restore_home/second-gc.log" "$GC"
if [ ! -e "$blocked_restore_home/.cache/dotfiles-wsl/builds/$active_id/payload/file-0" ]; then
  echo 'GC removed a project cache while an unresolved quarantine remained' >&2
  exit 1
fi
if [ ! -e "$blocked_restore_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0" ]; then
  echo 'GC purged the shared cache while an unresolved quarantine remained' >&2
  exit 1
fi
grep -Fq 'unresolved quarantined session' "$blocked_restore_home/second-gc.log"

# An empty, owned quarantine root is a resolved interrupted transaction and
# does not suppress cache collection.
empty_quarantine_home=$fixture/empty-quarantine-home
mkdir -p "$empty_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted" \
  "$empty_quarantine_home/.cache/dotfiles-wsl/builds"
chmod 700 \
  "$empty_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted"
make_cache "$empty_quarantine_home" "$pressure_old_id" 1 32
make_shared_cache "$empty_quarantine_home" 32
empty_quarantine_high=$(($(allocated_bytes \
  "$empty_quarantine_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$empty_quarantine_home DOTFILES_AGENT_GC_HIGH_BYTES=$empty_quarantine_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e \
  "$empty_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted"
test ! -e "$empty_quarantine_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test ! -e "$empty_quarantine_home/.cache/dotfiles-wsl/shared/cargo-home/payload"

# An empty quarantine root with unexpected permissions is ambiguous. It is
# retained and suppresses all cache deletion for the run.
invalid_quarantine_home=$fixture/invalid-quarantine-home
mkdir -p "$invalid_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted" \
  "$invalid_quarantine_home/.cache/dotfiles-wsl/builds"
chmod 755 \
  "$invalid_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted"
make_cache "$invalid_quarantine_home" "$pressure_old_id" 1 32
make_shared_cache "$invalid_quarantine_home" 32
invalid_quarantine_high=$(($(allocated_bytes \
  "$invalid_quarantine_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$invalid_quarantine_home DOTFILES_AGENT_GC_HIGH_BYTES=$invalid_quarantine_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$invalid_quarantine_home/gc.log" "$GC"
test -d \
  "$invalid_quarantine_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted"
test -e "$invalid_quarantine_home/.cache/dotfiles-wsl/builds/$pressure_old_id/payload/file-0"
test -e \
  "$invalid_quarantine_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
grep -Fq 'unresolved quarantined session root' "$invalid_quarantine_home/gc.log"

# A session without metadata has no live owner. It is removed like an orphan
# and protects neither a project cache nor the shared cache.
unclaimed_home=$fixture/unclaimed-session-home
unclaimed_session=$unclaimed_home/.cache/dotfiles-wsl/sessions/unclaimed-session
mkdir -p "$unclaimed_session/tmp/left" "$unclaimed_home/.cache/dotfiles-wsl/builds"
: > "$unclaimed_session/tmp/left/file"
make_session_metadata "$unclaimed_home" "$pressure_old_id" orphan-session \
  "$missing_pid" "$current_boot_id" 0
make_cache "$unclaimed_home" "$pressure_old_id" 1 32
make_shared_cache "$unclaimed_home" 32
unclaimed_high=$(($(allocated_bytes \
  "$unclaimed_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$unclaimed_home DOTFILES_AGENT_GC_HIGH_BYTES=$unclaimed_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$unclaimed_session"
test ! -e "$unclaimed_home/.cache/dotfiles-wsl/sessions/orphan-session"
test ! -e "$unclaimed_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test ! -e "$unclaimed_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
test -z "$(find "$unclaimed_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"

# A session without metadata that the run cannot delete fails the run, but it
# still protects no cache because it has no owner.
unremovable_unclaimed_home=$fixture/unremovable-unclaimed-home
unremovable_unclaimed_session=$unremovable_unclaimed_home/.cache/dotfiles-wsl/sessions/unclaimed-session
mkdir -p "$unremovable_unclaimed_session/tmp/locked" \
  "$unremovable_unclaimed_home/.cache/dotfiles-wsl/builds"
: > "$unremovable_unclaimed_session/tmp/locked/pinned"
chmod 0500 "$unremovable_unclaimed_session/tmp/locked"
make_cache "$unremovable_unclaimed_home" "$pressure_old_id" 1 32
make_shared_cache "$unremovable_unclaimed_home" 32
unremovable_unclaimed_high=$(($(allocated_bytes \
  "$unremovable_unclaimed_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$unremovable_unclaimed_home DOTFILES_AGENT_GC_HIGH_BYTES=$unremovable_unclaimed_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 \
  expect_unresolved "$unremovable_unclaimed_home/gc.log" "$GC"
test -d "$unremovable_unclaimed_session"
test ! -e "$unremovable_unclaimed_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test ! -e "$unremovable_unclaimed_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
grep -Fq 'preserve unremovable-orphan' "$unremovable_unclaimed_home/gc.log"
chmod 0700 "$unremovable_unclaimed_session/tmp/locked"

# An orphan the run cannot delete returns to its own path instead of being
# stranded in a quarantine root, so unrelated caches are still collected.
unremovable_home=$fixture/unremovable-session-home
mkdir -p "$unremovable_home/.cache/dotfiles-wsl/sessions" \
  "$unremovable_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$unremovable_home" "$pressure_old_id" unremovable-session \
  "$missing_pid" "$current_boot_id" 0
unremovable_session=$unremovable_home/.cache/dotfiles-wsl/sessions/unremovable-session
mkdir -p "$unremovable_session/tmp/locked"
: > "$unremovable_session/tmp/locked/pinned"
chmod 0500 "$unremovable_session/tmp/locked"
make_cache "$unremovable_home" "$pressure_old_id" 1 32
make_cache "$unremovable_home" "$stale_id" 40 2
make_shared_cache "$unremovable_home" 32
HOME=$unremovable_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 expect_unresolved "$unremovable_home/gc.log" "$GC"
test -d "$unremovable_session"
test -z "$(find "$unremovable_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"
test -e "$unremovable_home/.cache/dotfiles-wsl/builds/$pressure_old_id/payload/file-0"
test ! -e "$unremovable_home/.cache/dotfiles-wsl/builds/$stale_id"
grep -Fq 'cannot remove quarantined orphan' "$unremovable_home/gc.log"
grep -Fq 'preserve unremovable-orphan' "$unremovable_home/gc.log"
chmod 0700 "$unremovable_session/tmp/locked"

# If a validated empty root changes immediately before rmdir, the run retains
# the root and suppresses cache deletion instead of treating it as resolved.
rmdir_race_home=$fixture/rmdir-race-home
mkdir -p "$rmdir_race_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted" \
  "$rmdir_race_home/.cache/dotfiles-wsl/builds"
chmod 700 "$rmdir_race_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted"
make_cache "$rmdir_race_home" "$pressure_old_id" 1 32
make_shared_cache "$rmdir_race_home" 32
rmdir_race_high=$(($(allocated_bytes \
  "$rmdir_race_home/.cache/dotfiles-wsl/shared") - 1))
rmdir_race_marker=$rmdir_race_home/raced
HOME=$rmdir_race_home DOTFILES_AGENT_TEST_GC_RMDIR_RACE_MARKER=$rmdir_race_marker \
  DOTFILES_AGENT_GC_HIGH_BYTES=$rmdir_race_high DOTFILES_AGENT_GC_LOW_BYTES=0 \
  expect_unresolved "$rmdir_race_home/gc.log" "$RMDIR_RACE_GC"
test -e "$rmdir_race_marker"
test -e \
  "$rmdir_race_home/.cache/dotfiles-wsl/sessions/.gc-quarantine.interrupted/fixture-blocker"
test -e "$rmdir_race_home/.cache/dotfiles-wsl/builds/$pressure_old_id/payload/file-0"
test -e "$rmdir_race_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
grep -Fq 'quarantined session root changed during resolution' "$rmdir_race_home/gc.log"

wrong_owner_home=$fixture/wrong-owner-home
mkdir -p "$wrong_owner_home/.cache/dotfiles-wsl/sessions" \
  "$wrong_owner_home/.cache/dotfiles-wsl/builds"
make_session_metadata "$wrong_owner_home" "$active_id" wrong-owner "$$" \
  "$current_boot_id" "$current_start_time"
HOME=$wrong_owner_home DOTFILES_AGENT_TEST_WRONG_OWNER_PID="$$" \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$WRONG_OWNER_GC"
test -d "$wrong_owner_home/.cache/dotfiles-wsl/sessions/wrong-owner"

# Metadata damaged in place no longer identifies its owner, so the session may
# be live. It is kept, every cache is kept, and the run fails, while ordinary
# orphans are still reclaimed.
damaged_metadata_home=$fixture/damaged-metadata-home
damaged_metadata=$damaged_metadata_home/.cache/dotfiles-wsl/sessions/damaged-session/metadata.json
mkdir -p "${damaged_metadata%/*}/tmp" "$damaged_metadata_home/.cache/dotfiles-wsl/builds"
head -c 4096 /dev/zero > "$damaged_metadata"
damaged_metadata_sum=$(sha256sum < "$damaged_metadata")
make_session_metadata "$damaged_metadata_home" "$pressure_old_id" orphan-session \
  "$missing_pid" "$current_boot_id" 0
make_cache "$damaged_metadata_home" "$pressure_old_id" 40 32
make_shared_cache "$damaged_metadata_home" 32
damaged_metadata_high=$(($(allocated_bytes \
  "$damaged_metadata_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$damaged_metadata_home DOTFILES_AGENT_GC_HIGH_BYTES=$damaged_metadata_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$damaged_metadata_home/gc.log" "$GC"
test ! -e "$damaged_metadata_home/.cache/dotfiles-wsl/sessions/orphan-session"
test -d "${damaged_metadata%/*}/tmp"
test "$(sha256sum < "$damaged_metadata")" = "$damaged_metadata_sum"
test -z "$(find "$damaged_metadata_home/.cache/dotfiles-wsl/sessions" \
  -maxdepth 1 -name '.gc-quarantine.*' -print -quit)"
test -e "$damaged_metadata_home/.cache/dotfiles-wsl/builds/$pressure_old_id/payload/file-0"
test -e "$damaged_metadata_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
grep -Fq "$damaged_metadata" "$damaged_metadata_home/gc.log"

symlink_session_home=$fixture/symlink-session-home
mkdir -p "$symlink_session_home/.cache/dotfiles-wsl/sessions/symlink-metadata" \
  "$symlink_session_home/.cache/dotfiles-wsl/builds"
ln -s /dev/null \
  "$symlink_session_home/.cache/dotfiles-wsl/sessions/symlink-metadata/metadata.json"
if HOME=$symlink_session_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"; then
  echo 'GC accepted symlink session metadata' >&2
  exit 1
fi
test -L "$symlink_session_home/.cache/dotfiles-wsl/sessions/symlink-metadata/metadata.json"

ambiguous_session_home=$fixture/ambiguous-session-home
mkdir -p "$ambiguous_session_home/.cache/dotfiles-wsl/sessions" \
  "$ambiguous_session_home/.cache/dotfiles-wsl/builds" \
  "$ambiguous_session_home/outside"
ln -s "$ambiguous_session_home/outside" \
  "$ambiguous_session_home/.cache/dotfiles-wsl/sessions/ambiguous"
if HOME=$ambiguous_session_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"; then
  echo 'GC accepted ambiguous session path' >&2
  exit 1
fi
test -L "$ambiguous_session_home/.cache/dotfiles-wsl/sessions/ambiguous"

pressure_home=$fixture/pressure-home
mkdir -p "$pressure_home/.cache/dotfiles-wsl/sessions" "$pressure_home/.cache/dotfiles-wsl/builds"
make_cache "$pressure_home" "$pressure_old_id" 2 32
make_cache "$pressure_home" "$pressure_new_id" 1 16
make_shared_cache "$pressure_home" 0
pressure_high=$((
  $(allocated_bytes "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_old_id")
  + $(allocated_bytes "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_new_id")
  + $(allocated_bytes "$pressure_home/.cache/dotfiles-wsl/shared") - 1
))
pressure_low=$((
  $(allocated_bytes "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_new_id")
  + $(allocated_bytes "$pressure_home/.cache/dotfiles-wsl/shared")
))
HOME=$pressure_home DOTFILES_AGENT_GC_HIGH_BYTES=$pressure_high \
  DOTFILES_AGENT_GC_LOW_BYTES=$pressure_low "$GC"
test ! -e "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test -d "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_new_id"

shared_pressure_home=$fixture/shared-pressure-home
mkdir -p "$shared_pressure_home/.cache/dotfiles-wsl/sessions" \
  "$shared_pressure_home/.cache/dotfiles-wsl/builds"
make_cache "$shared_pressure_home" "$pressure_old_id" 1 16
make_shared_cache "$shared_pressure_home" 32
shared_pressure_high=$((
  $(allocated_bytes "$shared_pressure_home/.cache/dotfiles-wsl/shared") - 1
))
HOME=$shared_pressure_home DOTFILES_AGENT_GC_HIGH_BYTES=$shared_pressure_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$shared_pressure_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test ! -e "$shared_pressure_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
test -d "$shared_pressure_home/.cache/dotfiles-wsl/shared/cargo-home"
test -d "$shared_pressure_home/.cache/dotfiles-wsl/shared/xdg-cache"
test -f "$shared_pressure_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"

active_shared_home=$fixture/active-shared-home
mkdir -p "$active_shared_home/.cache/dotfiles-wsl/sessions" \
  "$active_shared_home/.cache/dotfiles-wsl/builds"
make_shared_cache "$active_shared_home" 32
make_cache "$active_shared_home" "$active_id" 1 32
make_session "$active_shared_home" "$active_id"
HOME=$active_shared_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test -e "$active_shared_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
test -e "$active_shared_home/.cache/dotfiles-wsl/builds/$active_id/payload/file-0"

unrecoverable_home=$fixture/unrecoverable-home
mkdir -p "$unrecoverable_home/.cache/dotfiles-wsl/sessions" \
  "$unrecoverable_home/.cache/dotfiles-wsl/builds"
make_shared_cache "$unrecoverable_home" 1
if HOME=$unrecoverable_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted an over-limit cache after shared purge' >&2
  exit 1
fi
test ! -e "$unrecoverable_home/.cache/dotfiles-wsl/shared/cargo-home/payload"

ambiguous_home=$fixture/ambiguous-home
mkdir -p "$ambiguous_home/.cache/dotfiles-wsl/sessions/bad" \
  "$ambiguous_home/.cache/dotfiles-wsl/builds"
make_cache "$ambiguous_home" "$stale_id" 40 2
ln -s nowhere "$ambiguous_home/.cache/dotfiles-wsl/sessions/bad/metadata.json"
if HOME=$ambiguous_home DOTFILES_AGENT_GC_HIGH_BYTES=1 DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted ambiguous session metadata' >&2
  exit 1
fi
test -d "$ambiguous_home/.cache/dotfiles-wsl/builds/$stale_id"

malformed_home=$fixture/malformed-home
mkdir -p "$malformed_home/.cache/dotfiles-wsl/sessions" \
  "$malformed_home/.cache/dotfiles-wsl/builds"
make_cache "$malformed_home" "$stale_id" 40 2
mkdir -p "$malformed_home/.cache/dotfiles-wsl/shared/cargo-home" \
  "$malformed_home/.cache/dotfiles-wsl/shared/xdg-cache"
printf '{}\n' > "$malformed_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"
if HOME=$malformed_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted malformed shared cache marker' >&2
  exit 1
fi
test -d "$malformed_home/.cache/dotfiles-wsl/builds/$stale_id"

unowned_home=$fixture/unowned-home
mkdir -p "$unowned_home/.cache/dotfiles-wsl/sessions" \
  "$unowned_home/.cache/dotfiles-wsl/builds/unowned"
make_shared_cache "$unowned_home" 2
if HOME=$unowned_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted unowned project cache' >&2
  exit 1
fi
test -e "$unowned_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"

symlink_home=$fixture/symlink-home
mkdir -p "$symlink_home/.cache/dotfiles-wsl/sessions" \
  "$symlink_home/.cache/dotfiles-wsl/builds"
make_shared_cache "$symlink_home" 2
ln -s "$symlink_home/.cache/dotfiles-wsl/shared" \
  "$symlink_home/.cache/dotfiles-wsl/builds/symlink-cache"
if HOME=$symlink_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted symlink project cache' >&2
  exit 1
fi
test -e "$symlink_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
