#!/usr/bin/env bash
set -euo pipefail

# Cargo 1.98 lays out a build-dir templated with {workspace-path-hash} as
# cargo-build/<2 hex>/<14 hex>/<profile>/ and takes an exclusive flock on
# <profile>/.cargo-build-lock while it builds. A unit keeps its fingerprint in
# .fingerprint/<package>-<hash>/, and Cargo reads its hash file on every build
# that includes the unit. The unit's outputs in deps/ and build/ carry the same hash.
entry_path() {
  printf '%s\n' "$1/.cache/dotfiles-wsl/cargo-build/${2:0:2}/${2:2}"
}

unit_hash() {
  printf '%s' "$1/$2" | sha256sum | cut -c 1-16
}

make_unit() {
  local entry=$1 name=$2 used=$3 file_count=$4 hash profile fingerprint index
  hash=$(unit_hash "$entry" "$name")
  profile=$entry/debug
  fingerprint=$profile/.fingerprint/$name-$hash
  mkdir -p "$fingerprint" "$profile/deps" "$profile/build/$name-$hash/out"
  : > "$profile/.cargo-build-lock"
  printf '%s\n' "$hash" > "$fingerprint/lib-$name"
  : > "$fingerprint/dep-lib-$name"
  printf 'allocated\n' > "$profile/deps/lib$name-$hash.rlib"
  printf 'allocated\n' > "$profile/deps/$name-$hash.d"
  for ((index = 0; index < file_count; index++)); do
    printf 'allocated\n' > "$profile/build/$name-$hash/out/file-$index"
  done
  find "$fingerprint" "$profile/deps/lib$name-$hash.rlib" "$profile/deps/$name-$hash.d" \
    "$profile/build/$name-$hash" -type f -exec touch -d "$used" {} +
}

unit_paths() {
  local entry=$1 name=$2 hash
  hash=$(unit_hash "$entry" "$name")
  printf '%s\n' "$entry/debug/.fingerprint/$name-$hash" "$entry/debug/deps/lib$name-$hash.rlib" \
    "$entry/debug/deps/$name-$hash.d" "$entry/debug/build/$name-$hash"
}

expect_unit() {
  local state=$1 path
  shift
  while IFS= read -r path; do
    if [ "$state" = kept ] && [ ! -e "$path" ]; then
      echo "GC removed a path of a unit it had to keep: $path" >&2
      exit 1
    fi
    if [ "$state" = reclaimed ] && [ -e "$path" ]; then
      echo "GC kept a path of a unit it had to reclaim: $path" >&2
      exit 1
    fi
  done < <(unit_paths "$@")
}

unit_bytes() {
  local -a paths
  mapfile -t paths < <(unit_paths "$@")
  du -s -c -B1 -- "${paths[@]}" | tail -n 1 | cut -f 1
}

# A test binary in deps/ that keeps running until it is killed. It was built with its
# unit, so it carries the unit's last use.
make_test_binary() {
  printf '#!%s\nsleep "$1"\n' "$BASH" > "$1"
  chmod +x "$1"
  touch -d "$2" "$1"
}

# Sessions use the launcher's name form PROJECT_ID.CLIENT.SUFFIX.
session_project_id=$(printf session-project | sha256sum | cut -d ' ' -f 1)
session_path() {
  printf '%s\n' "$1/.cache/dotfiles-wsl/sessions/$session_project_id.fixture.$2"
}

write_session_metadata() {
  local target=$1 session_id=$2 owner_pid=$3 boot_id=$4 owner_start_time=$5
  jq -cn \
    --arg session_id "$session_id" \
    --arg client fixture \
    --arg project_id "$session_project_id" \
    --arg boot_id "$boot_id" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start_time "$owner_start_time" \
    '{version: 1, session_id: $session_id, client: $client, project_id: $project_id,
      boot_id: $boot_id, owner_pid: $owner_pid, owner_start_time: $owner_start_time}' \
    > "$target"
}

make_session_metadata() {
  local home=$1 suffix=$2 owner_pid=$3 boot_id=$4 owner_start_time=$5 session
  session=$(session_path "$home" "$suffix")
  mkdir -p "$session/tmp"
  write_session_metadata "$session/metadata.json" "${session##*/}" \
    "$owner_pid" "$boot_id" "$owner_start_time"
  chmod 0777 "$session"
  chmod 0666 "$session/metadata.json"
}

make_session() {
  make_session_metadata "$1" live "$$" "$current_boot_id" "$current_start_time"
}

make_home() {
  mkdir -p "$1/.cache/dotfiles-wsl/sessions" "$1/.cache/dotfiles-wsl/cargo-build"
  chmod 0777 "$1/.cache/dotfiles-wsl" "$1/.cache/dotfiles-wsl/sessions" \
    "$1/.cache/dotfiles-wsl/cargo-build"
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

cache_bytes() {
  printf '%s\n' "$((
    $(allocated_bytes "$1/.cache/dotfiles-wsl/shared")
    + $(allocated_bytes "$1/.cache/dotfiles-wsl/cargo-build")
  ))"
}

trash_is_empty() {
  test -z "$(find "$1/.cache/dotfiles-wsl/trash" -mindepth 1 -print -quit)"
}

expect_unresolved() {
  local log=$1
  shift
  if "$@" 2>"$log"; then
    echo "GC reported success while cache entries remained unresolved: $log" >&2
    exit 1
  fi
  grep -Fq 'agent cache entries remain unresolved' "$log"
}

wait_for() {
  local path=$1
  for _ in {1..600}; do
    [ ! -e "$path" ] || return 0
    sleep 0.05
  done
  echo "timed out waiting for $path" >&2
  exit 1
}

# A dry run must leave every file, link and mode as it found them.
tree_state() {
  find "$1" -type f -printf '%p %s %T@\n' -o -type l -printf '%p -> %l\n' -o -type d -printf '%p/ %m\n' | sort
}

expect_report() {
  local report=$1
  shift
  awk -F'\t' -v verdict="$1" -v kind="$2" -v subject="$3" -v reason="$4" '
    $1 == verdict && $2 == kind && $4 == subject && $5 == reason { found = 1 }
    END { exit !found }
  ' "$report" || {
    echo "dry-run report lacks: $*" >&2
    cat "$report" >&2
    exit 1
  }
}

refute_report() {
  local report=$1 subject=$2
  if grep -Fq -- "$subject" "$report"; then
    echo "dry-run report names a path it must not: $subject" >&2
    cat "$report" >&2
    exit 1
  fi
}

# A script that carries the name of the retired verification-cache and runs until its release file exists.
start_runner() {
  local release=$1 index
  mkdir -p "$fixture/runner"
  printf '#!%s\nuntil [ -e "$1" ]; do sleep 0.05; done\n' "$BASH" > "$fixture/runner/dotfiles-agent-verification-cache"
  chmod +x "$fixture/runner/dotfiles-agent-verification-cache"
  "$fixture/runner/dotfiles-agent-verification-cache" "$release" < /dev/null > /dev/null 2>&1 &
  runner_pid=$!
  for ((index = 0; index < 200; index++)); do
    if tr '\0' ' ' < "/proc/$runner_pid/cmdline" | grep -Fq dotfiles-agent-verification-cache; then
      return 0
    fi
    sleep 0.05
  done
  echo 'runner did not start' >&2
  exit 1
}

first_entry_id=$(printf first-entry | sha256sum | cut -c 1-16)
second_entry_id=$(printf second-entry | sha256sum | cut -c 1-16)
locked_entry_id=$(printf locked-entry | sha256sum | cut -c 1-16)
current_boot_id=$(cat /proc/sys/kernel/random/boot_id)
current_start_time=$(awk '{print $22}' "/proc/$$/stat")
missing_pid=999999999
test ! -e "/proc/$missing_pid"

fixture=$PWD/gc-fixture

# A unit that no build used for the inactivity limit goes even below the high
# watermark, while units a build used stay in the same entry, a live session or not.
home=$fixture/home
make_home "$home"
make_session "$home"
make_shared_cache "$home" 2
entry=$(entry_path "$home" "$first_entry_id")
make_unit "$entry" old '40 days ago' 4
make_unit "$entry" recent '1 day ago' 4
# A fresh build compiles nothing and writes nothing, but it reads the hash file.
make_unit "$entry" fresh '40 days ago' 4
touch -a -d '1 hour ago' "$entry/debug/.fingerprint/fresh-$(unit_hash "$entry" fresh)/lib-fresh"
# Cargo reads the fingerprint JSON only for a unit it then rebuilds, so a tool that
# only inspected the JSON does not make an old unit look used.
make_unit "$entry" inspected '40 days ago' 4
inspected_json=$entry/debug/.fingerprint/inspected-$(unit_hash "$entry" inspected)/lib-inspected.json
printf '{}\n' > "$inspected_json"
touch -m -d '40 days ago' "$inspected_json"
touch -a -d '1 hour ago' "$inspected_json"
# Cargo never finds outputs fresh without a fingerprint carrying their hash, so they
# go once nothing wrote or read them for 48 hours.
printf 'allocated\n' > "$entry/debug/deps/liborphan-0123456789abcdef.rlib"
mkdir -p "$entry/debug/build/orphan-0123456789abcdef/out"
touch -d '3 days ago' "$entry/debug/deps/liborphan-0123456789abcdef.rlib" \
  "$entry/debug/build/orphan-0123456789abcdef/out" "$entry/debug/build/orphan-0123456789abcdef"
