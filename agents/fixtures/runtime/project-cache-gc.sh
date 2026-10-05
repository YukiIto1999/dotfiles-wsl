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
HOME=$scope_home DOTFILES_AGENT_GC_CGROUP_ROOT=$scope_cgroup \
  DOTFILES_AGENT_GC_HIGH_BYTES=1000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000 "$GC"
test -d "$(session_path "$scope_home" 4242.scoped)"
rm -r "$scope_cgroup"
HOME=$scope_home DOTFILES_AGENT_GC_CGROUP_ROOT=$scope_cgroup \
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
