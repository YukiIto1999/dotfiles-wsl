#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

fixture=$PWD/agent-resource-fixture
mkdir -p "$fixture"

proc_start_time() {
  local process_stat
  process_stat=$(<"/proc/$1/stat")
  awk '{print $20}' <<<"${process_stat##*) }"
}

new_case() {
  HOME="$fixture/$1/home"
  export HOME
  mkdir -p "$HOME"
}

state_root() {
  printf '%s\n' "$HOME/.local/state/dotfiles-wsl/agent-resources"
}

create_repo() {
  local repo=$1
  mkdir -p "$repo"
  "$REAL_GIT" -C "$repo" init -q
  "$REAL_GIT" -C "$repo" config user.name fixture
  "$REAL_GIT" -C "$repo" config user.email fixture@example.invalid
  printf 'initial\n' >"$repo/tracked"
  "$REAL_GIT" -C "$repo" add tracked
  "$REAL_GIT" -C "$repo" commit -qm initial
}

begin_session() {
  local session=$1 owner_pid=${2:-$$}
  export DOTFILES_AGENT_SESSION_ID=$session
  export DOTFILES_AGENT_CLIENT=fixture-client
  export DOTFILES_AGENT_OWNER_PID=$owner_pid
  export DOTFILES_AGENT_OWNER_START_TIME
  DOTFILES_AGENT_OWNER_START_TIME=$(proc_start_time "$owner_pid")
  export DOTFILES_AGENT_BOOT_ID
  DOTFILES_AGENT_BOOT_ID=$(</proc/sys/kernel/random/boot_id)
  "$RESOURCE" begin-session "$session"
}

add_managed_worktree() {
  local repo=$1 path=$2
  (
    cd "$repo"
    "$WORKTREE" add --detach "$path" HEAD >/dev/null
  )
}

record_for_path() {
  local path=$1 record
  for record in "$(state_root)/worktrees/"*.json; do
    if jq --exit-status --arg path "$path" '.path == $path' "$record" >/dev/null; then
      printf '%s\n' "$record"
      return 0
    fi
  done
  return 1
}

assert_preserved() {
  local path=$1 reason=$2 record
  if [ ! -d "$path" ]; then
    echo "worktree was removed instead of preserved ($reason): $path" >&2
    exit 1
  fi
  record=$(record_for_path "$path")
  test "$(jq -r '.status' "$record")" = preserved
  test "$(jq -r '.last_reason' "$record")" = "$reason"
}

wait_for_file() {
  local path=$1
  for _ in $(seq 1 500); do
    [ ! -e "$path" ] || return 0
    sleep 0.01
  done
  echo "timed out waiting for fixture marker: $path" >&2
  exit 1
}

assert_proc_failure_preserved() {
  local case_name=$1 mode=$2 repo path ready holder_pid reference
  new_case "$case_name"
  repo="$HOME/repo"
  path="$HOME/managed"
  ready="$HOME/holder-ready"
  create_repo "$repo"
  begin_session "$case_name-session"
  add_managed_worktree "$repo" "$path"
  (
    exec 7</dev/null
    : >"$ready"
    sleep 30
  ) &
  holder_pid=$!
  trap 'kill "$holder_pid" 2>/dev/null || true' EXIT
  wait_for_file "$ready"
  reference="/proc/$holder_pid/fd/7"
  DOTFILES_AGENT_TEST_PROC_MODE="$mode" \
    DOTFILES_AGENT_TEST_PROC_REFERENCE="$reference" \
    DOTFILES_AGENT_TEST_PROC_COUNTER="$HOME/readlink-count" \
    "$CONTROLLED_PROC_RESOURCE" cleanup-session "$case_name-session"
  assert_preserved "$path" ambiguous-process-reference
  kill "$holder_pid"
  wait "$holder_pid" 2>/dev/null || true
  trap - EXIT
}

