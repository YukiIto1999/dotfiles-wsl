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
  test -d "$path"
  record=$(record_for_path "$path")
  test "$(jq -r '.status' "$record")" = preserved
  test "$(jq -r '.last_reason' "$record")" = "$reason"
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