printf 'allocated\n' > "$entry/debug/deps/libnew_orphan-fedcba9876543210.rlib"
# An output without the hash in its name cannot be matched to a unit and stays.
printf 'allocated\n' > "$entry/debug/deps/libplain.so"
# rustc names incremental directories with its own hash, so only their age counts.
mkdir -p "$entry/debug/incremental/old-0abc/s-old" "$entry/debug/incremental/recent-0def/s-new"
touch -d '40 days ago' "$entry/debug/incremental/old-0abc/s-old" "$entry/debug/incremental/old-0abc"
lock_inode=$(stat -c %i "$entry/debug/.cargo-build-lock")
# Under relatime a read moves an atime older than the mtime, so this atime shows
# whether the GC read the file instead of only calling stat.
recent_hash_file=$entry/debug/.fingerprint/recent-$(unit_hash "$entry" recent)/lib-recent
touch -a -d '2 days ago' "$recent_hash_file"
recent_atime=$(stat -c %X "$recent_hash_file")
HOME=$home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
expect_unit reclaimed "$entry" old
expect_unit kept "$entry" recent
expect_unit kept "$entry" fresh
expect_unit reclaimed "$entry" inspected
test ! -e "$entry/debug/deps/liborphan-0123456789abcdef.rlib"
test ! -e "$entry/debug/build/orphan-0123456789abcdef"
test -e "$entry/debug/deps/libnew_orphan-fedcba9876543210.rlib"
test -e "$entry/debug/deps/libplain.so"
test ! -e "$entry/debug/incremental/old-0abc"
test -d "$entry/debug/incremental/recent-0def"
# A Cargo that opened the lock file before the reclaim waits on that inode, so
# the lock file stays at its path and the waiter excludes later builds.
test "$(stat -c %i "$entry/debug/.cargo-build-lock")" = "$lock_inode"
test "$(stat -c %X "$recent_hash_file")" = "$recent_atime"
test -d "$(session_path "$home" live)"
trash_is_empty "$home"
test "$(stat -c %a "$home/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/sessions")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/cargo-build")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/trash")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/cargo-home")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/xdg-cache")" = 700
test "$(stat -c %a "$home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json")" = 600
test "$(stat -c %a "$home/.cache/dotfiles-wsl/gc.lock")" = 600
test "$(stat -c %a "$(session_path "$home" live)")" = 700
test "$(stat -c %a "$(session_path "$home" live)/metadata.json")" = 600

# A live build can remove or lock files while the GC walks a cache. du and find
# then exit non-zero but still report the rest, and the GC run must still succeed.
partial_home=$fixture/partial-home
make_home "$partial_home"
partial_entry=$(entry_path "$partial_home" "$first_entry_id")
make_unit "$partial_entry" recent '1 day ago' 2
partial_unreadable=$partial_entry/debug/build/recent-$(unit_hash "$partial_entry" recent)/out/unreadable
mkdir -m 000 "$partial_unreadable"
HOME=$partial_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
expect_unit kept "$partial_entry" recent
chmod 700 "$partial_unreadable"

orphan_home=$fixture/orphan-home
make_home "$orphan_home"
make_session_metadata "$orphan_home" missing-owner "$missing_pid" "$current_boot_id" 0
make_session_metadata "$orphan_home" boot-mismatch "$$" \
  00000000-0000-0000-0000-000000000000 "$current_start_time"
make_session_metadata "$orphan_home" start-mismatch "$$" "$current_boot_id" 0
make_session "$orphan_home"
HOME=$orphan_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
for orphan_session in missing-owner boot-mismatch start-mismatch; do
  if [ -e "$(session_path "$orphan_home" "$orphan_session")" ]; then
    echo "GC retained orphan session: $orphan_session" >&2
    exit 1
  fi
done
test -d "$(session_path "$orphan_home" live)"
trash_is_empty "$orphan_home"

# A dead launcher whose session scope still has processes keeps its session.
scope_home=$fixture/scope-home
scope_cgroup=$fixture/cgroup
make_home "$scope_home"
make_session_metadata "$scope_home" 4242.scoped "$missing_pid" "$current_boot_id" 0
mkdir -p "$scope_cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice/dotfiles-agent-fixture.4242.scoped.scope"
HOME=$scope_home DOTFILES_AGENT_CGROUP_ROOT=$scope_cgroup \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test -d "$(session_path "$scope_home" 4242.scoped)"
rm -r "$scope_cgroup"
HOME=$scope_home DOTFILES_AGENT_CGROUP_ROOT=$scope_cgroup \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test ! -e "$(session_path "$scope_home" 4242.scoped)"