# Clean, unchanged, inactive linked worktrees are removed. The main and an
# unowned linked worktree are outside the ledger and remain untouched.
new_case clean
clean_repo="$HOME/repo"
clean_path="$HOME/managed"
unowned_path="$HOME/unowned"
create_repo "$clean_repo"
begin_session clean-session
"$RESOURCE" begin-session clean-session
add_managed_worktree "$clean_repo" "$clean_path"
"$REAL_GIT" -C "$clean_repo" worktree add -q --detach "$unowned_path" HEAD
clean_record=$(record_for_path "$clean_path")
test "$(stat -c %a "$(state_root)")" = 700
test "$(stat -c %a "$(state_root)/sessions")" = 700
test "$(stat -c %a "$clean_record")" = 600
test "$(jq -r '.initial_head' "$clean_record")" = "$("$REAL_GIT" -C "$clean_path" rev-parse HEAD)"
"$RESOURCE" cleanup-session clean-session
test ! -e "$clean_path"
test -d "$clean_repo"
test -d "$unowned_path"
test "$(jq -r '.status' "$clean_record")" = removed
test "$(jq -r '.last_reason' "$clean_record")" = clean-unchanged-inactive

# A removable worktree is first isolated below a unique sibling quarantine,
# then revalidated at that new path before the non-forced remove.
new_case quarantine
quarantine_repo="$HOME/repo"
quarantine_path="$HOME/managed"
quarantine_log="$HOME/git.log"
create_repo "$quarantine_repo"
begin_session quarantine-session
add_managed_worktree "$quarantine_repo" "$quarantine_path"
DOTFILES_AGENT_TEST_GIT_LOG="$quarantine_log" \
  "$AUDIT_RESOURCE" cleanup-session quarantine-session
test ! -e "$quarantine_path"
grep -Fq $'git\t--git-dir='"$quarantine_repo/.git"$'\tworktree\tmove\t--\t'"$quarantine_path" \
  "$quarantine_log"
grep -Eq $'git\t-C\t.*/[.]dotfiles-agent-quarantine[.][^/]+/worktree\tstatus\t' \
  "$quarantine_log"
grep -Eq $'git\t--git-dir=.*\tworktree\tremove\t--\t.*/[.]dotfiles-agent-quarantine[.][^/]+/worktree$' \
  "$quarantine_log"

# A mutation introduced after the initial precheck is detected at the
# quarantined path. The worktree is restored and its ownership is preserved.
new_case quarantine-mutation
mutation_repo="$HOME/repo"
mutation_path="$HOME/managed"
mutation_marker="$HOME/mutated"
create_repo "$mutation_repo"
begin_session mutation-session
add_managed_worktree "$mutation_repo" "$mutation_path"
DOTFILES_AGENT_TEST_MUTATE_AFTER_MOVE="$mutation_marker" \
  "$AUDIT_RESOURCE" cleanup-session mutation-session 2>"$HOME/cleanup.log"
assert_preserved "$mutation_path" dirty
test -f "$mutation_path/late-untracked"
test -z "$(find "$HOME" -maxdepth 1 -name '.dotfiles-agent-quarantine.*' -print -quit)"
grep -Fq 'preserve dirty' "$HOME/cleanup.log"

# A process can acquire a reference only after the worktree has moved. The
# post-quarantine scan must restore the worktree instead of removing it.
new_case quarantine-in-use
race_use_repo="$HOME/repo"
race_use_path="$HOME/managed"
race_use_ready="$HOME/move-ready"
race_use_release="$HOME/move-release"
race_use_holder_ready="$HOME/holder-ready"
create_repo "$race_use_repo"
begin_session race-use-session
add_managed_worktree "$race_use_repo" "$race_use_path"
DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_READY="$race_use_ready" \
  DOTFILES_AGENT_TEST_IN_USE_AFTER_MOVE_RELEASE="$race_use_release" \
  "$AUDIT_RESOURCE" cleanup-session race-use-session &
race_use_cleanup_pid=$!
trap 'kill "$race_use_cleanup_pid" 2>/dev/null || true' EXIT
race_use_deadline=$((SECONDS + 10))
while [ ! -e "$race_use_ready" ]; do
  if ((SECONDS >= race_use_deadline)); then
    echo "timed out waiting for fixture marker: $race_use_ready" >&2
    exit 1
  fi
done
race_use_quarantine=$(<"$race_use_ready")
(
  exec 7<"$race_use_quarantine/tracked"
  : >"$race_use_holder_ready"
  sleep 30
) &
race_use_holder_pid=$!
trap 'kill "$race_use_cleanup_pid" "$race_use_holder_pid" 2>/dev/null || true' EXIT
wait_for_file "$race_use_holder_ready"
: >"$race_use_release"
wait "$race_use_cleanup_pid"
assert_preserved "$race_use_path" active-fd
kill "$race_use_holder_pid"
wait "$race_use_holder_pid" 2>/dev/null || true
trap - EXIT

