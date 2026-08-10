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

make_session() {
  local home=$1 project_id=$2
  local session_id="session-$project_id"
  local session="$home/.cache/dotfiles-wsl/sessions/$session_id"
  local owner_start_time
  owner_start_time=$(awk '{print $22}' "/proc/$$/stat")
  mkdir -p "$session/tmp"
  jq -cn \
    --arg session_id "$session_id" \
    --arg client fixture \
    --arg project_id "$project_id" \
    --arg boot_id "$(cat /proc/sys/kernel/random/boot_id)" \
    --argjson owner_pid "$$" \
    --arg owner_start_time "$owner_start_time" \
    '{version: 1, session_id: $session_id, client: $client, project_id: $project_id,
      boot_id: $boot_id, owner_pid: $owner_pid, owner_start_time: $owner_start_time}' \
    > "$session/metadata.json"
  chmod 0777 "$session"
  chmod 0666 "$session/metadata.json"
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

stale_id=$(printf stale | sha256sum | cut -d ' ' -f 1)
recent_id=$(printf recent | sha256sum | cut -d ' ' -f 1)
active_id=$(printf active | sha256sum | cut -d ' ' -f 1)
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
