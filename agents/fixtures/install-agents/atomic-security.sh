#!/usr/bin/env bash
set -euo pipefail

: "${ATOMIC_PUBLISH:?}"
: "${ATOMIC_PUBLISH_PRODUCTION:?}"

fixture=$PWD/atomic-publish-security
mkdir -m 0700 "$fixture"

expect_status() {
  local expected=$1
  shift

  expect_command_status "$expected" "$ATOMIC_PUBLISH" "$@"
}

expect_command_status() {
  local expected=$1 command=$2
  shift 2

  set +e
  "$command" "$@" >"$fixture/helper.stdout" 2>"$fixture/helper.stderr"
  local status=$?
  set -e
  if [[ $status -ne $expected ]]; then
    echo "atomic helper status $status, expected $expected: $*" >&2
    cat "$fixture/helper.stderr" >&2
    return 1
  fi
}

identity() {
  "$ATOMIC_PUBLISH" identity "$1" "$2" "$3"
}

directory_identity() {
  "$ATOMIC_PUBLISH" directory-identity "$1"
}

run_case() {
  [[ ${ATOMIC_SECURITY_CASE:-all} == all || ${ATOMIC_SECURITY_CASE:-all} == "$1" ]]
}

# The production helper executes its non-racing FD API without fixture instrumentation.
if run_case production-fd-api; then
  directory=$fixture/production-fd-api
  mkdir -m 0700 "$directory"
  exec {directory_fd}<"$directory"
  directory_token=$($ATOMIC_PUBLISH_PRODUCTION directory-identity-fd "$directory_fd")
  printf '%s\n' source >"$directory/source"
  source_token=$($ATOMIC_PUBLISH_PRODUCTION identity-fd "$directory_fd" \
    "$directory_token" source)
  expect_command_status 0 "$ATOMIC_PUBLISH_PRODUCTION" move-noreplace-fd \
    "$directory_fd" "$directory_token" source \
    "$directory_fd" "$directory_token" destination "$source_token"
  test ! -e "$directory/source"
  destination_token=$($ATOMIC_PUBLISH_PRODUCTION identity-fd "$directory_fd" \
    "$directory_token" destination)
  ln -s exchange-target "$directory/source"
  source_token=$($ATOMIC_PUBLISH_PRODUCTION identity-fd "$directory_fd" \
    "$directory_token" source)
  expect_command_status 0 "$ATOMIC_PUBLISH_PRODUCTION" exchange-fd \
    "$directory_fd" "$directory_token" source \
    "$directory_fd" "$directory_token" destination "$source_token" "$destination_token"
  test "$(readlink -- "$directory/destination")" = exchange-target
  victim_token=$($ATOMIC_PUBLISH_PRODUCTION identity-fd "$directory_fd" \
    "$directory_token" destination)
  expect_command_status 0 "$ATOMIC_PUBLISH_PRODUCTION" unlink-if-fd \
    "$directory_fd" "$directory_token" destination "$victim_token"
  test ! -e "$directory/destination"
  test ! -L "$directory/destination"
  test -z "$(find "$directory" -maxdepth 1 -name '.atomic-quarantine.*' -print -quit)"
  exec {directory_fd}>&-
fi

# A forced open failure removes the exact empty quarantine created before the failure.
if run_case quarantine-open-failure; then
  directory=$fixture/quarantine-open-failure
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  exec {directory_fd}<"$directory"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  export FIXTURE_ATOMIC_HOOK_EVENT=before-quarantine-open
  export FIXTURE_ATOMIC_HOOK_ACTION=remove-quarantine
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/quarantine-open-failure.marker
  expect_status 5 unlink-if-fd "$directory_fd" "$directory_token" victim "$victim_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test "$(readlink -- "$directory/victim")" = expected-target
  test -z "$(find "$directory" -maxdepth 1 -name '.atomic-quarantine.*' -print -quit)"
  exec {directory_fd}>&-
fi