# Tracked changes and nonignored untracked files are distinct preservation cases.
new_case dirty
dirty_repo="$HOME/repo"
dirty_path="$HOME/dirty"
untracked_path="$HOME/untracked"
create_repo "$dirty_repo"
begin_session dirty-session
add_managed_worktree "$dirty_repo" "$dirty_path"
add_managed_worktree "$dirty_repo" "$untracked_path"
printf 'changed\n' >"$dirty_path/tracked"
printf 'untracked\n' >"$untracked_path/new-file"
"$RESOURCE" cleanup-session dirty-session 2>"$HOME/cleanup.log"
assert_preserved "$dirty_path" dirty
assert_preserved "$untracked_path" dirty
grep -Fq 'preserve dirty' "$HOME/cleanup.log"

# A changed HEAD is preserved even when the worktree is otherwise clean.
new_case commit
commit_repo="$HOME/repo"
commit_path="$HOME/commit"
create_repo "$commit_repo"
begin_session commit-session
add_managed_worktree "$commit_repo" "$commit_path"
printf 'commit\n' >"$commit_path/committed"
"$REAL_GIT" -C "$commit_path" add committed
"$REAL_GIT" -C "$commit_path" commit -qm unique
"$RESOURCE" cleanup-session commit-session
assert_preserved "$commit_path" head-changed

# Any live process with a cwd inside the worktree blocks removal.
new_case active
active_repo="$HOME/repo"
active_path="$HOME/active"
create_repo "$active_repo"
begin_session active-session
add_managed_worktree "$active_repo" "$active_path"
(
  cd "$active_path"
  exec sleep 30
) &
active_pid=$!
trap 'kill "$active_pid" 2>/dev/null || true' EXIT
"$RESOURCE" cleanup-session active-session
assert_preserved "$active_path" active-cwd
kill "$active_pid"
wait "$active_pid" 2>/dev/null || true
trap - EXIT

# An open descriptor blocks cleanup even when every process cwd is outside.
new_case active-fd
fd_repo="$HOME/repo"
fd_path="$HOME/active-fd"
fd_ready="$HOME/fd-ready"
create_repo "$fd_repo"
begin_session fd-session
add_managed_worktree "$fd_repo" "$fd_path"
(
  exec 7<"$fd_path/tracked"
  : >"$fd_ready"
  sleep 30
) &
fd_pid=$!
trap 'kill "$fd_pid" 2>/dev/null || true' EXIT
wait_for_file "$fd_ready"
test "$(readlink -e "/proc/$fd_pid/cwd")" != "$fd_path"
"$RESOURCE" cleanup-session fd-session
assert_preserved "$fd_path" active-fd
kill "$fd_pid"
wait "$fd_pid" 2>/dev/null || true
trap - EXIT

# Reaping also preserves a clean worktree while a process executes a binary
# from it with its cwd outside the worktree.
new_case active-exe
exe_repo="$HOME/repo"
exe_path="$HOME/active-exe"
create_repo "$exe_repo"
cp "$TEST_BASH" "$exe_repo/fixture-bash"
chmod +x "$exe_repo/fixture-bash"
"$REAL_GIT" -C "$exe_repo" add fixture-bash
"$REAL_GIT" -C "$exe_repo" commit -qm executable
begin_session exe-session
add_managed_worktree "$exe_repo" "$exe_path"
setsid "$exe_path/fixture-bash" -c 'sleep 30; :' &
exe_pid=$!
trap 'kill -- "-$exe_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 500); do
  [ "$(readlink -e "/proc/$exe_pid/exe" 2>/dev/null || true)" != "$exe_path/fixture-bash" ] || break
  sleep 0.01
done
test "$(readlink -e "/proc/$exe_pid/exe")" = "$exe_path/fixture-bash"
test "$(readlink -e "/proc/$exe_pid/cwd")" != "$exe_path"
exe_session="$(state_root)/sessions/exe-session.json"
jq '.owner_start_time = "0"' "$exe_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$exe_session"
"$RESOURCE" reap
assert_preserved "$exe_path" active-exe
kill -- "-$exe_pid" 2>/dev/null || true
wait "$exe_pid" 2>/dev/null || true
trap - EXIT

