#!/usr/bin/env bash
set -euo pipefail

make_cache() {
  local home=$1 project_id=$2 age=$3 size=$4
  local cache="$home/.cache/dotfiles-wsl/builds/$project_id"
  mkdir -p "$cache"
  jq -cn --arg project_id "$project_id" '{version: 1, project_id: $project_id}' \
    > "$cache/.dotfiles-agent-cache.json"
  truncate -s "$size" "$cache/payload"
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
make_cache "$home" "$stale_id" 40 100
make_cache "$home" "$recent_id" 1 100
make_cache "$home" "$active_id" 40 100
make_session "$home" "$active_id"
mkdir "$home/.cache/dotfiles-wsl/builds/unowned"
truncate -s 100 "$home/.cache/dotfiles-wsl/builds/unowned/payload"
ln -s "$home/.cache/dotfiles-wsl/builds/$recent_id" \
  "$home/.cache/dotfiles-wsl/builds/symlink-cache"

HOME=$home DOTFILES_AGENT_GC_HIGH_BYTES=100000 DOTFILES_AGENT_GC_LOW_BYTES=50000 "$GC"
test ! -e "$home/.cache/dotfiles-wsl/builds/$stale_id"
test -d "$home/.cache/dotfiles-wsl/builds/$recent_id"
test -d "$home/.cache/dotfiles-wsl/builds/$active_id"
test -d "$home/.cache/dotfiles-wsl/builds/unowned"
test -L "$home/.cache/dotfiles-wsl/builds/symlink-cache"
test "$(stat -c %a "$home/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/gc.lock")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds/$recent_id")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/builds/$recent_id/.dotfiles-agent-cache.json")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions/session-$active_id")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions/session-$active_id/metadata.json")" = 600

pressure_home=$fixture/pressure-home
mkdir -p "$pressure_home/.cache/dotfiles-wsl/sessions" "$pressure_home/.cache/dotfiles-wsl/builds"
make_cache "$pressure_home" "$pressure_old_id" 2 400
make_cache "$pressure_home" "$pressure_new_id" 1 400
HOME=$pressure_home DOTFILES_AGENT_GC_HIGH_BYTES=900 DOTFILES_AGENT_GC_LOW_BYTES=650 "$GC"
test ! -e "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_old_id"
test -d "$pressure_home/.cache/dotfiles-wsl/builds/$pressure_new_id"

ambiguous_home=$fixture/ambiguous-home
mkdir -p "$ambiguous_home/.cache/dotfiles-wsl/sessions/bad" \
  "$ambiguous_home/.cache/dotfiles-wsl/builds"
make_cache "$ambiguous_home" "$stale_id" 40 100
ln -s nowhere "$ambiguous_home/.cache/dotfiles-wsl/sessions/bad/metadata.json"
if HOME=$ambiguous_home DOTFILES_AGENT_GC_HIGH_BYTES=1 DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted ambiguous session metadata' >&2
  exit 1
fi
test -d "$ambiguous_home/.cache/dotfiles-wsl/builds/$stale_id"