# A failure from the first fstatat after mkdir recovers the exact empty directory.
if run_case quarantine-path-fstat-failure; then
  directory=$fixture/quarantine-path-fstat-failure
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  exec {directory_fd}<"$directory"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  export FIXTURE_ATOMIC_HOOK_EVENT=inject-quarantine-path-fstat
  export FIXTURE_ATOMIC_HOOK_ACTION=force-mismatch
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/quarantine-path-fstat-failure.marker
  expect_status 5 unlink-if-fd "$directory_fd" "$directory_token" victim "$victim_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test "$(readlink -- "$directory/victim")" = expected-target
  test -z "$(find "$directory" -maxdepth 1 -name '.atomic-quarantine.*' -print -quit)"
  exec {directory_fd}>&-
fi

# A failure from fstat on the opened qdir also removes that exact empty directory.
if run_case quarantine-opened-fstat-failure; then
  directory=$fixture/quarantine-opened-fstat-failure
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  exec {directory_fd}<"$directory"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  export FIXTURE_ATOMIC_HOOK_EVENT=inject-quarantine-opened-fstat
  export FIXTURE_ATOMIC_HOOK_ACTION=force-mismatch
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/quarantine-opened-fstat-failure.marker
  expect_status 5 unlink-if-fd "$directory_fd" "$directory_token" victim "$victim_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test "$(readlink -- "$directory/victim")" = expected-target
  test -z "$(find "$directory" -maxdepth 1 -name '.atomic-quarantine.*' -print -quit)"
  exec {directory_fd}>&-
fi

# Every directory component is resolved without following symlinks or procfs magic links.
if run_case directory-resolution; then
  mkdir -m 0700 "$fixture/real-directory"
  ln -s real-directory "$fixture/directory-link"
  expect_status 3 directory-identity "$fixture/directory-link"
  mkdir -m 0700 "$fixture/real-parent"
  mkdir -m 0700 "$fixture/real-parent/child"
  ln -s real-parent "$fixture/parent-link"
  expect_status 3 directory-identity "$fixture/parent-link/child"
  expect_status 3 directory-identity /proc/self/cwd/atomic-publish-security
  mkdir -m 0700 "$fixture/different-source" "$fixture/different-destination"
  ln -s source-target "$fixture/different-source/source"
  source_directory_token=$(directory_identity "$fixture/different-source")
  destination_directory_token=$(directory_identity "$fixture/different-destination")
  source_token=$(identity "$fixture/different-source" "$source_directory_token" source)
  expect_status 4 move-noreplace "$fixture/different-source" "$source_directory_token" source \
    "$fixture/different-destination" "$source_directory_token" destination "$source_token"
  test -L "$fixture/different-source/source"
  test ! -e "$fixture/different-destination/destination"
  test ! -L "$fixture/different-destination/destination"
  test "$source_directory_token" != "$destination_directory_token"
fi

# A successful removal leaves no private quarantine directory behind.
if run_case quarantine-success; then
  directory=$fixture/quarantine-success/source
  mkdir -m 0700 "$fixture/quarantine-success"
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  unset FIXTURE_ATOMIC_HOOK_EVENT FIXTURE_ATOMIC_HOOK_ACTION
  expect_status 0 unlink-if "$directory" "$directory_token" victim "$victim_token"
  test ! -e "$directory/victim"
  test ! -L "$directory/victim"
  test -z "$(find "$directory" -mindepth 1 -name '.atomic-quarantine.*' -print -quit)"
fi

# No test hook or child runs between private identity verification and unlink.
if run_case quarantine-no-post-hook; then
  directory=$fixture/quarantine-no-post-hook/source
  mkdir -m 0700 "$fixture/quarantine-no-post-hook"
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  export FIXTURE_ATOMIC_HOOK_EVENT=after-quarantine-move
  export FIXTURE_ATOMIC_HOOK_ACTION=replace-quarantine
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/quarantine-no-post-hook.marker
  export FIXTURE_ATOMIC_HOOK_SAVED=$fixture/quarantine-no-post-hook.saved
  export FIXTURE_ATOMIC_HOOK_TARGET=external-target
  expect_status 0 unlink-if "$directory" "$directory_token" victim "$victim_token"
  test ! -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test ! -e "$directory/victim"
  test ! -L "$directory/victim"
  test -z "$(find "$directory" -mindepth 1 -name '.atomic-quarantine.*' -print -quit)"
fi