# Missing worktrees keep their ledger record and are reported rather than pruned.
new_case missing
missing_repo="$HOME/repo"
missing_path="$HOME/missing"
create_repo "$missing_repo"
begin_session missing-session
add_managed_worktree "$missing_repo" "$missing_path"
missing_record=$(record_for_path "$missing_path")
"$REAL_GIT" -C "$missing_repo" worktree remove "$missing_path"
"$RESOURCE" cleanup-session missing-session 2>"$HOME/cleanup.log"
test "$(jq -r '.status' "$missing_record")" = preserved
test "$(jq -r '.last_reason' "$missing_record")" = missing
grep -Fq 'preserve missing' "$HOME/cleanup.log"

# Main worktrees and relative/untrusted paths can never enter the ownership ledger.
new_case main
main_repo="$HOME/repo"
create_repo "$main_repo"
begin_session main-session
main_common=$("$REAL_GIT" -C "$main_repo" rev-parse --path-format=absolute --git-common-dir)
main_head=$("$REAL_GIT" -C "$main_repo" rev-parse HEAD)
if "$RESOURCE" register-worktree main-session "$main_common" "$main_repo" "$main_head"; then
  echo 'main worktree was registered' >&2
  exit 1
fi
if "$RESOURCE" register-worktree main-session "$main_common" relative-path "$main_head"; then
  echo 'relative worktree path was registered' >&2
  exit 1
fi
if "$RESOURCE" begin-session ../escape; then
  echo 'untrusted session id was accepted' >&2
  exit 1
fi
test -d "$main_repo"

# The managed wrapper is an add-only creation boundary. Moving an existing,
# unowned linked worktree must be rejected before Git changes its path.
new_case reject-move
move_repo="$HOME/repo"
move_source="$HOME/unowned"
move_target="$HOME/moved"
create_repo "$move_repo"
begin_session move-session
"$REAL_GIT" -C "$move_repo" worktree add -q --detach "$move_source" HEAD
if (
  cd "$move_repo"
  "$WORKTREE" move "$move_source" "$move_target"
) 2>"$HOME/move.log"; then
  echo 'managed wrapper accepted worktree move' >&2
  exit 1
fi
test -d "$move_source"
test ! -e "$move_target"
test -z "$(find "$(state_root)/worktrees" -mindepth 1 -name '*.json' -print -quit)"
grep -Fq 'only worktree add is supported' "$HOME/move.log"

# A symlink or malformed ledger entry makes cleanup fail closed before deletion.
new_case symlink-ledger
symlink_repo="$HOME/repo"
symlink_path="$HOME/managed"
create_repo "$symlink_repo"
begin_session symlink-session
add_managed_worktree "$symlink_repo" "$symlink_path"
ln -s /dev/null "$(state_root)/worktrees/symlink.json"
if "$RESOURCE" cleanup-session symlink-session 2>"$HOME/cleanup.log"; then
  echo 'symlink ledger did not fail closed' >&2
  exit 1
fi
test -d "$symlink_path"
grep -Fq 'symlink-ledger' "$HOME/cleanup.log"

new_case malformed-ledger
malformed_repo="$HOME/repo"
malformed_path="$HOME/managed"
create_repo "$malformed_repo"
begin_session malformed-session
add_managed_worktree "$malformed_repo" "$malformed_path"
printf '{' >"$(state_root)/worktrees/malformed.json"
chmod 600 "$(state_root)/worktrees/malformed.json"
if "$RESOURCE" cleanup-session malformed-session 2>"$HOME/cleanup.log"; then
  echo 'malformed ledger did not fail closed' >&2
  exit 1
fi
test -d "$malformed_path"
grep -Fq 'malformed-ledger' "$HOME/cleanup.log"

# Managed creation preflights the ledger. Registration failures known before
# git runs must not leave a newly-created unowned worktree behind.
new_case create-preflight
preflight_repo="$HOME/repo"
preflight_path="$HOME/not-created"
create_repo "$preflight_repo"
begin_session preflight-session
ln -s /dev/null "$(state_root)/worktrees/symlink.json"
if (
  cd "$preflight_repo"
  "$WORKTREE" add --detach "$preflight_path" HEAD
) 2>"$HOME/create.log"; then
  echo 'creation ignored malformed ledger' >&2
  exit 1