# A truly deleted orphan does not protect the shared cache.
deleted_orphan_home=$fixture/deleted-orphan-home
make_home "$deleted_orphan_home"
make_session_metadata "$deleted_orphan_home" deleted "$missing_pid" "$current_boot_id" 0
deleted_orphan_entry=$(entry_path "$deleted_orphan_home" "$first_entry_id")
make_unit "$deleted_orphan_entry" idle '3 days ago' 32
make_shared_cache "$deleted_orphan_home" 32
deleted_orphan_high=$(($(allocated_bytes \
  "$deleted_orphan_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$deleted_orphan_home DOTFILES_AGENT_GC_HIGH_BYTES=$deleted_orphan_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$(session_path "$deleted_orphan_home" deleted)"
expect_unit reclaimed "$deleted_orphan_entry" idle
test ! -e "$deleted_orphan_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
trash_is_empty "$deleted_orphan_home"

# A session without metadata has no live owner. It is removed like an orphan
# and does not protect the shared cache.
unclaimed_home=$fixture/unclaimed-session-home
unclaimed_session=$(session_path "$unclaimed_home" unclaimed)
make_home "$unclaimed_home"
mkdir -p "$unclaimed_session/tmp/left"
: > "$unclaimed_session/tmp/left/file"
unclaimed_entry=$(entry_path "$unclaimed_home" "$first_entry_id")
make_unit "$unclaimed_entry" idle '3 days ago' 32
make_shared_cache "$unclaimed_home" 32
unclaimed_high=$(($(allocated_bytes "$unclaimed_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$unclaimed_home DOTFILES_AGENT_GC_HIGH_BYTES=$unclaimed_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$unclaimed_session"
expect_unit reclaimed "$unclaimed_entry" idle
test ! -e "$unclaimed_home/.cache/dotfiles-wsl/shared/cargo-home/payload"

readonly_home=$fixture/readonly-session-home
readonly_session=$(session_path "$readonly_home" readonly)
readonly_external=$fixture/readonly-external
make_home "$readonly_home"
make_session_metadata "$readonly_home" readonly "$missing_pid" "$current_boot_id" 0
mkdir -p "$readonly_session/tmp/locked/nested" "$readonly_external"
: > "$readonly_session/tmp/locked/nested/payload"
: > "$readonly_external/preserved"
ln -s "$readonly_external" "$readonly_session/tmp/locked/external"
chmod 0500 "$readonly_session/tmp/locked" "$readonly_external"
chmod 0000 "$readonly_session/tmp/locked/nested"
HOME=$readonly_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test ! -e "$readonly_session"
trash_is_empty "$readonly_home"
test -f "$readonly_external/preserved"
test "$(stat -c %a "$readonly_external")" = 500
chmod 0700 "$readonly_external"

wrong_owner_home=$fixture/wrong-owner-home
make_home "$wrong_owner_home"
make_session "$wrong_owner_home"
HOME=$wrong_owner_home DOTFILES_AGENT_TEST_WRONG_OWNER_PID="$$" \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$WRONG_OWNER_GC"
test -d "$(session_path "$wrong_owner_home" live)"

# Metadata damaged in place no longer identifies its owner, so the session may
# be live. It is kept, it blocks the shared cache purge, and the run fails,
# while ordinary orphans and unused units are still reclaimed.
damaged_metadata_home=$fixture/damaged-metadata-home
damaged_session=$(session_path "$damaged_metadata_home" damaged)
damaged_metadata=$damaged_session/metadata.json
make_home "$damaged_metadata_home"
mkdir -p "$damaged_session/tmp"
head -c 4096 /dev/zero > "$damaged_metadata"
damaged_metadata_sum=$(sha256sum < "$damaged_metadata")
make_session_metadata "$damaged_metadata_home" orphan "$missing_pid" "$current_boot_id" 0
damaged_entry=$(entry_path "$damaged_metadata_home" "$first_entry_id")
make_unit "$damaged_entry" old '40 days ago' 32
make_shared_cache "$damaged_metadata_home" 32
damaged_metadata_high=$(($(allocated_bytes \
  "$damaged_metadata_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$damaged_metadata_home DOTFILES_AGENT_GC_HIGH_BYTES=$damaged_metadata_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 expect_unresolved "$damaged_metadata_home/gc.log" "$GC"
test ! -e "$(session_path "$damaged_metadata_home" orphan)"
test -d "$damaged_session/tmp"
test "$(sha256sum < "$damaged_metadata")" = "$damaged_metadata_sum"
expect_unit reclaimed "$damaged_entry" old
test -e "$damaged_metadata_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
grep -Fq "$damaged_metadata" "$damaged_metadata_home/gc.log"

# While the GC removes large units, it does not hold gc.lock. A launcher started
# during the removal completes while the removal is still blocked.
slow_home=$fixture/slow-home
slow_ready=$fixture/slow-ready
slow_release=$fixture/slow-release
make_home "$slow_home"
slow_entry=$(entry_path "$slow_home" "$first_entry_id")
make_unit "$slow_entry" old '40 days ago' 64
make_unit "$slow_entry" recent '1 day ago' 2
make_session "$slow_home"
HOME=$slow_home DOTFILES_AGENT_TEST_RM_READY=$slow_ready \
  DOTFILES_AGENT_TEST_RM_RELEASE=$slow_release \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
  "$SLOW_RM_GC" &
slow_gc_pid=$!
wait_for "$slow_ready"
mkdir -p "$fixture/outside"
set +e
(
  cd "$fixture/outside"
  HOME=$slow_home SYSTEMD_RUN_CAPTURE=$fixture/systemd-run \
    timeout 30 "$LAUNCHER" fixture-client "$(type -P true)"
)
launcher_status=$?
set -e
if [ "$launcher_status" -ne 0 ]; then
  echo "launcher did not finish while the GC removed units: status $launcher_status" >&2
  exit 1
fi
kill -0 "$slow_gc_pid"
: > "$slow_release"
wait "$slow_gc_pid"
expect_unit reclaimed "$slow_entry" old
expect_unit kept "$slow_entry" recent
trash_is_empty "$slow_home"

# A run killed in the middle of a removal leaves a partial entry in trash, and the
# next run removes it and succeeds.
killed_home=$fixture/killed-home
killed_ready=$fixture/killed-ready
make_home "$killed_home"
killed_entry=$(entry_path "$killed_home" "$first_entry_id")
make_unit "$killed_entry" old '40 days ago' 16
HOME=$killed_home DOTFILES_AGENT_TEST_RM_READY=$killed_ready \
  DOTFILES_AGENT_TEST_RM_RELEASE=$fixture/never-released \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
  "$SLOW_RM_GC" &
killed_gc_pid=$!
wait_for "$killed_ready"
kill -KILL "$killed_gc_pid" "$(cat "$killed_ready")"
wait "$killed_gc_pid" || true
test -n "$(find "$killed_home/.cache/dotfiles-wsl/trash" -mindepth 1 -maxdepth 1 -print -quit)"
HOME=$killed_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
trash_is_empty "$killed_home"
expect_unit reclaimed "$killed_entry" old

symlink_session_home=$fixture/symlink-session-home
symlink_session=$(session_path "$symlink_session_home" symlink)
make_home "$symlink_session_home"
mkdir -p "$symlink_session"
ln -s /dev/null "$symlink_session/metadata.json"
if HOME=$symlink_session_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"; then
  echo 'GC accepted symlink session metadata' >&2
  exit 1
fi
test -L "$symlink_session/metadata.json"

ambiguous_session_home=$fixture/ambiguous-session-home
make_home "$ambiguous_session_home"
mkdir -p "$ambiguous_session_home/outside"
ln -s "$ambiguous_session_home/outside" "$(session_path "$ambiguous_session_home" ambiguous)"
if HOME=$ambiguous_session_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"; then
  echo 'GC accepted ambiguous session path' >&2
  exit 1
fi
test -L "$(session_path "$ambiguous_session_home" ambiguous)"

# Above the high watermark, units go by their last use across every entry until
# the total reaches the low watermark. An entry whose lock Cargo holds is not touched.
pressure_home=$fixture/pressure-home
make_home "$pressure_home"
make_shared_cache "$pressure_home" 0
make_session "$pressure_home"
locked_entry=$(entry_path "$pressure_home" "$locked_entry_id")
first_entry=$(entry_path "$pressure_home" "$first_entry_id")
second_entry=$(entry_path "$pressure_home" "$second_entry_id")
make_unit "$locked_entry" locked '50 days ago' 8
make_unit "$first_entry" oldest '10 days ago' 8
make_unit "$second_entry" middle '7 days ago' 8
make_unit "$first_entry" newer '5 days ago' 8
make_unit "$second_entry" newest '1 hour ago' 8
pressure_total=$(cache_bytes "$pressure_home")
pressure_low=$((
  pressure_total - $(unit_bytes "$first_entry" oldest) - $(unit_bytes "$second_entry" middle)
  + $(unit_bytes "$first_entry" newer) / 2
))
exec {cargo_lock_fd}<"$locked_entry/debug/.cargo-build-lock"
flock -x "$cargo_lock_fd"
HOME=$pressure_home DOTFILES_AGENT_GC_HIGH_BYTES=$((pressure_total - 1)) \
  DOTFILES_AGENT_GC_LOW_BYTES=$pressure_low "$GC"
exec {cargo_lock_fd}<&-
expect_unit kept "$locked_entry" locked
expect_unit reclaimed "$first_entry" oldest
expect_unit reclaimed "$second_entry" middle
expect_unit kept "$first_entry" newer
expect_unit kept "$second_entry" newest
test -d "$(session_path "$pressure_home" live)"
test "$(cache_bytes "$pressure_home")" -le "$pressure_low"
trash_is_empty "$pressure_home"

# Cargo reads the hash file of every unit when an invocation starts and releases its
# lock before it runs test binaries. Under relatime that read leaves an atime at most
# 24 hours older than the start, so a unit read within 48 hours stays even under
# capacity pressure, while its test binary runs without any lock.
running_home=$fixture/running-entry-home
make_home "$running_home"
make_session "$running_home"
running_entry=$(entry_path "$running_home" "$first_entry_id")
make_unit "$running_entry" tested '40 days ago' 2
running_binary=$running_entry/debug/deps/tested-$(unit_hash "$running_entry" tested)
make_test_binary "$running_binary" '40 days ago'
touch -a -d '47 hours ago' \
  "$running_entry/debug/.fingerprint/tested-$(unit_hash "$running_entry" tested)/lib-tested"
"$running_binary" 300 &
running_pid=$!
HOME=$running_home DOTFILES_AGENT_GC_HIGH_BYTES=1 DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
kill "$running_pid"
wait "$running_pid" || true
expect_unit kept "$running_entry" tested
test -e "$running_binary"

# The 48 hours do not depend on a running process. A unit read 47 hours ago stays under
# capacity pressure, and a unit read 49 hours ago goes.
recent_use_home=$fixture/recent-use-home
make_home "$recent_use_home"
make_session "$recent_use_home"
recent_use_entry=$(entry_path "$recent_use_home" "$first_entry_id")
make_unit "$recent_use_entry" within '40 days ago' 2
make_unit "$recent_use_entry" beyond '40 days ago' 2
touch -a -d '47 hours ago' \
  "$recent_use_entry/debug/.fingerprint/within-$(unit_hash "$recent_use_entry" within)/lib-within"
touch -a -d '49 hours ago' \
  "$recent_use_entry/debug/.fingerprint/beyond-$(unit_hash "$recent_use_entry" beyond)/lib-beyond"
HOME=$recent_use_home DOTFILES_AGENT_GC_HIGH_BYTES=1 DOTFILES_AGENT_GC_LOW_BYTES=0 \
  "$GC" 2> "$recent_use_home/gc.log"
expect_unit kept "$recent_use_entry" within
expect_unit reclaimed "$recent_use_entry" beyond
# What stays above the high watermark is reported, and the next run retries it.
grep -Fq 'remain above the high watermark' "$recent_use_home/gc.log"

# A test runner can execute a test binary without Cargo, which reads no fingerprint.
# Running or reading any output of a unit counts as using it.
direct_home=$fixture/direct-use-home
make_home "$direct_home"
direct_entry=$(entry_path "$direct_home" "$first_entry_id")
make_unit "$direct_entry" executed '40 days ago' 2
make_unit "$direct_entry" idle '40 days ago' 2
direct_rlib=$direct_entry/debug/deps/libexecuted-$(unit_hash "$direct_entry" executed).rlib
touch -m -d '40 days ago' "$direct_rlib"
touch -a -d '1 hour ago' "$direct_rlib"
HOME=$direct_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
expect_unit kept "$direct_entry" executed
expect_unit reclaimed "$direct_entry" idle

# A process that starts running a file of the entry after the GC chose its units can
# read any unit of the entry, as a test reads its OUT_DIR. Under Cargo's lock the GC
# looks for such a process and leaves the whole entry.
exec_race_home=$fixture/exec-race-home
make_home "$exec_race_home"
exec_race_entry=$(entry_path "$exec_race_home" "$first_entry_id")
make_unit "$exec_race_entry" data '40 days ago' 2
cp "$(type -P sleep)" "$exec_race_entry/debug/deps/sleep"
touch -d '40 days ago' "$exec_race_entry/debug/deps/sleep"
{
  printf '%q 300 < /dev/null > /dev/null 2>&1 &\n' "$exec_race_entry/debug/deps/sleep"
  printf 'printf "%%s\\n" "$!" > %q\n' "$fixture/exec-race.pid"
} > "$fixture/exec-start.sh"
HOME=$exec_race_home DOTFILES_AGENT_TEST_BEFORE_RECLAIM=$fixture/exec-start.sh \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$RACING_GC"
exec_race_pid=$(cat "$fixture/exec-race.pid")
test "$(readlink "/proc/$exec_race_pid/exe")" = "$exec_race_entry/debug/deps/sleep"
kill "$exec_race_pid"
expect_unit kept "$exec_race_entry" data

# A test that starts after the GC chose its unit read the unit's hash file first, so
# the check under Cargo's lock keeps the running binary.
test_race_home=$fixture/test-race-home
make_home "$test_race_home"
test_race_entry=$(entry_path "$test_race_home" "$first_entry_id")
make_unit "$test_race_entry" tested '40 days ago' 2
test_race_binary=$test_race_entry/debug/deps/tested-$(unit_hash "$test_race_entry" tested)
make_test_binary "$test_race_binary" '40 days ago'
{
  printf 'cat -- %q > /dev/null\n' \
    "$test_race_entry/debug/.fingerprint/tested-$(unit_hash "$test_race_entry" tested)/lib-tested"
  printf '%q 300 < /dev/null > /dev/null 2>&1 &\n' "$test_race_binary"
  printf 'printf "%%s\\n" "$!" > %q\n' "$fixture/test-race.pid"
} > "$fixture/test-start.sh"
HOME=$test_race_home DOTFILES_AGENT_TEST_BEFORE_RECLAIM=$fixture/test-start.sh \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$RACING_GC"
kill "$(cat "$fixture/test-race.pid")"
expect_unit kept "$test_race_entry" tested
test -e "$test_race_binary"

# Without atime updates a fresh build leaves no trace, so the GC reclaims no unit and
# fails instead of judging use from stale times.
noatime_home=$fixture/noatime-home
make_home "$noatime_home"
noatime_entry=$(entry_path "$noatime_home" "$first_entry_id")
make_unit "$noatime_entry" old '40 days ago' 2
HOME=$noatime_home DOTFILES_AGENT_TEST_MOUNT_OPTIONS=rw,noatime \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
  expect_unresolved "$noatime_home/gc.log" "$MOUNT_OPTIONS_GC"
grep -Fq 'atime' "$noatime_home/gc.log"
expect_unit kept "$noatime_entry" old

# A build that uses a unit after the GC chose it reads the unit's hash file. The GC
# checks the unit again under Cargo's lock and keeps it, even with no capacity pressure.
fresh_race_home=$fixture/fresh-race-home
make_home "$fresh_race_home"
fresh_race_entry=$(entry_path "$fresh_race_home" "$first_entry_id")
make_unit "$fresh_race_entry" old '40 days ago' 4
fresh_race_hash_file=$fresh_race_entry/debug/.fingerprint/old-$(unit_hash "$fresh_race_entry" old)/lib-old
printf 'cat -- %q > /dev/null\n' "$fresh_race_hash_file" > "$fixture/fresh-use.sh"
HOME=$fresh_race_home DOTFILES_AGENT_TEST_BEFORE_RECLAIM=$fixture/fresh-use.sh \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$RACING_GC"
test -e "$fixture/fresh-use.sh.done"
expect_unit kept "$fresh_race_entry" old
# Reading the hash file moved its atime, as Cargo's fresh build does on this file system.
test "$(stat -c %X "$fresh_race_hash_file")" -gt "$(date -d '1 day ago' +%s)"

# A build that takes the lock of the entry the GC chose under capacity pressure makes
# the GC skip that entry and reclaim the next unit by last use until the low watermark.
busy_pressure_home=$fixture/busy-pressure-home
make_home "$busy_pressure_home"
make_shared_cache "$busy_pressure_home" 0
make_session "$busy_pressure_home"
busy_pressure_old=$(entry_path "$busy_pressure_home" "$first_entry_id")
busy_pressure_new=$(entry_path "$busy_pressure_home" "$second_entry_id")
make_unit "$busy_pressure_old" oldest '10 days ago' 8
make_unit "$busy_pressure_new" newer '3 days ago' 32
busy_pressure_total=$(cache_bytes "$busy_pressure_home")
busy_pressure_low=$((busy_pressure_total - $(unit_bytes "$busy_pressure_old" oldest)))
{
  printf 'flock --no-fork -x %q sleep 300 < /dev/null > /dev/null 2>&1 &\n' \
    "$busy_pressure_old/debug/.cargo-build-lock"
  printf 'printf "%%s\\n" "$!" > %q\n' "$fixture/busy-pressure.pid"
  printf 'while flock -n -s %q true; do sleep 0.05; done\n' "$busy_pressure_old/debug/.cargo-build-lock"
} > "$fixture/busy-pressure.sh"
HOME=$busy_pressure_home DOTFILES_AGENT_TEST_BEFORE_RECLAIM=$fixture/busy-pressure.sh \
  DOTFILES_AGENT_GC_HIGH_BYTES=$((busy_pressure_total - 1)) \
  DOTFILES_AGENT_GC_LOW_BYTES=$busy_pressure_low "$RACING_GC"
kill "$(cat "$fixture/busy-pressure.pid")"
expect_unit kept "$busy_pressure_old" oldest
expect_unit reclaimed "$busy_pressure_new" newer
test "$(cache_bytes "$busy_pressure_home")" -le "$busy_pressure_low"
trash_is_empty "$busy_pressure_home"

shared_pressure_home=$fixture/shared-pressure-home
make_home "$shared_pressure_home"
shared_pressure_entry=$(entry_path "$shared_pressure_home" "$first_entry_id")
make_unit "$shared_pressure_entry" idle '3 days ago' 16
make_shared_cache "$shared_pressure_home" 32
shared_pressure_high=$((
  $(allocated_bytes "$shared_pressure_home/.cache/dotfiles-wsl/shared") - 1
))
HOME=$shared_pressure_home DOTFILES_AGENT_GC_HIGH_BYTES=$shared_pressure_high \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
expect_unit reclaimed "$shared_pressure_entry" idle
test ! -e "$shared_pressure_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
test -d "$shared_pressure_home/.cache/dotfiles-wsl/shared/cargo-home"
test -d "$shared_pressure_home/.cache/dotfiles-wsl/shared/xdg-cache"
test -f "$shared_pressure_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"
trash_is_empty "$shared_pressure_home"

active_shared_home=$fixture/active-shared-home
make_home "$active_shared_home"
make_shared_cache "$active_shared_home" 32
make_session "$active_shared_home"
HOME=$active_shared_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test -e "$active_shared_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"

unrecoverable_home=$fixture/unrecoverable-home
make_home "$unrecoverable_home"
make_shared_cache "$unrecoverable_home" 1
if HOME=$unrecoverable_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted an over-limit cache after shared purge' >&2
  exit 1
fi
test ! -e "$unrecoverable_home/.cache/dotfiles-wsl/shared/cargo-home/payload"

# Without a session the shared cache goes first, and units the 48 hours protect may
# still keep the total above the high watermark. Time ends that excess, so the GC
# records it and succeeds, as it does with a session.
protected_home=$fixture/protected-no-session-home
make_home "$protected_home"
make_shared_cache "$protected_home" 2
protected_entry=$(entry_path "$protected_home" "$first_entry_id")
make_unit "$protected_entry" recent '1 day ago' 32
protected_after_purge=$((
  $(cache_bytes "$protected_home")
  - $(allocated_bytes "$protected_home/.cache/dotfiles-wsl/shared/cargo-home/payload")
))
HOME=$protected_home \
  DOTFILES_AGENT_GC_HIGH_BYTES=$((protected_after_purge - $(unit_bytes "$protected_entry" recent) / 2)) \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC" 2> "$protected_home/gc.log"
expect_unit kept "$protected_entry" recent
test ! -e "$protected_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
grep -Fq 'remain above the high watermark' "$protected_home/gc.log"

ambiguous_home=$fixture/ambiguous-home
make_home "$ambiguous_home"
mkdir -p "$(session_path "$ambiguous_home" bad)"
ambiguous_entry=$(entry_path "$ambiguous_home" "$first_entry_id")
make_unit "$ambiguous_entry" old '40 days ago' 2
ln -s nowhere "$(session_path "$ambiguous_home" bad)/metadata.json"
if HOME=$ambiguous_home DOTFILES_AGENT_GC_HIGH_BYTES=1 DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted ambiguous session metadata' >&2
  exit 1
fi
expect_unit kept "$ambiguous_entry" old

malformed_home=$fixture/malformed-home
make_home "$malformed_home"
malformed_entry=$(entry_path "$malformed_home" "$first_entry_id")
make_unit "$malformed_entry" old '40 days ago' 2
mkdir -p "$malformed_home/.cache/dotfiles-wsl/shared/cargo-home" \
  "$malformed_home/.cache/dotfiles-wsl/shared/xdg-cache"
printf '{}\n' > "$malformed_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"
if HOME=$malformed_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted malformed shared cache marker' >&2
  exit 1
fi
expect_unit kept "$malformed_entry" old

# A build-dir root that is not the GC's own directory fails the run before
# anything is removed, and what it points to stays.
symlink_root_home=$fixture/symlink-root-home
mkdir -p "$symlink_root_home/.cache/dotfiles-wsl/sessions" "$fixture/symlink-root-target"
printf 'kept\n' > "$fixture/symlink-root-target/payload"
ln -s "$fixture/symlink-root-target" "$symlink_root_home/.cache/dotfiles-wsl/cargo-build"
if HOME=$symlink_root_home DOTFILES_AGENT_GC_HIGH_BYTES=1 \
  DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"; then
  echo 'GC accepted a symlink build-dir root' >&2
  exit 1
fi
test "$(cat "$fixture/symlink-root-target/payload")" = kept

# ---- Observation never deletes. Help and unknown arguments act before anything exists or changes.
absent_home=$fixture/absent-home
mkdir -p "$absent_home"
HOME=$absent_home "$GC" --help > "$fixture/usage"
grep -Fq 'usage: dotfiles-agent-project-cache-gc [--dry-run]' "$fixture/usage"
HOME=$absent_home "$GC" --dry-run > "$fixture/absent-report"
awk -F'\t' '$1 == "summary" && $2 == "cache" && $3 == 0 { found = 1 } END { exit !found }' "$fixture/absent-report"
status=0
HOME=$absent_home "$GC" --purge 2> "$fixture/usage-error" || status=$?
test "$status" -eq 64
grep -Fq 'usage: dotfiles-agent-project-cache-gc' "$fixture/usage-error"
status=0
HOME=$absent_home "$GC" --dry-run extra 2> /dev/null || status=$?
test "$status" -eq 64
test ! -e "$absent_home/.cache"

# ---- A dry run reports the verdict of every owned artifact and changes nothing. A real run of the same
# tree then retires what was reported and keeps the rest: live and scoped sessions, a locked entry, recent
# units, receipts and resumable verification state, build dirs the user chose, and recovery data.
dry_home=$fixture/dry-home
dry_cache=$dry_home/.cache/dotfiles-wsl
dry_cgroup=$fixture/dry-cgroup
dry_verification=$dry_cache/verification
dry_project=$(printf dry-project | sha256sum | cut -d ' ' -f 1)
dry_fingerprint=$(printf dry-fingerprint | sha256sum | cut -d ' ' -f 1)
dry_other=$(printf dry-other | sha256sum | cut -d ' ' -f 1)
make_home "$dry_home"
make_shared_cache "$dry_home" 2
make_session "$dry_home"
make_session_metadata "$dry_home" orphan "$missing_pid" "$current_boot_id" 0
make_session_metadata "$dry_home" 4242.scoped "$missing_pid" "$current_boot_id" 0
mkdir -p "$dry_cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice/dotfiles-agent-fixture.4242.scoped.scope"
mkdir -p "$(session_path "$dry_home" unclaimed)/tmp"
: > "$(session_path "$dry_home" orphan)/tmp/scratch"
dry_entry=$(entry_path "$dry_home" "$first_entry_id")
make_unit "$dry_entry" old '40 days ago' 4
make_unit "$dry_entry" recent '1 day ago' 4
printf 'allocated\n' > "$dry_entry/debug/deps/liborphan-0123456789abcdef.rlib"
touch -d '3 days ago' "$dry_entry/debug/deps/liborphan-0123456789abcdef.rlib"
dry_locked=$(entry_path "$dry_home" "$locked_entry_id")
make_unit "$dry_locked" idle '40 days ago' 4
mkdir -p "$dry_home/.cache/explicit-target/debug/deps" "$dry_home/work/recovery-bundle" "$dry_cache/recovery"
printf 'allocated\n' > "$dry_home/.cache/explicit-target/debug/deps/libuser-0123456789abcdef.rlib"
touch -d '90 days ago' "$dry_home/.cache/explicit-target/debug/deps/libuser-0123456789abcdef.rlib"
printf '{}\n' > "$dry_home/work/recovery-bundle/manifest.json"
: > "$dry_cache/recovery/bundle"
mkdir -p "$dry_verification/.fingerprint.dead" "$dry_verification/$dry_project" \
  "$dry_verification/sessions/resume-me" "$dry_cache/trash/units.interrupted"
printf 'allocated\n' > "$dry_verification/.fingerprint.dead/tracked-index"
printf 'version=6\nfingerprint=%s' "$dry_fingerprint" > "$dry_verification/$dry_project/$dry_fingerprint.success"
printf 'version=6\nfingerprint=%s' "$dry_fingerprint" > "$dry_verification/$dry_project/$dry_other.success"
: > "$dry_verification/$dry_project/$dry_fingerprint.1793000000000000.123.verified"
: > "$dry_verification/$dry_project/$dry_other.waived"
: > "$dry_verification/$dry_project/.pending.1793000000000000.124"
: > "$dry_verification/$dry_project/run.lock"
: > "$dry_verification/sessions/resume-me/armed"
: > "$dry_cache/trash/units.interrupted/payload"
exec {dry_lock_fd}<"$dry_locked/debug/.cargo-build-lock"
flock -x "$dry_lock_fd"
tree_state "$dry_home" > "$fixture/dry-before"
HOME=$dry_home DOTFILES_AGENT_CGROUP_ROOT=$dry_cgroup DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC" --dry-run > "$fixture/dry-report"
tree_state "$dry_home" > "$fixture/dry-after"
cmp "$fixture/dry-before" "$fixture/dry-after"
expect_report "$fixture/dry-report" keep session "$(session_path "$dry_home" live)" owner-alive
expect_report "$fixture/dry-report" keep session "$(session_path "$dry_home" 4242.scoped)" scope-occupied
expect_report "$fixture/dry-report" retire session "$(session_path "$dry_home" orphan)" owner-dead
expect_report "$fixture/dry-report" retire session "$(session_path "$dry_home" unclaimed)" unclaimed
expect_report "$fixture/dry-report" retire cargo-unit "$dry_entry#$(unit_hash "$dry_entry" old)" inactive
expect_report "$fixture/dry-report" retire cargo-orphan "$dry_entry#0123456789abcdef" orphan
expect_report "$fixture/dry-report" keep cargo-entry "$dry_locked" busy
expect_report "$fixture/dry-report" retire verification-scratch "$dry_verification/.fingerprint.dead" no-runner
expect_report "$fixture/dry-report" retire verification-success "$dry_verification" 'legacy-record x1'
expect_report "$fixture/dry-report" keep verification-success \
  "$dry_verification/$dry_project/$dry_other.success" unrecognized-record
expect_report "$fixture/dry-report" retire trash "$dry_cache/trash/units.interrupted" interrupted-removal
awk -F'\t' '$1 == "summary" && $2 == "cache" { found = 1 } END { exit !found }' "$fixture/dry-report"
refute_report "$fixture/dry-report" "$dry_entry#$(unit_hash "$dry_entry" recent)"
refute_report "$fixture/dry-report" "$dry_locked#"
for untouched in "$dry_home/.cache/explicit-target" "$dry_home/work" "$dry_cache/recovery" \
  "$dry_verification/sessions" .verified .waived .pending run.lock; do
  refute_report "$fixture/dry-report" "$untouched"
done
HOME=$dry_home DOTFILES_AGENT_CGROUP_ROOT=$dry_cgroup DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
exec {dry_lock_fd}<&-
test -d "$(session_path "$dry_home" live)"
test -d "$(session_path "$dry_home" 4242.scoped)"
test ! -e "$(session_path "$dry_home" orphan)"
test ! -e "$(session_path "$dry_home" unclaimed)"
expect_unit reclaimed "$dry_entry" old
expect_unit kept "$dry_entry" recent
expect_unit kept "$dry_locked" idle
test ! -e "$dry_entry/debug/deps/liborphan-0123456789abcdef.rlib"
test ! -e "$dry_verification/.fingerprint.dead"
test ! -e "$dry_verification/$dry_project/$dry_fingerprint.success"
test -f "$dry_verification/$dry_project/$dry_other.success"
test -f "$dry_verification/$dry_project/$dry_fingerprint.1793000000000000.123.verified"
test -f "$dry_verification/$dry_project/$dry_other.waived"
test -f "$dry_verification/$dry_project/.pending.1793000000000000.124"
test -f "$dry_verification/$dry_project/run.lock"
test -f "$dry_verification/sessions/resume-me/armed"
test -f "$dry_home/.cache/explicit-target/debug/deps/libuser-0123456789abcdef.rlib"
test -f "$dry_home/work/recovery-bundle/manifest.json"
test -f "$dry_cache/recovery/bundle"
trash_is_empty "$dry_home"

# A verification-cache that still runs may own any scratch directory, so none is retired while it runs.
# The legacy success records have no reader left, so they go either way.
runner_home=$fixture/runner-home
runner_verification=$runner_home/.cache/dotfiles-wsl/verification
make_home "$runner_home"
mkdir -p "$runner_verification/.fingerprint.busy" "$runner_verification/$dry_project"
: > "$runner_verification/.fingerprint.busy/tracked-index"
printf 'version=6\nfingerprint=%s' "$dry_fingerprint" > "$runner_verification/$dry_project/$dry_fingerprint.success"
start_runner "$fixture/runner.release"
HOME=$runner_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
  "$GC" --dry-run > "$fixture/runner-report"
expect_report "$fixture/runner-report" keep verification-scratch "$runner_verification/.fingerprint.busy" runner-alive
expect_report "$fixture/runner-report" retire verification-success "$runner_verification" 'legacy-record x1'
HOME=$runner_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test -f "$runner_verification/.fingerprint.busy/tracked-index"
test ! -e "$runner_verification/$dry_project/$dry_fingerprint.success"
: > "$fixture/runner.release"
wait "$runner_pid"
HOME=$runner_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test ! -e "$runner_verification/.fingerprint.busy"
trash_is_empty "$runner_home"

# A cmdline the GC cannot read means it cannot tell whether a legacy verification-cache runs. It keeps the
# scratch, says why, and fails the run. A process that vanished while it was read, or that belongs to
# another user, does not make the answer unknown, and the legacy records go in every case.
unverifiable_home=$fixture/unverifiable-home
unverifiable_verification=$unverifiable_home/.cache/dotfiles-wsl/verification
unverifiable_scratch=$unverifiable_verification/.fingerprint.unknown
make_home "$unverifiable_home"
mkdir -p "$unverifiable_scratch" "$unverifiable_verification/$dry_project"
: > "$unverifiable_scratch/tracked-index"
write_legacy_record() {
  printf 'version=6\nfingerprint=%s' "$dry_fingerprint" > "$unverifiable_verification/$dry_project/$dry_fingerprint.success"
}
unverifiable_dry_run() {
  HOME=$unverifiable_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
    "$UNREADABLE_PROC_GC" --dry-run > "$fixture/unverifiable-report" 2> /dev/null
}
write_legacy_record
status=0
DOTFILES_AGENT_TEST_UNREADABLE_CMDLINE_PIDS=$$ unverifiable_dry_run || status=$?
test "$status" -eq 70
expect_report "$fixture/unverifiable-report" keep verification-scratch "$unverifiable_scratch" runner-unverifiable
expect_report "$fixture/unverifiable-report" retire verification-success "$unverifiable_verification" 'legacy-record x1'
status=0
DOTFILES_AGENT_TEST_AWK_FAILS=1 unverifiable_dry_run || status=$?
test "$status" -eq 70
expect_report "$fixture/unverifiable-report" keep verification-scratch "$unverifiable_scratch" runner-unverifiable
test -f "$unverifiable_verification/$dry_project/$dry_fingerprint.success"
if HOME=$unverifiable_home DOTFILES_AGENT_TEST_UNREADABLE_CMDLINE_PIDS=$$ DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 \
  DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$UNREADABLE_PROC_GC" 2> /dev/null; then
  echo 'GC removed scratch although it could not tell whether a verification-cache runs' >&2
  exit 1
fi
test -f "$unverifiable_scratch/tracked-index"
test ! -e "$unverifiable_verification/$dry_project/$dry_fingerprint.success"
DOTFILES_AGENT_TEST_UNREADABLE_CMDLINE_PIDS=$missing_pid unverifiable_dry_run
expect_report "$fixture/unverifiable-report" retire verification-scratch "$unverifiable_scratch" no-runner
DOTFILES_AGENT_TEST_UNREADABLE_CMDLINE_PIDS=$$ DOTFILES_AGENT_TEST_WRONG_OWNER_PID=$$ unverifiable_dry_run
expect_report "$fixture/unverifiable-report" retire verification-scratch "$unverifiable_scratch" no-runner
test -f "$unverifiable_scratch/tracked-index"

# A scratch path that is a link is not the GC's to remove: it fails the run in both modes and what the link
# points to stays.
link_home=$fixture/link-scratch-home
link_verification=$link_home/.cache/dotfiles-wsl/verification
make_home "$link_home"
mkdir -p "$link_verification" "$link_home/outside"
: > "$link_home/outside/payload"
ln -s "$link_home/outside" "$link_verification/.fingerprint.link"
status=0
HOME=$link_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 \
  "$GC" --dry-run > "$fixture/link-report" 2> /dev/null || status=$?
test "$status" -eq 70
expect_report "$fixture/link-report" unresolved verification-scratch "$link_verification/.fingerprint.link" not-owned-directory
if HOME=$link_home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC" 2> /dev/null; then
  echo 'GC accepted a linked verification scratch path' >&2
  exit 1
fi
test -L "$link_verification/.fingerprint.link"
test -f "$link_home/outside/payload"

# Metadata that no longer names an owner keeps its session and fails a dry run exactly as it fails a run.
invalid_home=$fixture/invalid-metadata-home
make_home "$invalid_home"
mkdir -p "$(session_path "$invalid_home" invalid)/tmp"
head -c 4096 /dev/zero > "$(session_path "$invalid_home" invalid)/metadata.json"
make_shared_cache "$invalid_home" 32
invalid_high=$(($(allocated_bytes "$invalid_home/.cache/dotfiles-wsl/shared") - 1))
status=0
HOME=$invalid_home DOTFILES_AGENT_GC_HIGH_BYTES=$invalid_high DOTFILES_AGENT_GC_LOW_BYTES=0 \
  "$GC" --dry-run > "$fixture/invalid-report" 2> /dev/null || status=$?
test "$status" -eq 70
expect_report "$fixture/invalid-report" unresolved session "$(session_path "$invalid_home" invalid)" invalid-metadata
expect_report "$fixture/invalid-report" keep shared-cache "$invalid_home/.cache/dotfiles-wsl/shared" active-session
if grep -q $'^retire\tshared-cache\t' "$fixture/invalid-report"; then
  echo 'GC preview retires shared cache despite an unknown session owner' >&2
  exit 1
fi
status=0
HOME=$invalid_home DOTFILES_AGENT_GC_HIGH_BYTES=$invalid_high DOTFILES_AGENT_GC_LOW_BYTES=0 \
  "$GC" > /dev/null 2> /dev/null || status=$?
test "$status" -eq 70
test -f "$invalid_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
test -d "$(session_path "$invalid_home" invalid)/tmp"

# Above the high watermark the shared cache is reported as retired only without a session, and is
# then removed by the run that was reported.
purge_home=$fixture/purge-report-home
make_home "$purge_home"
make_shared_cache "$purge_home" 32
purge_high=$(($(allocated_bytes "$purge_home/.cache/dotfiles-wsl/shared") - 1))
HOME=$purge_home DOTFILES_AGENT_GC_HIGH_BYTES=$purge_high DOTFILES_AGENT_GC_LOW_BYTES=0 \
  "$GC" --dry-run > "$fixture/purge-report"
expect_report "$fixture/purge-report" retire shared-cache "$purge_home/.cache/dotfiles-wsl/shared" over-high-without-session
test -e "$purge_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"
HOME=$purge_home DOTFILES_AGENT_GC_HIGH_BYTES=$purge_high DOTFILES_AGENT_GC_LOW_BYTES=0 "$GC"
test ! -e "$purge_home/.cache/dotfiles-wsl/shared/cargo-home/payload"
make_session "$purge_home"
make_shared_cache "$purge_home" 32
HOME=$purge_home DOTFILES_AGENT_GC_HIGH_BYTES=$purge_high DOTFILES_AGENT_GC_LOW_BYTES=0 \
  "$GC" --dry-run > "$fixture/purge-active-report"
expect_report "$fixture/purge-active-report" keep shared-cache "$purge_home/.cache/dotfiles-wsl/shared" active-session
test -e "$purge_home/.cache/dotfiles-wsl/shared/cargo-home/payload/file-0"

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
worktree_repo=$fixture/worktree-repo
git init -q "$worktree_repo"
printf 'tracked\n' > "$worktree_repo/tracked"
git -C "$worktree_repo" add tracked
git -C "$worktree_repo" commit -qm initial
printf 'inner/\n' >> "$worktree_repo/.git/info/exclude"
initial_head=$(git -C "$worktree_repo" rev-parse HEAD)

gc_in() {
  local home=$1
  shift
  HOME=$home DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$@"
}

worktree_registered() {
  git -C "$worktree_repo" worktree list --porcelain > "$fixture/worktree-list"
  grep -Fxq "worktree $1" "$fixture/worktree-list"
}

add_recorded_worktree() {
  local session=$1 path=$2
  git -C "$worktree_repo" worktree add -q --detach "$path"
  path=$(git -C "$path" rev-parse --show-toplevel)
  printf '%s\0%s\0' "$path" "$(git -C "$path" rev-parse HEAD)" >> "$session/worktrees"
}

refute_retire() {
  if awk -F'\t' -v subject="$2" '$1 == "retire" && $2 == "session" && $4 == subject { found = 1 } END { exit !found }' "$1"; then
    echo "dry-run report retires a session that holds a kept worktree: $2" >&2
    cat "$1" >&2
    exit 1
  fi
}

kept_home=$fixture/kept-worktree-home
make_home "$kept_home"
make_session "$kept_home"
make_session_metadata "$kept_home" dead "$missing_pid" "$current_boot_id" 0
make_session_metadata "$kept_home" clean "$missing_pid" "$current_boot_id" 0
make_session_metadata "$kept_home" plain "$missing_pid" "$current_boot_id" 0
kept_live=$(session_path "$kept_home" live)
kept_dead=$(session_path "$kept_home" dead)
kept_clean=$(session_path "$kept_home" clean)
kept_plain=$(session_path "$kept_home" plain)
kept_external=$fixture/kept-external
add_recorded_worktree "$kept_dead" "$kept_dead/tmp/clean"
add_recorded_worktree "$kept_dead" "$kept_dead/tmp/untracked"
printf 'untracked\n' > "$kept_dead/tmp/untracked/sentinel"
add_recorded_worktree "$kept_dead" "$kept_dead/tmp/modified"
printf 'modified\n' > "$kept_dead/tmp/modified/tracked"
add_recorded_worktree "$kept_dead" "$kept_dead/tmp/advanced"
git -C "$kept_dead/tmp/advanced" commit -q --allow-empty -m advanced
add_recorded_worktree "$kept_dead" "$kept_dead/tmp/locked"
git -C "$worktree_repo" worktree lock "$kept_dead/tmp/locked"
add_recorded_worktree "$kept_dead" "$kept_external"
printf 'external\n' > "$kept_external/sentinel"
printf 'scratch\n' > "$kept_dead/tmp/scratch"
add_recorded_worktree "$kept_clean" "$kept_clean/tmp/clean"
printf 'scratch\n' > "$kept_plain/tmp/scratch"
add_recorded_worktree "$kept_live" "$kept_live/tmp/dirty"
printf 'live\n' > "$kept_live/tmp/dirty/sentinel"
mkdir -p "$kept_home/.cache/explicit-target/debug"
: > "$kept_home/.cache/explicit-target/debug/artifact"

tree_state "$kept_home" > "$fixture/kept-before"
git -C "$worktree_repo" worktree list --porcelain > "$fixture/kept-list-before"
gc_in "$kept_home" "$GC" --dry-run > "$fixture/kept-report"
tree_state "$kept_home" > "$fixture/kept-after"
git -C "$worktree_repo" worktree list --porcelain > "$fixture/kept-list-after"
cmp "$fixture/kept-before" "$fixture/kept-after"
cmp "$fixture/kept-list-before" "$fixture/kept-list-after"
expect_report "$fixture/kept-report" keep session "$kept_dead" retained-worktree
refute_retire "$fixture/kept-report" "$kept_dead"
expect_report "$fixture/kept-report" keep session "$kept_live" owner-alive
expect_report "$fixture/kept-report" retire session "$kept_clean" owner-dead
expect_report "$fixture/kept-report" retire session "$kept_plain" owner-dead

gc_in "$kept_home" "$GC"
trash_is_empty "$kept_home"
test -f "$kept_dead/metadata.json"
test "$(cat "$kept_dead/tmp/scratch")" = scratch
test ! -e "$kept_dead/tmp/clean"
if worktree_registered "$kept_dead/tmp/clean"; then
  echo 'the GC left a removed clean worktree registered' >&2
  exit 1
fi
for name in untracked modified advanced locked; do
  test -d "$kept_dead/tmp/$name"
  worktree_registered "$kept_dead/tmp/$name"
done
test "$(cat "$kept_dead/tmp/untracked/sentinel")" = untracked
test "$(cat "$kept_dead/tmp/modified/tracked")" = modified
test "$(git -C "$kept_dead/tmp/advanced" log -1 --format=%s)" = advanced
test -e "$(git -C "$kept_dead/tmp/locked" rev-parse --absolute-git-dir)/locked"
test "$(cat "$kept_external/sentinel")" = external
worktree_registered "$kept_external"
test ! -e "$kept_clean"
if worktree_registered "$kept_clean/tmp/clean"; then
  echo 'the GC left the worktree of a collected session registered' >&2
  exit 1
fi
test ! -e "$kept_plain"
test "$(cat "$kept_live/tmp/dirty/sentinel")" = live
worktree_registered "$kept_live/tmp/dirty"
test -f "$kept_home/.cache/explicit-target/debug/artifact"

git -C "$worktree_repo" worktree unlock "$kept_dead/tmp/locked"
for name in untracked modified advanced locked; do
  git -C "$worktree_repo" worktree remove --force "$kept_dead/tmp/$name"
done
gc_in "$kept_home" "$GC" --dry-run > "$fixture/kept-resolved-report"
expect_report "$fixture/kept-resolved-report" retire session "$kept_dead" owner-dead
gc_in "$kept_home" "$GC"
test ! -e "$kept_dead"
trash_is_empty "$kept_home"
test "$(cat "$kept_external/sentinel")" = external
worktree_registered "$kept_external"
test "$(cat "$kept_live/tmp/dirty/sentinel")" = live

enclosing_home=$fixture/enclosing-worktree-home
make_home "$enclosing_home"
make_session_metadata "$enclosing_home" enclosing "$missing_pid" "$current_boot_id" 0
enclosing_session=$(session_path "$enclosing_home" enclosing)
add_recorded_worktree "$enclosing_session" "$enclosing_session/tmp/outer"
add_recorded_worktree "$enclosing_session" "$enclosing_session/tmp/outer/inner"
printf 'inner\n' > "$enclosing_session/tmp/outer/inner/sentinel"
gc_in "$enclosing_home" "$GC" --dry-run > "$fixture/enclosing-report"
expect_report "$fixture/enclosing-report" keep session "$enclosing_session" retained-worktree
gc_in "$enclosing_home" "$GC"
test "$(cat "$enclosing_session/tmp/outer/inner/sentinel")" = inner
worktree_registered "$enclosing_session/tmp/outer"
worktree_registered "$enclosing_session/tmp/outer/inner"
git -C "$worktree_repo" worktree remove --force "$enclosing_session/tmp/outer/inner"
gc_in "$enclosing_home" "$GC"
test ! -e "$enclosing_session"
if worktree_registered "$enclosing_session/tmp/outer"; then
  echo 'the GC left the outer worktree of a collected session registered' >&2
  exit 1
fi

symlinked_home=$fixture/symlinked-worktree-home
make_home "$symlinked_home"
make_session_metadata "$symlinked_home" linked "$missing_pid" "$current_boot_id" 0
symlinked_session=$(session_path "$symlinked_home" linked)
git -C "$worktree_repo" worktree add -q --detach "$fixture/link-target"
ln -s "$fixture/link-target" "$symlinked_session/tmp/link"
printf '%s\0%s\0' "$(realpath "$symlinked_session")/tmp/link" "$initial_head" > "$symlinked_session/worktrees"
gc_in "$symlinked_home" "$GC" --dry-run > "$fixture/symlinked-report"
expect_report "$fixture/symlinked-report" keep session "$symlinked_session" retained-worktree
gc_in "$symlinked_home" "$GC"
test -L "$symlinked_session/tmp/link"
test -d "$fixture/link-target"
worktree_registered "$fixture/link-target"

record_home=$fixture/unreadable-record-home
make_home "$record_home"
make_session "$record_home"
make_session_metadata "$record_home" healthy "$missing_pid" "$current_boot_id" 0
printf 'scratch\n' > "$(session_path "$record_home" healthy)/tmp/scratch"
: > "$fixture/record-target"
record_shapes=(truncated relative dotted badhead symlink)
for shape in "${record_shapes[@]}"; do
  make_session_metadata "$record_home" "record-$shape" "$missing_pid" "$current_boot_id" 0
  record_session=$(session_path "$record_home" "record-$shape")
  printf 'scratch\n' > "$record_session/tmp/sentinel"
  case $shape in
    truncated) printf '%s\0' /only/a/path > "$record_session/worktrees" ;;
    relative) printf '%s\0%s\0' relative/path "$initial_head" > "$record_session/worktrees" ;;
    dotted) printf '%s\0%s\0' /some/../path "$initial_head" > "$record_session/worktrees" ;;
    badhead) printf '%s\0%s\0' /some/path not-a-commit > "$record_session/worktrees" ;;
    symlink) ln -s "$fixture/record-target" "$record_session/worktrees" ;;
  esac
done
status=0
gc_in "$record_home" "$GC" --dry-run > "$fixture/record-report" 2> /dev/null || status=$?
test "$status" -eq 70
for shape in "${record_shapes[@]}"; do
  expect_report "$fixture/record-report" unresolved session "$(session_path "$record_home" "record-$shape")" worktree-record
done
expect_report "$fixture/record-report" retire session "$(session_path "$record_home" healthy)" owner-dead
expect_unresolved "$fixture/record-gc.log" gc_in "$record_home" "$GC"
for shape in "${record_shapes[@]}"; do
  test "$(cat "$(session_path "$record_home" "record-$shape")/tmp/sentinel")" = scratch
done
test ! -e "$(session_path "$record_home" healthy)"
test -d "$(session_path "$record_home" live)"
trash_is_empty "$record_home"

launcher_home=$fixture/launcher-kept-home
mkdir -p "$launcher_home"
cat > "$fixture/launcher-client" <<SCRIPT
#!$BASH
set -eu
git worktree add -q --detach "\$TMPDIR/kept"
printf 'kept\n' > "\$TMPDIR/kept/sentinel"
SCRIPT
chmod +x "$fixture/launcher-client"
(
  cd "$worktree_repo"
  env -u TMPDIR HOME="$launcher_home" SYSTEMD_RUN_CAPTURE="$fixture/systemd-run" \
    "$LAUNCHER" fixture-client "$fixture/launcher-client"
)
launcher_session=$(find "$launcher_home/.cache/dotfiles-wsl/sessions" -mindepth 1 -maxdepth 1 -print -quit)
test -n "$launcher_session"
test "$(cat "$launcher_session/tmp/kept/sentinel")" = kept
gc_in "$launcher_home" "$GC" --dry-run > "$fixture/launcher-kept-report"
expect_report "$fixture/launcher-kept-report" keep session "$launcher_session" retained-worktree
gc_in "$launcher_home" "$GC"
test "$(cat "$launcher_session/tmp/kept/sentinel")" = kept
worktree_registered "$launcher_session/tmp/kept"
git -C "$worktree_repo" worktree remove --force "$launcher_session/tmp/kept"
gc_in "$launcher_home" "$GC"
test ! -e "$launcher_session"

make_exit_home() {
  local home=$1
  make_home "$home"
  make_session "$home"
  printf 'working\n' > "$(session_path "$home" live)/tmp/work"
  make_session_metadata "$home" ended "$$" "$current_boot_id" "$current_start_time"
  make_session_metadata "$home" ending "$$" "$current_boot_id" "$current_start_time"
  mkdir -p "$home/.cache/explicit-target/debug"
  : > "$home/.cache/explicit-target/debug/artifact"
}

write_exit_action() {
  local home=$1 action=$2
  rm -f "$action" "$action.done"
  printf 'rm -rf -- %q\nrm -f -- %q\n' "$(session_path "$home" ended)" \
    "$(session_path "$home" ending)/metadata.json" > "$action"
}

exit_dry_home=$fixture/session-exit-dry-home
exit_dry_action=$fixture/session-exit-dry.action
make_exit_home "$exit_dry_home"
write_exit_action "$exit_dry_home" "$exit_dry_action"
gc_in "$exit_dry_home" env DOTFILES_AGENT_TEST_AFTER_SESSION_LISTING="$exit_dry_action" \
  "$SESSION_EXIT_GC" --dry-run > "$fixture/session-exit-dry-report"
test -e "$exit_dry_action.done"
expect_report "$fixture/session-exit-dry-report" keep session "$(session_path "$exit_dry_home" live)" owner-alive
expect_report "$fixture/session-exit-dry-report" retire session "$(session_path "$exit_dry_home" ending)" unclaimed
refute_report "$fixture/session-exit-dry-report" "$(session_path "$exit_dry_home" ended)"
test -d "$(session_path "$exit_dry_home" ending)"
test "$(cat "$(session_path "$exit_dry_home" live)/tmp/work")" = working
test -f "$exit_dry_home/.cache/explicit-target/debug/artifact"

exit_home=$fixture/session-exit-home
exit_action=$fixture/session-exit.action
make_exit_home "$exit_home"
write_exit_action "$exit_home" "$exit_action"
gc_in "$exit_home" env DOTFILES_AGENT_TEST_AFTER_SESSION_LISTING="$exit_action" "$SESSION_EXIT_GC"
test -e "$exit_action.done"
test ! -e "$(session_path "$exit_home" ended)"
test ! -e "$(session_path "$exit_home" ending)"
test "$(cat "$(session_path "$exit_home" live)/tmp/work")" = working
test -f "$exit_home/.cache/explicit-target/debug/artifact"
trash_is_empty "$exit_home"

exit_move_home=$fixture/session-move-home
exit_move_action=$fixture/session-move.action
make_home "$exit_move_home"
make_session "$exit_move_home"
make_session_metadata "$exit_move_home" reaped "$missing_pid" "$current_boot_id" 0
rm -f "$exit_move_action" "$exit_move_action.done"
printf 'rm -rf -- %q\n' "$(session_path "$exit_move_home" reaped)" > "$exit_move_action"
gc_in "$exit_move_home" env DOTFILES_AGENT_TEST_BEFORE_SESSION_MOVE="$exit_move_action" "$SESSION_EXIT_GC"
test -e "$exit_move_action.done"
test ! -e "$(session_path "$exit_move_home" reaped)"
test -d "$(session_path "$exit_move_home" live)"
trash_is_empty "$exit_move_home"

: > "$fixture/session-unsafe-target"
for mode in dry real; do
  exit_unsafe_home=$fixture/session-unsafe-$mode-home
  exit_unsafe_action=$fixture/session-unsafe-$mode.action
  make_exit_home "$exit_unsafe_home"
  make_session_metadata "$exit_unsafe_home" symlinked "$$" "$current_boot_id" "$current_start_time"
  rm -f "$(session_path "$exit_unsafe_home" symlinked)/metadata.json"
  ln -s "$fixture/session-unsafe-target" "$(session_path "$exit_unsafe_home" symlinked)/metadata.json"
  write_exit_action "$exit_unsafe_home" "$exit_unsafe_action"
  gc_options=()
  if [ "$mode" = dry ]; then
    gc_options=(--dry-run)
  fi
  status=0
  gc_in "$exit_unsafe_home" env DOTFILES_AGENT_TEST_AFTER_SESSION_LISTING="$exit_unsafe_action" \
    "$SESSION_EXIT_GC" "${gc_options[@]}" > /dev/null 2> "$fixture/session-unsafe-$mode.log" || status=$?
  test "$status" -eq 70
  grep -Fq 'session metadata is a symlink' "$fixture/session-unsafe-$mode.log"
  test -L "$(session_path "$exit_unsafe_home" symlinked)/metadata.json"
  test "$(cat "$(session_path "$exit_unsafe_home" live)/tmp/work")" = working
done