# Replacing a locked directory path after its FD is opened cannot redirect publication.
if run_case directory-race; then
  directory=$fixture/directory-race
  mkdir -m 0700 "$directory"
  ln -s release-target "$directory/next"
  directory_token=$(directory_identity "$directory")
  next_token=$(identity "$directory" "$directory_token" next)
  export FIXTURE_ATOMIC_HOOK_EVENT=after-open-directories
  export FIXTURE_ATOMIC_HOOK_ACTION=replace-directory
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/directory-race.marker
  export FIXTURE_ATOMIC_HOOK_SAVED=$fixture/directory-race.saved
  expect_status 4 move-noreplace "$directory" "$directory_token" next \
    "$directory" "$directory_token" current "$next_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test ! -e "$directory/current"
  test ! -L "$directory/current"
  saved_directory_token=$(directory_identity "$FIXTURE_ATOMIC_HOOK_SAVED")
  test "$(identity "$FIXTURE_ATOMIC_HOOK_SAVED" "$saved_directory_token" next)" = "$next_token"
  test "$(identity "$FIXTURE_ATOMIC_HOOK_SAVED" "$saved_directory_token" current)" = missing
fi

# unlink-if quarantines an object before deletion and restores an unexpected public replacement.
if run_case unlink-race; then
  directory=$fixture/unlink-race/source
  mkdir -m 0700 "$fixture/unlink-race"
  mkdir -m 0700 "$directory"
  ln -s expected-target "$directory/victim"
  directory_token=$(directory_identity "$directory")
  victim_token=$(identity "$directory" "$directory_token" victim)
  export FIXTURE_ATOMIC_HOOK_EVENT=before-quarantine-move
  export FIXTURE_ATOMIC_HOOK_ACTION=replace-object
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/unlink-race.marker
  export FIXTURE_ATOMIC_HOOK_SAVED=$fixture/unlink-race.saved
  export FIXTURE_ATOMIC_HOOK_TARGET=external-target
  expect_status 4 unlink-if "$directory" "$directory_token" victim "$victim_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test "$(readlink -- "$directory/victim")" = external-target
  test "$(readlink -- "$FIXTURE_ATOMIC_HOOK_SAVED")" = expected-target
  test -z "$(find "$directory" -mindepth 1 -name '.atomic-quarantine.*' -print -quit)"
fi

# Link count is part of the CAS identity for legacy regular files.
if run_case nlink-race; then
  directory=$fixture/nlink-race
  mkdir -m 0700 "$directory"
  printf '%s\n' legacy >"$directory/visible"
  chmod 0755 "$directory/visible"
  ln -s stable-target "$directory/next"
  directory_token=$(directory_identity "$directory")
  visible_token=$(identity "$directory" "$directory_token" visible)
  next_token=$(identity "$directory" "$directory_token" next)
  visible_inode=$(stat -c %i -- "$directory/visible")
  ln "$directory/visible" "$directory/added-hardlink"
  unset FIXTURE_ATOMIC_HOOK_EVENT FIXTURE_ATOMIC_HOOK_ACTION
  expect_status 4 exchange "$directory" "$directory_token" next \
    "$directory" "$directory_token" visible "$next_token" "$visible_token"
  test "$(stat -c %i -- "$directory/visible")" = "$visible_inode"
  test "$(readlink -- "$directory/next")" = stable-target
fi

# A forced post-exchange mismatch traverses stability verification and reverses the real syscall.
if run_case exchange-reverse; then
  directory=$fixture/exchange-reverse
  mkdir -m 0700 "$directory"
  ln -s source-target "$directory/source"
  ln -s destination-target "$directory/destination"
  directory_token=$(directory_identity "$directory")
  source_token=$(identity "$directory" "$directory_token" source)
  destination_token=$(identity "$directory" "$directory_token" destination)
  export FIXTURE_ATOMIC_HOOK_EVENT=after-exchange
  export FIXTURE_ATOMIC_HOOK_ACTION=force-mismatch
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/exchange-reverse.marker
  expect_status 4 exchange "$directory" "$directory_token" source \
    "$directory" "$directory_token" destination "$source_token" "$destination_token"
  test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
  test "$(identity "$directory" "$directory_token" source)" = "$source_token"
  test "$(identity "$directory" "$directory_token" destination)" = "$destination_token"
  test "$(readlink -- "$directory/source")" = source-target
  test "$(readlink -- "$directory/destination")" = destination-target
fi