fi
test ! -e "$preflight_path"
grep -Fq 'symlink-ledger' "$HOME/create.log"

# A schema-valid record whose identity no longer matches its filename is
# ambiguous. It must not transfer ownership to an unowned linked worktree.
new_case tampered-ledger
tampered_repo="$HOME/repo"
tampered_managed="$HOME/managed"
tampered_unowned="$HOME/unowned"
create_repo "$tampered_repo"
begin_session tampered-session
add_managed_worktree "$tampered_repo" "$tampered_managed"
"$REAL_GIT" -C "$tampered_repo" worktree add -q --detach "$tampered_unowned" HEAD
tampered_record=$(record_for_path "$tampered_managed")
jq --arg path "$tampered_unowned" '.path = $path' "$tampered_record" >"$HOME/record.tmp"
chmod 600 "$HOME/record.tmp"
mv -T "$HOME/record.tmp" "$tampered_record"
if "$RESOURCE" cleanup-session tampered-session 2>"$HOME/cleanup.log"; then
  echo 'tampered ledger did not fail closed' >&2
  exit 1
fi
test -d "$tampered_managed"
test -d "$tampered_unowned"
grep -Fq 'malformed-ledger' "$HOME/cleanup.log"

# Creation is serialized and registration/begin are idempotent.
new_case concurrent
concurrent_repo="$HOME/repo"
concurrent_one="$HOME/one"
concurrent_two="$HOME/two"
create_repo "$concurrent_repo"
begin_session concurrent-session
"$RESOURCE" begin-session concurrent-session
(
  cd "$concurrent_repo"
  "$WORKTREE" add --detach "$concurrent_one" HEAD >/dev/null
) &
first_add=$!
(
  cd "$concurrent_repo"
  "$WORKTREE" add --detach "$concurrent_two" HEAD >/dev/null
) &
second_add=$!
wait "$first_add"
wait "$second_add"
owned_records=("$(state_root)/worktrees/"*.json)
test "${#owned_records[@]}" -eq 2
"$RESOURCE" cleanup-session concurrent-session
test ! -e "$concurrent_one"
test ! -e "$concurrent_two"

# Cleanup shares the per-session creation lock. It cannot end the session in
# the interval after Git creates the exact target and before registration.
new_case add-cleanup-race
race_repo="$HOME/repo"
race_path="$HOME/managed"
race_ready="$HOME/add-ready"
race_release="$HOME/add-release"
race_cleanup_done="$HOME/cleanup-done"
create_repo "$race_repo"
begin_session race-session
(
  cd "$race_repo"
  DOTFILES_AGENT_TEST_ADD_READY="$race_ready" \
    DOTFILES_AGENT_TEST_ADD_RELEASE="$race_release" \
    "$RACE_WORKTREE" add --detach "$race_path" HEAD >/dev/null
) &
race_add_pid=$!
for _ in $(seq 1 500); do
  [[ -e $race_ready ]] && break
  sleep 0.01
done
test -e "$race_ready"
(
  "$RACE_RESOURCE" cleanup-session race-session
  : >"$race_cleanup_done"
) &
race_cleanup_pid=$!
cleanup_crossed_creation=0
for _ in $(seq 1 100); do
  if [[ -e $race_cleanup_done ]]; then
    cleanup_crossed_creation=1
    break
  fi
  sleep 0.01
done
: >"$race_release"
set +e
wait "$race_add_pid"
race_add_status=$?
wait "$race_cleanup_pid"
race_cleanup_status=$?
set -e
if ((cleanup_crossed_creation == 1)); then
  echo 'cleanup crossed an in-flight worktree create/register transaction' >&2
  exit 1
fi
test "$race_add_status" -eq 0
test "$race_cleanup_status" -eq 0
test ! -e "$race_path"
race_record=$(record_for_path "$race_path")
test "$(jq -r '.status' "$race_record")" = removed

# The add-only parser identifies the target while preserving the supported
# Git add option forms.
new_case add-options
options_repo="$HOME/repo"
options_b="$HOME/branch-b"
options_B="$HOME/branch-B"
options_no_checkout="$HOME/no-checkout"
options_locked="$HOME/locked"
create_repo "$options_repo"
begin_session options-session
(
  cd "$options_repo"
  "$WORKTREE" add -b fixture-b --checkout "$options_b" HEAD >/dev/null
  "$WORKTREE" add -B fixture-B "$options_B" HEAD >/dev/null
  "$WORKTREE" add --detach --no-checkout "$options_no_checkout" HEAD >/dev/null
  "$WORKTREE" add --detach --lock --reason fixture "$options_locked" HEAD >/dev/null
)
"$REAL_GIT" -C "$options_no_checkout" reset --hard -q
"$REAL_GIT" -C "$options_repo" worktree unlock "$options_locked"
test -n "$(record_for_path "$options_b")"
test -n "$(record_for_path "$options_B")"
test -n "$(record_for_path "$options_no_checkout")"
test -n "$(record_for_path "$options_locked")"
"$RESOURCE" cleanup-session options-session
test ! -e "$options_b"
test ! -e "$options_B"
test ! -e "$options_no_checkout"
test ! -e "$options_locked"

# Wrapper housekeeping never changes the real git failure and leaves no
# snapshot files behind.
new_case caller-status
status_repo="$HOME/repo"
create_repo "$status_repo"
begin_session caller-status-session
mkdir -p "$HOME/tmp"
set +e
(
  cd "$status_repo"
  "$REAL_GIT" worktree add "$HOME/direct-invalid" missing-ref >/dev/null 2>&1
)
real_status=$?
(
  cd "$status_repo"
  TMPDIR="$HOME/tmp" "$WORKTREE" add "$HOME/wrapper-invalid" missing-ref >/dev/null 2>&1
)
wrapper_status=$?
set -e
test "$real_status" -ne 0
test "$wrapper_status" -eq "$real_status"
test -z "$(find "$HOME/tmp" -mindepth 1 -print -quit)"

# Reaping validates dead owners, PID start time, and boot id independently.
new_case orphan
orphan_repo="$HOME/repo"
orphan_path="$HOME/orphan"
create_repo "$orphan_repo"
sleep 30 &
orphan_pid=$!
begin_session orphan-session "$orphan_pid"
add_managed_worktree "$orphan_repo" "$orphan_path"
kill "$orphan_pid"
wait "$orphan_pid" 2>/dev/null || true
"$RESOURCE" reap
test ! -e "$orphan_path"
test "$(jq -r '.reason' "$(state_root)/sessions/orphan-session.json")" = orphan-dead

new_case owner-mismatch
owner_repo="$HOME/repo"
owner_path="$HOME/owner-mismatch"
create_repo "$owner_repo"
begin_session owner-mismatch-session
add_managed_worktree "$owner_repo" "$owner_path"
owner_session="$(state_root)/sessions/owner-mismatch-session.json"
jq '.owner_start_time = "0"' "$owner_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$owner_session"
"$RESOURCE" reap
test ! -e "$owner_path"
test "$(jq -r '.reason' "$owner_session")" = orphan-owner-mismatch

new_case boot-mismatch
boot_repo="$HOME/repo"
boot_path="$HOME/boot-mismatch"
create_repo "$boot_repo"
begin_session boot-mismatch-session
add_managed_worktree "$boot_repo" "$boot_path"
boot_session="$(state_root)/sessions/boot-mismatch-session.json"
jq '.boot_id = "00000000-0000-0000-0000-000000000000"' "$boot_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$boot_session"
"$RESOURCE" reap
test ! -e "$boot_path"
test "$(jq -r '.reason' "$boot_session")" = orphan-boot-mismatch

# A future terminal timestamp is never interpreted as expired, even at the
# largest accepted retention setting.
new_case future-retention
begin_session future-retention-session
future_session="$(state_root)/sessions/future-retention-session.json"
"$RESOURCE" cleanup-session future-retention-session
future_timestamp=$(($(date +%s) + 365 * 24 * 60 * 60))
jq --argjson timestamp "$future_timestamp" '.updated_at = $timestamp' \
  "$future_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$future_session"
"$OVERFLOW_RESOURCE" reap
test -f "$future_session"

# Retention arithmetic must not overflow and expire a fresh terminal ledger.
new_case overflow-retention
begin_session overflow-retention-session
overflow_session="$(state_root)/sessions/overflow-retention-session.json"
"$RESOURCE" cleanup-session overflow-retention-session
"$OVERFLOW_RESOURCE" reap
if [ ! -f "$overflow_session" ]; then
  echo 'maximum ledger retention expired a fresh terminal ledger' >&2
  exit 1
fi

# Permission denial, a disappearing magic link, and a stable broken link all
# make process-reference inspection inconclusive and therefore preserve.
assert_proc_failure_preserved proc-permission-denied denied
assert_proc_failure_preserved proc-reference-disappearing disappearing
assert_proc_failure_preserved proc-reference-broken broken

# Terminal ledgers use their recorded update time for bounded retention. Ledger
# expiry never authorizes deleting a worktree.
new_case terminal-retention
retention_repo="$HOME/repo"
retention_path="$HOME/removed"
create_repo "$retention_repo"
begin_session retention-session
add_managed_worktree "$retention_repo" "$retention_path"
retention_record=$(record_for_path "$retention_path")
retention_session="$(state_root)/sessions/retention-session.json"
"$RESOURCE" cleanup-session retention-session
test ! -e "$retention_path"
for ledger in "$retention_record" "$retention_session"; do
  jq '.updated_at = 0' "$ledger" >"$HOME/ledger.tmp"
  chmod 600 "$HOME/ledger.tmp"
  mv -T "$HOME/ledger.tmp" "$ledger"
done
"$RESOURCE" reap
test ! -e "$retention_record"
test ! -e "$retention_session"

# Legacy terminal records without updated_at fall back to their own mtime.
# Pruning the expired ownership record leaves the preserved dirty worktree.
new_case legacy-retention
legacy_repo="$HOME/repo"
legacy_path="$HOME/preserved"
create_repo "$legacy_repo"
begin_session legacy-session
add_managed_worktree "$legacy_repo" "$legacy_path"
printf 'dirty\n' >"$legacy_path/untracked"
legacy_record=$(record_for_path "$legacy_path")
legacy_session="$(state_root)/sessions/legacy-session.json"
"$RESOURCE" cleanup-session legacy-session
assert_preserved "$legacy_path" dirty
for ledger in "$legacy_record" "$legacy_session"; do
  jq 'del(.updated_at)' "$ledger" >"$HOME/ledger.tmp"
  chmod 600 "$HOME/ledger.tmp"
  mv -T "$HOME/ledger.tmp" "$ledger"
  touch -d '31 days ago' "$ledger"
done
"$RESOURCE" reap
test -d "$legacy_path"
test -f "$legacy_path/untracked"
test ! -e "$legacy_record"
test ! -e "$legacy_session"

# Age never expires a live session or its owned worktree ledger.
new_case active-retention
active_retention_repo="$HOME/repo"
active_retention_path="$HOME/active"
create_repo "$active_retention_repo"
begin_session active-retention-session
add_managed_worktree "$active_retention_repo" "$active_retention_path"
active_retention_record=$(record_for_path "$active_retention_path")
active_retention_session="$(state_root)/sessions/active-retention-session.json"
for ledger in "$active_retention_record" "$active_retention_session"; do
  jq '.updated_at = 0' "$ledger" >"$HOME/ledger.tmp"
  chmod 600 "$HOME/ledger.tmp"
  mv -T "$HOME/ledger.tmp" "$ledger"
done
"$RESOURCE" reap
test -d "$active_retention_path"
test -f "$active_retention_record"
test -f "$active_retention_session"

# An unknown status is not a terminal deletion authorization.
new_case unknown-retention
begin_session unknown-retention-session
unknown_session="$(state_root)/sessions/unknown-retention-session.json"
jq '.status = "unknown" | .updated_at = 0' "$unknown_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$unknown_session"
if "$RESOURCE" reap 2>"$HOME/reap.log"; then
  echo 'retention accepted an unknown session status' >&2
  exit 1
fi
test -f "$unknown_session"
grep -Fq 'malformed-ledger' "$HOME/reap.log"

# An old malformed ledger still fails closed and remains untouched.
new_case malformed-retention
mkdir -p "$(state_root)/sessions"
printf '{\n' >"$(state_root)/sessions/malformed.json"
chmod 600 "$(state_root)/sessions/malformed.json"
touch -d '31 days ago' "$(state_root)/sessions/malformed.json"
if "$RESOURCE" reap 2>"$HOME/reap.log"; then
  echo 'retention accepted malformed ledger' >&2
  exit 1
fi
test -f "$(state_root)/sessions/malformed.json"
grep -Fq 'malformed-ledger' "$HOME/reap.log"
