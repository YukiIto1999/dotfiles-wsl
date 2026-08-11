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

proc_parent_pid() {
  local process_stat
  process_stat=$(<"/proc/$1/stat")
  awk '{print $2}' <<<"${process_stat##*) }"
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
  fixture_trap_pid=$holder_pid
  trap 'kill "$fixture_trap_pid" 2>/dev/null || true' EXIT
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
  unset fixture_trap_pid
}

assert_foreign_proc_failure_ignored() {
  local repo path ready holder_pid reference
  new_case proc-foreign-permission-denied
  repo="$HOME/repo"
  path="$HOME/managed"
  ready="$HOME/holder-ready"
  create_repo "$repo"
  begin_session proc-foreign-session
  add_managed_worktree "$repo" "$path"
  (
    exec 7</dev/null
    : >"$ready"
    sleep 30
  ) &
  holder_pid=$!
  fixture_trap_pid=$holder_pid
  trap 'kill "$fixture_trap_pid" 2>/dev/null || true' EXIT
  wait_for_file "$ready"
  reference="/proc/$holder_pid/fd/7"
  DOTFILES_AGENT_TEST_PROC_MODE=denied \
    DOTFILES_AGENT_TEST_PROC_REFERENCE="$reference" \
    DOTFILES_AGENT_TEST_PROC_OWNER_MODE=foreign \
    DOTFILES_AGENT_TEST_PROC_OWNER_PID="$holder_pid" \
    "$CONTROLLED_PROC_RESOURCE" cleanup-session proc-foreign-session
  test ! -e "$path"
  kill "$holder_pid"
  wait "$holder_pid" 2>/dev/null || true
  trap - EXIT
  unset fixture_trap_pid
}

assert_proc_owner_failure_preserved() {
  local repo path holder_pid
  new_case proc-owner-permission-denied
  repo="$HOME/repo"
  path="$HOME/managed"
  create_repo "$repo"
  begin_session proc-owner-permission-denied-session
  add_managed_worktree "$repo" "$path"
  sleep 30 &
  holder_pid=$!
  fixture_trap_pid=$holder_pid
  trap 'kill "$fixture_trap_pid" 2>/dev/null || true' EXIT
  DOTFILES_AGENT_TEST_PROC_OWNER_MODE=denied \
    DOTFILES_AGENT_TEST_PROC_OWNER_PID="$holder_pid" \
    "$CONTROLLED_PROC_RESOURCE" cleanup-session proc-owner-permission-denied-session
  assert_preserved "$path" ambiguous-process-reference
  kill "$holder_pid"
  wait "$holder_pid" 2>/dev/null || true
  trap - EXIT
  unset fixture_trap_pid
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

# A same-repository, same-HEAD worktree swapped into the quarantine path after
# move is not restored or terminalized as the registered worktree.
new_case quarantine-identity-after-move
post_identity_repo="$HOME/repo"
post_identity_path="$HOME/managed"
post_identity_safe_path="$HOME/registered-safe"
post_identity_marker="$HOME/replaced"
create_repo "$post_identity_repo"
begin_session post-identity-session
add_managed_worktree "$post_identity_repo" "$post_identity_path"
post_identity_record=$(record_for_path "$post_identity_path")
DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_SAFE="$post_identity_safe_path" \
  DOTFILES_AGENT_TEST_REPLACE_AFTER_MOVE_MARKER="$post_identity_marker" \
  "$AUDIT_RESOURCE" cleanup-session post-identity-session
test -e "$post_identity_marker"
if [ "$(jq -r '.status' "$post_identity_record")" != quarantining ]; then
  echo 'post-move identity replacement terminalized the transaction' >&2
  exit 1
fi
test ! -e "$post_identity_path"
post_identity_quarantine=$(jq -r '.quarantine_path' "$post_identity_record")
test -d "$post_identity_quarantine"
test -d "$post_identity_safe_path"
"$REAL_GIT" --git-dir="$post_identity_repo/.git" worktree remove -- \
  "$post_identity_quarantine"
"$REAL_GIT" --git-dir="$post_identity_repo/.git" worktree move -- \
  "$post_identity_safe_path" "$post_identity_quarantine"
"$RESOURCE" reap
test -d "$post_identity_path"
test "$(jq -r '.status' "$post_identity_record")" = owned
"$RESOURCE" reap
test ! -e "$post_identity_path"
test "$(jq -r '.status' "$post_identity_record")" = removed

# An unmanaged direct-Git replacement after the quarantined HEAD check remains
# outside the cooperative lock and must fail the final identity revalidation.
new_case quarantine-identity-before-remove
late_identity_repo="$HOME/repo"
late_identity_path="$HOME/managed"
late_identity_safe_path="$HOME/registered-safe"
late_identity_marker="$HOME/replaced-after-head"
create_repo "$late_identity_repo"
begin_session late-identity-session
add_managed_worktree "$late_identity_repo" "$late_identity_path"
late_identity_record=$(record_for_path "$late_identity_path")
DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_SAFE="$late_identity_safe_path" \
  DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_MARKER="$late_identity_marker" \
  "$AUDIT_RESOURCE" cleanup-session late-identity-session
test -e "$late_identity_marker"
late_identity_quarantine=$(jq -r '.quarantine_path' "$late_identity_record")
if [ "$(jq -r '.status' "$late_identity_record")" != quarantining ]; then
  echo 'late quarantine replacement terminalized the registered transaction' >&2
  exit 1
fi
test "$(jq -r '.last_reason' "$late_identity_record")" = \
  quarantine-identity-changed-before-remove
test -d "$late_identity_safe_path"
test -d "$late_identity_quarantine"
test ! -e "$late_identity_path"

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
while [ ! -s "$race_use_ready" ]; do
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

# The transaction intent precedes the move, so an untrappable SIGKILL leaves a
# recoverable ledger that the next reap restores without deleting the worktree.
new_case quarantine-sigkill
sigkill_repo="$HOME/repo"
sigkill_path="$HOME/managed"
sigkill_marker="$HOME/moved"
create_repo "$sigkill_repo"
begin_session sigkill-session
add_managed_worktree "$sigkill_repo" "$sigkill_path"
sigkill_record=$(record_for_path "$sigkill_path")
set +e
(
  exec env DOTFILES_AGENT_TEST_KILL_AFTER_MOVE="$sigkill_marker" \
    DOTFILES_AGENT_TEST_TRANSACTION_PARENT_PID="$BASHPID" \
    "$AUDIT_RESOURCE" cleanup-session sigkill-session
)
sigkill_status=$?
set -e
test "$sigkill_status" -eq 137
sigkill_quarantine=$(<"$sigkill_marker")
if [ "$(jq -r '.status' "$sigkill_record")" != quarantining ]; then
  echo 'worktree move was not preceded by a quarantining ledger intent' >&2
  exit 1
fi
test "$(jq -r '.quarantine_path' "$sigkill_record")" = "$sigkill_quarantine"
sigkill_git_dir=$(jq -r '.git_dir' "$sigkill_record")
sigkill_device=$(jq -r '.worktree_device' "$sigkill_record")
sigkill_inode=$(jq -r '.worktree_inode' "$sigkill_record")
test ! -e "$sigkill_path"
test -d "$sigkill_quarantine"
mkdir "$sigkill_path"
"$RESOURCE" reap
test -d "$sigkill_path"
test -d "$sigkill_quarantine"
test "$(jq -r '.status' "$sigkill_record")" = quarantining
test "$(jq -r '.last_reason' "$sigkill_record")" = quarantine-both-paths
test "$(jq -r '.path' "$sigkill_record")" = "$sigkill_path"
test "$(jq -r '.quarantine_path' "$sigkill_record")" = "$sigkill_quarantine"
rmdir "$sigkill_path"
"$RESOURCE" reap
test -d "$sigkill_path"
test ! -e "$sigkill_quarantine"
test "$(jq -r '.status' "$sigkill_record")" = owned
test "$(jq -r '.git_dir' "$sigkill_record")" = "$sigkill_git_dir"
test "$(jq -r '.worktree_device' "$sigkill_record")" = "$sigkill_device"
test "$(jq -r '.worktree_inode' "$sigkill_record")" = "$sigkill_inode"
if jq --exit-status 'has("quarantine_path")' "$sigkill_record" >/dev/null; then
  echo 'recovered worktree ledger retained stale quarantine intent' >&2
  exit 1
fi
sigkill_replacement_safe="$HOME/replacement-safe"
"$REAL_GIT" -C "$sigkill_repo" worktree add -q --detach \
  "$sigkill_replacement_safe" HEAD
sigkill_replacement_marker="$HOME/replaced-after-identity"
DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_PATH="$sigkill_path" \
  DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_SAFE="$sigkill_replacement_safe" \
  DOTFILES_AGENT_TEST_REPLACE_AFTER_IDENTITY_MARKER="$sigkill_replacement_marker" \
  "$AUDIT_RESOURCE" reap
test -e "$sigkill_replacement_marker"
if [ ! -d "$sigkill_path" ]; then
  echo 'reap deleted an ABA replacement introduced after identity validation' >&2
  exit 1
fi
test "$(jq -r '.status' "$sigkill_record")" = preserved
test "$(jq -r '.last_reason' "$sigkill_record")" = recovered-identity-changed

# Recovery binds to the originally registered linked-worktree git-dir. Another
# worktree from the same repository and HEAD cannot inherit the ledger merely
# by occupying the quarantine path after SIGKILL.
new_case quarantine-identity
identity_repo="$HOME/repo"
identity_path="$HOME/managed"
identity_safe_path="$HOME/registered-safe"
identity_marker="$HOME/moved"
create_repo "$identity_repo"
begin_session identity-session
add_managed_worktree "$identity_repo" "$identity_path"
identity_git_dir=$("$REAL_GIT" -C "$identity_path" rev-parse \
  --path-format=absolute --git-dir)
identity_record=$(record_for_path "$identity_path")
set +e
(
  exec env DOTFILES_AGENT_TEST_KILL_AFTER_MOVE="$identity_marker" \
    DOTFILES_AGENT_TEST_TRANSACTION_PARENT_PID="$BASHPID" \
    "$AUDIT_RESOURCE" cleanup-session identity-session
)
identity_status=$?
set -e
test "$identity_status" -eq 137
identity_quarantine=$(<"$identity_marker")
if [ "$(jq -r '.git_dir // empty' "$identity_record")" != "$identity_git_dir" ]; then
  echo 'quarantining ledger omitted the linked-worktree git-dir identity' >&2
  exit 1
fi
"$REAL_GIT" --git-dir="$identity_repo/.git" worktree move -- \
  "$identity_quarantine" "$identity_safe_path"
"$REAL_GIT" -C "$identity_repo" worktree add -q --detach \
  "$identity_quarantine" HEAD
"$RESOURCE" reap
test ! -e "$identity_path"
test -d "$identity_quarantine"
test -d "$identity_safe_path"
test "$(jq -r '.status' "$identity_record")" = quarantining
test "$(jq -r '.last_reason' "$identity_record")" = quarantine-path-ambiguous
"$REAL_GIT" --git-dir="$identity_repo/.git" worktree remove -- "$identity_quarantine"
"$REAL_GIT" --git-dir="$identity_repo/.git" worktree move -- \
  "$identity_safe_path" "$identity_quarantine"
"$RESOURCE" reap
test -d "$identity_path"
test "$(jq -r '.status' "$identity_record")" = owned
"$RESOURCE" reap
test ! -e "$identity_path"
test "$(jq -r '.status' "$identity_record")" = removed

# TERM is trappable and restores the moved worktree before the command exits;
# the recovered owned ledger remains retryable by reap.
new_case quarantine-term
term_repo="$HOME/repo"
term_path="$HOME/managed"
term_marker="$HOME/moved"
create_repo "$term_repo"
begin_session term-session
add_managed_worktree "$term_repo" "$term_path"
term_record=$(record_for_path "$term_path")
set +e
(
  exec env DOTFILES_AGENT_TEST_TERM_AFTER_MOVE="$term_marker" \
    DOTFILES_AGENT_TEST_TRANSACTION_PARENT_PID="$BASHPID" \
    "$AUDIT_RESOURCE" cleanup-session term-session
)
term_status=$?
set -e
test "$term_status" -eq 143
term_quarantine=$(<"$term_marker")
test -d "$term_path"
test ! -e "$term_quarantine"
test "$(jq -r '.status' "$term_record")" = owned
"$RESOURCE" reap
test ! -e "$term_path"
test "$(jq -r '.status' "$term_record")" = removed

# A quarantining ledger without the stable directory identity predates safe
# recovery and must fail closed instead of adopting its path.
new_case quarantine-legacy-identity
legacy_identity_repo="$HOME/repo"
legacy_identity_path="$HOME/managed"
create_repo "$legacy_identity_repo"
begin_session legacy-identity-session
add_managed_worktree "$legacy_identity_repo" "$legacy_identity_path"
legacy_identity_record=$(record_for_path "$legacy_identity_path")
legacy_identity_git_dir=$("$REAL_GIT" -C "$legacy_identity_path" rev-parse \
  --path-format=absolute --git-dir)
jq --arg git_dir "$legacy_identity_git_dir" \
  --arg quarantine_path "$HOME/.dotfiles-agent-quarantine.fixture/worktree" \
  'del(.worktree_device, .worktree_inode) |
    .status = "quarantining" | .git_dir = $git_dir |
    .quarantine_path = $quarantine_path |
    .last_reason = "quarantining" | .updated_at = 0' \
  "$legacy_identity_record" >"$HOME/record.tmp"
chmod 600 "$HOME/record.tmp"
mv -T "$HOME/record.tmp" "$legacy_identity_record"
if "$RESOURCE" cleanup-session legacy-identity-session 2>"$HOME/cleanup.log"; then
  echo 'legacy quarantining ledger without directory identity was accepted' >&2
  exit 1
fi
test -d "$legacy_identity_path"
grep -Fq 'malformed-ledger' "$HOME/cleanup.log"

# Removal intent is durable across SIGKILL after Git removes both the worktree
# and its exact administrative entry but before terminal ledger publication.
new_case removing-sigkill
removing_repo="$HOME/repo"
removing_path="$HOME/managed"
removing_marker="$HOME/removed"
create_repo "$removing_repo"
begin_session removing-session
add_managed_worktree "$removing_repo" "$removing_path"
removing_record=$(record_for_path "$removing_path")
set +e
(
  export DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_MARKER=$removing_marker
  export DOTFILES_AGENT_TEST_KILL_AFTER_REMOVE_PARENT_PID=$BASHPID
  exec "$AUDIT_RESOURCE" cleanup-session removing-session
)
removing_status=$?
set -e
test "$removing_status" -eq 137
test -f "$removing_marker"
removing_quarantine=$(<"$removing_marker")
removing_git_dir=$(jq -r '.git_dir' "$removing_record")
test "$(jq -r '.status' "$removing_record")" = removing
test "$(jq -r '.last_reason' "$removing_record")" = removing
test "$(jq -r '.quarantine_path' "$removing_record")" = "$removing_quarantine"
test ! -e "$removing_path"
test ! -e "$removing_quarantine"
test ! -e "$removing_git_dir"
mkdir -p "$removing_git_dir"
"$RESOURCE" reap
test "$(jq -r '.status' "$removing_record")" = removing
test "$(jq -r '.last_reason' "$removing_record")" = removing-admin-present
test -d "$removing_git_dir"
rmdir "$removing_git_dir"
if [ -d "${removing_git_dir%/*}" ]; then
  rmdir "${removing_git_dir%/*}" 2>/dev/null || true
fi
"$RESOURCE" reap
test "$(jq -r '.status' "$removing_record")" = removed
test ! -e "${removing_quarantine%/worktree}"

# A persisted removing record whose exact quarantine still exists revalidates
# the worktree and safely resumes the non-forced Git removal.
new_case removing-resume
removing_resume_repo="$HOME/repo"
removing_resume_path="$HOME/managed"
removing_resume_marker="$HOME/remove-failed"
create_repo "$removing_resume_repo"
begin_session removing-resume-session
add_managed_worktree "$removing_resume_repo" "$removing_resume_path"
removing_resume_record=$(record_for_path "$removing_resume_path")
DOTFILES_AGENT_TEST_FAIL_REMOVE_ONCE="$removing_resume_marker" \
  "$AUDIT_RESOURCE" cleanup-session removing-resume-session
test -f "$removing_resume_marker"
removing_resume_quarantine=$(jq -r '.quarantine_path' "$removing_resume_record")
test "$(jq -r '.status' "$removing_resume_record")" = removing
test -d "$removing_resume_quarantine"
printf 'late mutation\n' >"$removing_resume_quarantine/late-untracked"
"$RESOURCE" reap
test "$(jq -r '.status' "$removing_resume_record")" = removing
test "$(jq -r '.last_reason' "$removing_resume_record")" = removing-dirty
test -d "$removing_resume_quarantine"
rm -- "$removing_resume_quarantine/late-untracked"
removing_resume_safe="$HOME/original-safe"
removing_resume_identity_marker="$HOME/replaced-after-head"
DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_SAFE="$removing_resume_safe" \
  DOTFILES_AGENT_TEST_REPLACE_AFTER_HEAD_MARKER="$removing_resume_identity_marker" \
  "$AUDIT_RESOURCE" reap
test -e "$removing_resume_identity_marker"
test "$(jq -r '.status' "$removing_resume_record")" = removing
test "$(jq -r '.last_reason' "$removing_resume_record")" = \
  removing-quarantine-ambiguous
test -d "$removing_resume_safe"
test -d "$removing_resume_quarantine"
"$REAL_GIT" --git-dir="$removing_resume_repo/.git" worktree remove -- \
  "$removing_resume_quarantine"
"$REAL_GIT" --git-dir="$removing_resume_repo/.git" worktree move -- \
  "$removing_resume_safe" "$removing_resume_quarantine"
"$RESOURCE" reap
test "$(jq -r '.status' "$removing_resume_record")" = removed
test ! -e "$removing_resume_quarantine"

# A successful worktree removal can still be interrupted before its empty
# quarantine root is removed. The terminal phase proof remains retryable.
new_case quarantine-remove-root-retry
remove_root_repo="$HOME/repo"
remove_root_path="$HOME/managed"
remove_root_marker="$HOME/root-blocked"
create_repo "$remove_root_repo"
begin_session remove-root-session
add_managed_worktree "$remove_root_repo" "$remove_root_path"
remove_root_device=$(stat -c %d -- "$remove_root_path")
remove_root_inode=$(stat -c %i -- "$remove_root_path")
remove_root_record=$(record_for_path "$remove_root_path")
DOTFILES_AGENT_TEST_BLOCK_ROOT_AFTER_REMOVE_MARKER="$remove_root_marker" \
  "$AUDIT_RESOURCE" cleanup-session remove-root-session
test -f "$remove_root_marker"
remove_root_blocker=$(<"$remove_root_marker")
remove_root_quarantine=$(jq -r '.quarantine_path' "$remove_root_record")
remove_root_quarantine_root=${remove_root_quarantine%/worktree}
test -f "$remove_root_blocker"
test ! -e "$remove_root_path"
test ! -e "$remove_root_quarantine"
test "$(jq -r '.status' "$remove_root_record")" = removing
test "$(jq -r '.worktree_device' "$remove_root_record")" = "$remove_root_device"
test "$(jq -r '.worktree_inode' "$remove_root_record")" = "$remove_root_inode"
if [ "$(jq -r '.last_reason' "$remove_root_record")" != removing-root-unresolved ]; then
  echo 'EXIT recovery discarded the completed-removal transaction phase' >&2
  exit 1
fi
remove_root_git_dir=$(jq -r '.git_dir' "$remove_root_record")
"$REAL_GIT" -C "$remove_root_repo" worktree add -q --detach \
  "$remove_root_path" HEAD
replacement_git_dir=$("$REAL_GIT" -C "$remove_root_path" rev-parse \
  --path-format=absolute --git-dir)
if [ "$replacement_git_dir" != "$remove_root_git_dir" ]; then
  echo 'fixture did not reproduce linked-worktree git-dir path reuse' >&2
  exit 1
fi
test "$("$REAL_GIT" -C "$remove_root_path" rev-parse HEAD)" = \
  "$("$REAL_GIT" -C "$remove_root_repo" rev-parse HEAD)"
rm -- "$remove_root_blocker"
"$RESOURCE" reap
test -d "$remove_root_quarantine_root"
test -d "$remove_root_path"
test "$(jq -r '.status' "$remove_root_record")" = removing
test "$(jq -r '.last_reason' "$remove_root_record")" = removing-original-present
"$REAL_GIT" --git-dir="$remove_root_repo/.git" worktree remove -- "$remove_root_path"
mkdir -p "$remove_root_git_dir"
"$RESOURCE" reap
test -d "$remove_root_quarantine_root"
test -d "$remove_root_git_dir"
test "$(jq -r '.status' "$remove_root_record")" = removing
test "$(jq -r '.last_reason' "$remove_root_record")" = removing-admin-present
rmdir "$remove_root_git_dir"
if [ -d "${remove_root_git_dir%/*}" ]; then
  rmdir "${remove_root_git_dir%/*}" 2>/dev/null || true
fi
"$RESOURCE" reap
test ! -e "$remove_root_quarantine_root"
test "$(jq -r '.status' "$remove_root_record")" = removed

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

# Managed worktree mutations share one global lock before any session lock.
# An add from another session cannot enter the final remove window.
new_case global-mutation-lock
mutation_lock_repo="$HOME/repo"
mutation_lock_path="$HOME/managed"
mutation_lock_ready="$HOME/remove-ready"
mutation_lock_release="$HOME/remove-release"
create_repo "$mutation_lock_repo"
begin_session mutation-lock-owner-session
add_managed_worktree "$mutation_lock_repo" "$mutation_lock_path"
begin_session worktree-mutation
DOTFILES_AGENT_SESSION_ID=mutation-lock-owner-session \
  DOTFILES_AGENT_TEST_BEFORE_REMOVE_READY="$mutation_lock_ready" \
  DOTFILES_AGENT_TEST_BEFORE_REMOVE_RELEASE="$mutation_lock_release" \
  "$AUDIT_RESOURCE" cleanup-session mutation-lock-owner-session &
mutation_cleanup_pid=$!
fixture_trap_pid=$mutation_cleanup_pid
trap ': >"$mutation_lock_release"; kill "$fixture_trap_pid" 2>/dev/null || true' EXIT
mutation_ready_deadline=$((SECONDS + 5))
while [ ! -e "$mutation_lock_ready" ]; do
  if ((SECONDS >= mutation_ready_deadline)); then
    echo "timed out waiting for fixture marker: $mutation_lock_ready" >&2
    exit 1
  fi
done
test ! -e "$mutation_lock_path"
mutation_lock_file="$(state_root)/locks/.worktree-mutation.lock"
test "$(readlink -e "/proc/$mutation_cleanup_pid/fd/7")" = "$mutation_lock_file"
if flock -n "$mutation_lock_file" true; then
  echo 'cleanup did not hold the global mutation lock' >&2
  exit 1
fi
(
  cd "$mutation_lock_repo"
  exec env DOTFILES_AGENT_SESSION_ID=worktree-mutation \
    "$WORKTREE" add --detach "$mutation_lock_path" HEAD
) >/dev/null &
mutation_add_pid=$!
trap ': >"$mutation_lock_release"; kill "$mutation_cleanup_pid" "$mutation_add_pid" 2>/dev/null || true' EXIT
mutation_lock_deadline=$((SECONDS + 5))
while [ "$(readlink -e "/proc/$mutation_add_pid/fd/7" 2>/dev/null || true)" != \
  "$mutation_lock_file" ]; do
  if ((SECONDS >= mutation_lock_deadline)); then
    echo 'managed add did not block on the global mutation lock' >&2
    exit 1
  fi
done
test "$(stat -c %a -- "$mutation_lock_file")" = 600
test "$(stat -c %u -- "$mutation_lock_file")" = "$(id -u)"
for _ in $(seq 1 50); do
  kill -0 "$mutation_add_pid"
  test ! -e "$mutation_lock_path"
  sleep 0.01
done
: >"$mutation_lock_release"
set +e
wait "$mutation_cleanup_pid"
mutation_cleanup_status=$?
wait "$mutation_add_pid"
mutation_add_status=$?
set -e
trap - EXIT
unset fixture_trap_pid
test "$mutation_cleanup_status" -eq 0
test "$mutation_add_status" -eq 0
test -d "$mutation_lock_path"
mutation_lock_record=$(record_for_path "$mutation_lock_path")
test "$(jq -r '.session_id' "$mutation_lock_record")" = worktree-mutation
test "$(jq -r '.status' "$mutation_lock_record")" = owned

# A Git guardian keeps the global lock alive when the resource shell is killed
# while its direct Git mutation is still running.
new_case mutation-lock-resource-guardian
resource_guard_repo="$HOME/repo"
resource_guard_path="$HOME/managed"
resource_guard_contender="$HOME/contender"
resource_guard_ready="$HOME/remove-blocked"
resource_guard_release="$HOME/remove-release"
create_repo "$resource_guard_repo"
begin_session resource-guardian-owner
add_managed_worktree "$resource_guard_repo" "$resource_guard_path"
begin_session resource-guardian-contender
DOTFILES_AGENT_SESSION_ID=resource-guardian-owner \
  DOTFILES_AGENT_TEST_BLOCK_REMOVE_READY="$resource_guard_ready" \
  DOTFILES_AGENT_TEST_BLOCK_REMOVE_RELEASE="$resource_guard_release" \
  "$AUDIT_RESOURCE" cleanup-session resource-guardian-owner &
resource_guard_parent_pid=$!
trap ': >"$resource_guard_release"; kill "$resource_guard_parent_pid" 2>/dev/null || true' EXIT
resource_guard_deadline=$((SECONDS + 5))
while [ ! -s "$resource_guard_ready" ]; do
  if ((SECONDS >= resource_guard_deadline)); then
    echo 'timed out waiting for blocked resource Git child' >&2
    exit 1
  fi
done
resource_guard_git_pid=$(<"$resource_guard_ready")
kill -0 "$resource_guard_git_pid"
kill -KILL "$resource_guard_parent_pid"
set +e
wait "$resource_guard_parent_pid"
resource_guard_parent_status=$?
set -e
test "$resource_guard_parent_status" -eq 137
kill -0 "$resource_guard_git_pid"
(
  cd "$resource_guard_repo"
  exec env DOTFILES_AGENT_SESSION_ID=resource-guardian-contender \
    "$WORKTREE" add --detach "$resource_guard_contender" HEAD
) >/dev/null &
resource_guard_contender_pid=$!
trap ': >"$resource_guard_release"; kill "$resource_guard_contender_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  kill -0 "$resource_guard_contender_pid"
  test ! -e "$resource_guard_contender"
  sleep 0.01
done
: >"$resource_guard_release"
wait "$resource_guard_contender_pid"
trap - EXIT
test -d "$resource_guard_contender"
resource_guard_record=$(record_for_path "$resource_guard_path")
test "$(jq -r '.status' "$resource_guard_record")" = removing
"$RESOURCE" reap
test "$(jq -r '.status' "$resource_guard_record")" = removed

# The add wrapper uses the same guardian, so killing it cannot release the
# global lock while its direct Git add process is still running.
new_case mutation-lock-worktree-guardian
worktree_guard_repo="$HOME/repo"
worktree_guard_path="$HOME/in-flight"
worktree_guard_contender="$HOME/contender"
worktree_guard_ready="$HOME/add-blocked"
worktree_guard_release="$HOME/add-release"
create_repo "$worktree_guard_repo"
begin_session worktree-guardian-owner
begin_session worktree-guardian-contender
(
  cd "$worktree_guard_repo"
  exec env DOTFILES_AGENT_SESSION_ID=worktree-guardian-owner \
    DOTFILES_AGENT_TEST_ADD_READY="$worktree_guard_ready" \
    DOTFILES_AGENT_TEST_ADD_RELEASE="$worktree_guard_release" \
    "$RACE_WORKTREE" add --detach "$worktree_guard_path" HEAD
) >/dev/null &
worktree_guard_parent_pid=$!
trap ': >"$worktree_guard_release"; kill "$worktree_guard_parent_pid" 2>/dev/null || true' EXIT
worktree_guard_deadline=$((SECONDS + 5))
while [ ! -s "$worktree_guard_ready" ]; do
  if ((SECONDS >= worktree_guard_deadline)); then
    echo 'timed out waiting for blocked worktree Git child' >&2
    exit 1
  fi
done
worktree_guard_git_pid=$(<"$worktree_guard_ready")
kill -0 "$worktree_guard_git_pid"
kill -KILL "$worktree_guard_parent_pid"
set +e
wait "$worktree_guard_parent_pid"
worktree_guard_parent_status=$?
set -e
test "$worktree_guard_parent_status" -eq 137
kill -0 "$worktree_guard_git_pid"
(
  cd "$worktree_guard_repo"
  exec env DOTFILES_AGENT_SESSION_ID=worktree-guardian-contender \
    "$WORKTREE" add --detach "$worktree_guard_contender" HEAD
) >/dev/null &
worktree_guard_contender_pid=$!
trap ': >"$worktree_guard_release"; kill "$worktree_guard_contender_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  kill -0 "$worktree_guard_contender_pid"
  test ! -e "$worktree_guard_contender"
  sleep 0.01
done
: >"$worktree_guard_release"
wait "$worktree_guard_contender_pid"
trap - EXIT
test -d "$worktree_guard_path"
test -d "$worktree_guard_contender"
worktree_guard_owner_record=$(record_for_path "$worktree_guard_path")
test "$(jq -r '.session_id' "$worktree_guard_owner_record")" = worktree-guardian-owner
test "$(jq -r '.status' "$worktree_guard_owner_record")" = owned
worktree_guard_record=$(record_for_path "$worktree_guard_contender")
test "$(jq -r '.session_id' "$worktree_guard_record")" = worktree-guardian-contender
test "$(jq -r '.status' "$worktree_guard_record")" = owned

# If the outer transaction guardian is killed before Git starts, the inner Git
# guardian keeps the global lock until Git exits. Cleanup then sees the created
# but unvalidated target and preserves the adding intent.
new_case adding-guardian-before-git
adding_before_repo="$HOME/repo"
adding_before_path="$HOME/managed"
adding_before_ready="$HOME/git-before-ready"
adding_before_release="$HOME/git-before-release"
create_repo "$adding_before_repo"
begin_session adding-before-session
(
  cd "$adding_before_repo"
  exec env DOTFILES_AGENT_TEST_ADD_BEFORE_READY="$adding_before_ready" \
    DOTFILES_AGENT_TEST_ADD_BEFORE_RELEASE="$adding_before_release" \
    "$RACE_WORKTREE" add --detach "$adding_before_path" HEAD
) >/dev/null &
adding_before_parent_pid=$!
trap ': >"$adding_before_release"; kill "$adding_before_parent_pid" 2>/dev/null || true' EXIT
wait_for_file "$adding_before_ready"
adding_before_git_pid=$(<"$adding_before_ready")
adding_before_git_guardian_pid=$(proc_parent_pid "$adding_before_git_pid")
adding_before_transaction_guardian_pid=$(proc_parent_pid "$adding_before_git_guardian_pid")
test "$adding_before_transaction_guardian_pid" -ne "$adding_before_parent_pid"
kill -KILL "$adding_before_transaction_guardian_pid"
set +e
wait "$adding_before_parent_pid"
adding_before_parent_status=$?
set -e
test "$adding_before_parent_status" -eq 137
"$RESOURCE" cleanup-session adding-before-session >/dev/null &
adding_before_cleanup_pid=$!
trap ': >"$adding_before_release"; kill "$adding_before_cleanup_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  kill -0 "$adding_before_cleanup_pid"
  test ! -e "$adding_before_path"
  sleep 0.01
done
: >"$adding_before_release"
wait "$adding_before_cleanup_pid"
trap - EXIT
test -d "$adding_before_path"
adding_before_record=$(record_for_path "$adding_before_path")
test "$(jq -r '.status' "$adding_before_record")" = adding
test "$(jq -r '.last_reason' "$adding_before_record")" = adding-target-unproven

# Killing the transaction guardian after stable identity capture leaves an
# adding intent that cleanup can publish without deleting the worktree.
new_case adding-guardian-recovery
adding_recovery_repo="$HOME/repo"
adding_recovery_path="$HOME/managed"
adding_recovery_ready="$HOME/identity-ready"
adding_recovery_release="$HOME/identity-release"
create_repo "$adding_recovery_repo"
begin_session adding-recovery-session
(
  cd "$adding_recovery_repo"
  exec env DOTFILES_AGENT_TEST_ADD_IDENTITY_READY="$adding_recovery_ready" \
    DOTFILES_AGENT_TEST_ADD_IDENTITY_RELEASE="$adding_recovery_release" \
    "$ADDING_PAUSE_WORKTREE" add --detach "$adding_recovery_path" HEAD
) >/dev/null &
adding_recovery_parent_pid=$!
trap ': >"$adding_recovery_release"; kill "$adding_recovery_parent_pid" 2>/dev/null || true' EXIT
wait_for_file "$adding_recovery_ready"
adding_recovery_guardian_pid=$(<"$adding_recovery_ready")
kill -KILL "$adding_recovery_guardian_pid"
: >"$adding_recovery_release"
set +e
wait "$adding_recovery_parent_pid"
adding_recovery_status=$?
set -e
trap - EXIT
test "$adding_recovery_status" -eq 137
adding_recovery_record=$(record_for_path "$adding_recovery_path")
test "$(jq -r '.status' "$adding_recovery_record")" = adding
test "$(jq -r '.last_reason' "$adding_recovery_record")" = adding-validated
"$RESOURCE" cleanup-session adding-recovery-session
test -d "$adding_recovery_path"
test "$(jq -r '.status' "$adding_recovery_record")" = owned
test "$(jq -r '.last_reason' "$adding_recovery_record")" = adding-recovered

# An unmanaged replacement at the intended path cannot inherit a validated
# adding transaction, even when repository and HEAD still match.
new_case adding-guardian-replacement
adding_replacement_repo="$HOME/repo"
adding_replacement_path="$HOME/managed"
adding_replacement_safe="$HOME/original-added-worktree"
adding_replacement_ready="$HOME/identity-ready"
adding_replacement_release="$HOME/identity-release"
create_repo "$adding_replacement_repo"
begin_session adding-replacement-session
(
  cd "$adding_replacement_repo"
  exec env DOTFILES_AGENT_TEST_ADD_IDENTITY_READY="$adding_replacement_ready" \
    DOTFILES_AGENT_TEST_ADD_IDENTITY_RELEASE="$adding_replacement_release" \
    "$ADDING_PAUSE_WORKTREE" add --detach "$adding_replacement_path" HEAD
) >/dev/null &
adding_replacement_parent_pid=$!
trap ': >"$adding_replacement_release"; kill "$adding_replacement_parent_pid" 2>/dev/null || true' EXIT
wait_for_file "$adding_replacement_ready"
adding_replacement_guardian_pid=$(<"$adding_replacement_ready")
kill -KILL "$adding_replacement_guardian_pid"
: >"$adding_replacement_release"
set +e
wait "$adding_replacement_parent_pid"
adding_replacement_status=$?
set -e
trap - EXIT
test "$adding_replacement_status" -eq 137
adding_replacement_record=$(record_for_path "$adding_replacement_path")
"$REAL_GIT" --git-dir="$adding_replacement_repo/.git" worktree move -- \
  "$adding_replacement_path" "$adding_replacement_safe"
"$REAL_GIT" -C "$adding_replacement_repo" worktree add --detach \
  "$adding_replacement_path" HEAD
"$RESOURCE" cleanup-session adding-replacement-session
test -d "$adding_replacement_path"
test -d "$adding_replacement_safe"
test "$(jq -r '.status' "$adding_replacement_record")" = adding
test "$(jq -r '.last_reason' "$adding_replacement_record")" = adding-target-ambiguous

# A registration failure retains an unproven adding intent. Cleanup never
# rolls back by deleting either the added worktree or a later replacement.
new_case adding-registration-failure
adding_failure_repo="$HOME/repo"
adding_failure_path="$HOME/managed"
adding_failure_safe="$HOME/created-before-registration-failure"
create_repo "$adding_failure_repo"
begin_session adding-failure-session
set +e
(
  cd "$adding_failure_repo"
  DOTFILES_AGENT_TEST_FAIL_ADD_IDENTITY=1 \
    "$ADDING_PAUSE_WORKTREE" add --detach "$adding_failure_path" HEAD
) >/dev/null 2>&1
adding_failure_status=$?
set -e
test "$adding_failure_status" -ne 0
adding_failure_record=$(record_for_path "$adding_failure_path")
test "$(jq -r '.status' "$adding_failure_record")" = adding
test "$(jq -r 'has("git_dir")' "$adding_failure_record")" = false
"$REAL_GIT" --git-dir="$adding_failure_repo/.git" worktree move -- \
  "$adding_failure_path" "$adding_failure_safe"
"$RESOURCE" cleanup-session adding-failure-session
test ! -e "$adding_failure_path"
test -d "$adding_failure_safe"
test "$(jq -r '.status' "$adding_failure_record")" = adding
test "$(jq -r '.last_reason' "$adding_failure_record")" = adding-absent-roster-changed
"$REAL_GIT" -C "$adding_failure_repo" worktree add --detach \
  "$adding_failure_path" HEAD
"$RESOURCE" cleanup-session adding-failure-session
test -d "$adding_failure_path"
test -d "$adding_failure_safe"
test "$(jq -r '.status' "$adding_failure_record")" = adding
test "$(jq -r '.last_reason' "$adding_failure_record")" = adding-target-unproven

# A failed Git add leaves no path, so cleanup can discard only its adding
# intent without removing any filesystem or Git worktree state.
new_case adding-absent-recovery
adding_absent_repo="$HOME/repo"
adding_absent_path="$HOME/not-created"
create_repo "$adding_absent_repo"
begin_session adding-absent-session
set +e
(
  cd "$adding_absent_repo"
  DOTFILES_AGENT_TEST_FAIL_WORKTREE_ADD=1 \
    "$RACE_WORKTREE" add --detach "$adding_absent_path" HEAD
) >/dev/null 2>&1
adding_absent_status=$?
set -e
test "$adding_absent_status" -eq 73
adding_absent_record=$(record_for_path "$adding_absent_path")
test "$(jq -r '.status' "$adding_absent_record")" = adding
test ! -e "$adding_absent_path"
"$RESOURCE" cleanup-session adding-absent-session
test ! -e "$adding_absent_record"
test ! -e "$adding_absent_path"

# The shared lock path itself must be an owned, mode-0600 regular file.
new_case global-mutation-lock-ambiguous
mutation_ambiguous_repo="$HOME/repo"
mutation_ambiguous_path="$HOME/managed"
create_repo "$mutation_ambiguous_repo"
begin_session mutation-lock-ambiguous-session
mkdir "$(state_root)/locks/.worktree-mutation.lock"
set +e
(
  cd "$mutation_ambiguous_repo"
  "$WORKTREE" add --detach "$mutation_ambiguous_path" HEAD
) >/dev/null 2>&1
mutation_ambiguous_status=$?
set -e
test "$mutation_ambiguous_status" -eq 70
test ! -e "$mutation_ambiguous_path"

# Inherited descriptors are accepted only when they prove the same global lock
# and preserve the global-before-session ordering.
new_case mutation-lock-inherited-invalid
mutation_inherited_repo="$HOME/repo"
mutation_inherited_path="$HOME/managed"
create_repo "$mutation_inherited_repo"
begin_session mutation-lock-inherited-session
mutation_inherited_session="$(state_root)/sessions/mutation-lock-inherited-session.json"
mutation_inherited_before=$(<"$mutation_inherited_session")
set +e
DOTFILES_AGENT_MUTATION_LOCK_FD=7 \
  "$RESOURCE" validate-session mutation-lock-inherited-session >/dev/null 2>&1
mutation_missing_fd_status=$?
set -e
test "$mutation_missing_fd_status" -eq 70
test "$(<"$mutation_inherited_session")" = "$mutation_inherited_before"
mutation_other_lock="$HOME/other.lock"
: >"$mutation_other_lock"
chmod 600 "$mutation_other_lock"
exec 7<>"$mutation_other_lock"
set +e
DOTFILES_AGENT_MUTATION_LOCK_FD=7 \
  "$RESOURCE" validate-session mutation-lock-inherited-session >/dev/null 2>&1
mutation_wrong_fd_status=$?
set -e
exec 7>&-
test "$mutation_wrong_fd_status" -eq 70
test "$(<"$mutation_inherited_session")" = "$mutation_inherited_before"
add_managed_worktree "$mutation_inherited_repo" "$mutation_inherited_path"
mutation_inherited_record=$(record_for_path "$mutation_inherited_path")
mutation_inherited_before=$(<"$mutation_inherited_record")
exec 8<>"$(state_root)/locks/mutation-lock-inherited-session.lock"
flock -x 8
set +e
DOTFILES_AGENT_CREATION_LOCK_FD=8 \
  "$RESOURCE" cleanup-session mutation-lock-inherited-session >/dev/null 2>&1
mutation_reverse_order_status=$?
set -e
exec 8>&-
test "$mutation_reverse_order_status" -eq 70
test -d "$mutation_inherited_path"
test "$(<"$mutation_inherited_record")" = "$mutation_inherited_before"

# Git hooks may leave background processes, but those processes must not retain
# either managed lock descriptor after the add transaction exits.
new_case mutation-lock-hook-fd
mutation_hook_repo="$HOME/repo"
mutation_hook_path="$HOME/managed"
mutation_hook_pid_file="$HOME/hook-pid"
create_repo "$mutation_hook_repo"
begin_session mutation-lock-hook-session
{
  printf '#!%s\n' "$TEST_BASH"
  # shellcheck disable=SC2016 # The generated hook expands these variables.
  printf '%s\n' 'sleep 30 &' 'printf '\''%s\n'\'' "$!" >"$DOTFILES_AGENT_TEST_HOOK_PID_FILE"'
} >"$mutation_hook_repo/.git/hooks/post-checkout"
chmod 700 "$mutation_hook_repo/.git/hooks/post-checkout"
export DOTFILES_AGENT_TEST_HOOK_PID_FILE=$mutation_hook_pid_file
add_managed_worktree "$mutation_hook_repo" "$mutation_hook_path"
unset DOTFILES_AGENT_TEST_HOOK_PID_FILE
mutation_hook_pid=$(<"$mutation_hook_pid_file")
[[ $mutation_hook_pid =~ ^[0-9]+$ ]]
trap 'kill "$mutation_hook_pid" 2>/dev/null || true' EXIT
kill -0 "$mutation_hook_pid"
if [ -e "/proc/$mutation_hook_pid/fd/7" ] || [ -e "/proc/$mutation_hook_pid/fd/8" ]; then
  echo 'background Git hook retained a managed lock descriptor' >&2
  exit 1
fi
kill "$mutation_hook_pid"
trap - EXIT

# Without an explicit commit-ish or branch mode, Git selects an existing local
# branch whose name matches the target basename instead of repository HEAD.
new_case add-implicit-existing-branch
implicit_repo="$HOME/repo"
implicit_path="$HOME/named-target"
create_repo "$implicit_repo"
implicit_head_a=$("$REAL_GIT" -C "$implicit_repo" rev-parse HEAD)
printf 'branch-b\n' >"$implicit_repo/tracked"
"$REAL_GIT" -C "$implicit_repo" commit -qam branch-b
implicit_head_b=$("$REAL_GIT" -C "$implicit_repo" rev-parse HEAD)
"$REAL_GIT" -C "$implicit_repo" branch named-target "$implicit_head_b"
"$REAL_GIT" -C "$implicit_repo" reset --hard -q "$implicit_head_a"
begin_session implicit-branch-session
set +e
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_path" >/dev/null
)
implicit_add_status=$?
set -e
test "$implicit_add_status" -eq 0
implicit_record=$(record_for_path "$implicit_path")
test "$(jq -r '.status' "$implicit_record")" = owned
test "$(jq -r '.initial_head' "$implicit_record")" = "$implicit_head_b"
test "$("$REAL_GIT" -C "$implicit_path" rev-parse HEAD)" = "$implicit_head_b"

# Without a matching local branch, Git creates the basename branch from HEAD.
implicit_new_path="$HOME/new-target"
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_new_path" >/dev/null
)
implicit_new_record=$(record_for_path "$implicit_new_path")
test "$(jq -r '.status' "$implicit_new_record")" = owned
test "$(jq -r '.initial_head' "$implicit_new_record")" = "$implicit_head_a"
test "$("$REAL_GIT" -C "$implicit_repo" rev-parse refs/heads/new-target)" = "$implicit_head_a"

# An explicit commit-ish wins even when the target basename names another
# existing local branch.
implicit_explicit_path="$HOME/explicit-target"
"$REAL_GIT" -C "$implicit_repo" branch explicit-target "$implicit_head_b"
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_explicit_path" "$implicit_head_a" >/dev/null
)
implicit_explicit_record=$(record_for_path "$implicit_explicit_path")
test "$(jq -r '.status' "$implicit_explicit_record")" = owned
test "$(jq -r '.initial_head' "$implicit_explicit_record")" = "$implicit_head_a"
test "$("$REAL_GIT" -C "$implicit_explicit_path" rev-parse HEAD)" = "$implicit_head_a"

# worktree.guessRemote=true makes Git use a unique matching remote-tracking
# branch; false keeps the normal HEAD/new-branch fallback.
implicit_remote="$HOME/remote.git"
implicit_remote_path="$HOME/remote-target"
implicit_remote_disabled_path="$HOME/remote-disabled"
implicit_explicit_remote_path="$HOME/explicit-remote-path"
implicit_default_remote_path="$HOME/ambiguous-target"
"$REAL_GIT" init --bare -q "$implicit_remote"
"$REAL_GIT" -C "$implicit_repo" remote add origin "$implicit_remote"
"$REAL_GIT" -C "$implicit_repo" push -q origin \
  "$implicit_head_b:refs/heads/remote-target" \
  "$implicit_head_b:refs/heads/remote-disabled" \
  "$implicit_head_b:refs/heads/explicit-remote" \
  "$implicit_head_b:refs/heads/ambiguous-target"
"$REAL_GIT" -C "$implicit_repo" fetch -q origin
"$REAL_GIT" -C "$implicit_repo" config worktree.guessRemote true
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_remote_path" >/dev/null
)
implicit_remote_record=$(record_for_path "$implicit_remote_path")
test "$(jq -r '.status' "$implicit_remote_record")" = owned
test "$(jq -r '.initial_head' "$implicit_remote_record")" = "$implicit_head_b"
test "$("$REAL_GIT" -C "$implicit_remote_path" rev-parse HEAD)" = "$implicit_head_b"
"$REAL_GIT" -C "$implicit_repo" config worktree.guessRemote false
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_remote_disabled_path" >/dev/null
)
implicit_remote_disabled_record=$(record_for_path "$implicit_remote_disabled_path")
test "$(jq -r '.status' "$implicit_remote_disabled_record")" = owned
test "$(jq -r '.initial_head' "$implicit_remote_disabled_record")" = "$implicit_head_a"
test "$("$REAL_GIT" -C "$implicit_remote_disabled_path" rev-parse HEAD)" = "$implicit_head_a"

# An explicit missing local branch still uses Git's unique remote fallback,
# regardless of worktree.guessRemote.
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_explicit_remote_path" explicit-remote >/dev/null
)
implicit_explicit_remote_record=$(record_for_path "$implicit_explicit_remote_path")
test "$(jq -r '.status' "$implicit_explicit_remote_record")" = owned
test "$(jq -r '.initial_head' "$implicit_explicit_remote_record")" = "$implicit_head_b"
test "$("$REAL_GIT" -C "$implicit_explicit_remote_path" rev-parse HEAD)" = "$implicit_head_b"

# checkout.defaultRemote selects one matching branch when multiple remotes have
# the same branch name.
implicit_other_remote="$HOME/other.git"
"$REAL_GIT" init --bare -q "$implicit_other_remote"
"$REAL_GIT" -C "$implicit_repo" remote add other "$implicit_other_remote"
"$REAL_GIT" -C "$implicit_repo" push -q other \
  "$implicit_head_a:refs/heads/ambiguous-target"
"$REAL_GIT" -C "$implicit_repo" fetch -q other
"$REAL_GIT" -C "$implicit_repo" config worktree.guessRemote true
"$REAL_GIT" -C "$implicit_repo" config checkout.defaultRemote origin
(
  cd "$implicit_repo"
  "$WORKTREE" add "$implicit_default_remote_path" >/dev/null
)
implicit_default_remote_record=$(record_for_path "$implicit_default_remote_path")
test "$(jq -r '.status' "$implicit_default_remote_record")" = owned
test "$(jq -r '.initial_head' "$implicit_default_remote_record")" = "$implicit_head_b"
test "$("$REAL_GIT" -C "$implicit_default_remote_path" rev-parse HEAD)" = "$implicit_head_b"
"$RESOURCE" cleanup-session implicit-branch-session
test ! -e "$implicit_path"
test ! -e "$implicit_new_path"
test ! -e "$implicit_explicit_path"
test ! -e "$implicit_remote_path"
test ! -e "$implicit_remote_disabled_path"
test ! -e "$implicit_explicit_remote_path"
test ! -e "$implicit_default_remote_path"

# Git interprets a literal `-` commit-ish as the previous checkout. The managed
# wrapper predicts the same commit while forwarding the original argument.
new_case add-checkout-alias
alias_repo="$HOME/repo"
alias_path="$HOME/alias-target"
alias_explicit_path="$HOME/explicit-alias-target"
alias_git_log="$HOME/git.log"
create_repo "$alias_repo"
alias_initial_branch=$("$REAL_GIT" -C "$alias_repo" symbolic-ref --short HEAD)
alias_head_a=$("$REAL_GIT" -C "$alias_repo" rev-parse HEAD)
"$REAL_GIT" -C "$alias_repo" checkout -qb alias-previous
printf 'previous-checkout\n' >"$alias_repo/tracked"
"$REAL_GIT" -C "$alias_repo" commit -qam previous-checkout
alias_head_b=$("$REAL_GIT" -C "$alias_repo" rev-parse HEAD)
"$REAL_GIT" -C "$alias_repo" checkout -q "$alias_initial_branch"
test "$("$REAL_GIT" -C "$alias_repo" rev-parse '@{-1}^{commit}')" = "$alias_head_b"
test "$alias_head_a" != "$alias_head_b"
begin_session add-checkout-alias-session
(
  cd "$alias_repo"
  DOTFILES_AGENT_TEST_GIT_LOG="$alias_git_log" \
    "$AUDIT_WORKTREE" add "$alias_path" - >/dev/null
  "$WORKTREE" add --detach "$alias_explicit_path" '@{-1}' >/dev/null
)
grep -Fqx $'git\tworktree\tadd\t'"$alias_path"$'\t-' "$alias_git_log"
alias_record=$(record_for_path "$alias_path")
alias_explicit_record=$(record_for_path "$alias_explicit_path")
test "$(jq -r '.status' "$alias_record")" = owned
test "$(jq -r '.initial_head' "$alias_record")" = "$alias_head_b"
test "$("$REAL_GIT" -C "$alias_path" rev-parse HEAD)" = "$alias_head_b"
test "$(jq -r '.status' "$alias_explicit_record")" = owned
test "$(jq -r '.initial_head' "$alias_explicit_record")" = "$alias_head_b"
test "$("$REAL_GIT" -C "$alias_explicit_path" rev-parse HEAD)" = "$alias_head_b"
"$RESOURCE" cleanup-session add-checkout-alias-session
test ! -e "$alias_path"
test ! -e "$alias_explicit_path"

# With no previous checkout, both Git and the wrapper fail before creating a
# path. The wrapper must not publish even a nonterminal ledger record.
new_case add-checkout-alias-missing
alias_missing_repo="$HOME/repo"
alias_missing_direct_path="$HOME/direct-alias-target"
alias_missing_wrapper_path="$HOME/wrapper-alias-target"
create_repo "$alias_missing_repo"
begin_session add-checkout-alias-missing-session
set +e
"$REAL_GIT" -C "$alias_missing_repo" worktree add \
  "$alias_missing_direct_path" - >/dev/null 2>"$HOME/direct-alias.log"
alias_missing_direct_status=$?
(
  cd "$alias_missing_repo"
  "$WORKTREE" add "$alias_missing_wrapper_path" - \
    >/dev/null 2>"$HOME/wrapper-alias.log"
)
alias_missing_wrapper_status=$?
set -e
test "$alias_missing_direct_status" -ne 0
test "$alias_missing_wrapper_status" -ne 0
test ! -e "$alias_missing_direct_path"
test ! -e "$alias_missing_wrapper_path"
if record_for_path "$alias_missing_wrapper_path" >/dev/null 2>&1; then
  echo 'failed checkout alias published a worktree ledger record' >&2
  exit 1
fi

# Git creates a linked worktree from an unborn HEAD when no commit-ish is
# supplied. The roster represents that HEAD with the object-format zero OID.
new_case add-unborn
unborn_direct_repo="$HOME/direct-repo"
unborn_direct_path="$HOME/direct-unborn"
unborn_repo="$HOME/repo"
unborn_path="$HOME/managed-unborn"
unborn_git_log="$HOME/git.log"
mkdir -p "$unborn_direct_repo" "$unborn_repo"
"$REAL_GIT" -C "$unborn_direct_repo" init -q
"$REAL_GIT" -C "$unborn_repo" init -q
unborn_probe_oid=$("$REAL_GIT" -C "$unborn_repo" hash-object --stdin </dev/null)
unborn_zero_oid=$(printf '%0*d' "${#unborn_probe_oid}" 0)
test "${#unborn_zero_oid}" -eq 40 || test "${#unborn_zero_oid}" -eq 64
"$REAL_GIT" -C "$unborn_direct_repo" worktree add "$unborn_direct_path" >/dev/null
test -d "$unborn_direct_path"
set +e
"$REAL_GIT" -C "$unborn_direct_path" rev-parse --verify HEAD >/dev/null 2>&1
unborn_direct_head_status=$?
set -e
test "$unborn_direct_head_status" -ne 0
"$REAL_GIT" -C "$unborn_direct_repo" worktree remove -- "$unborn_direct_path"
test ! -e "$unborn_direct_path"

begin_session add-unborn-session
(
  cd "$unborn_repo"
  DOTFILES_AGENT_TEST_GIT_LOG="$unborn_git_log" \
    "$AUDIT_WORKTREE" add "$unborn_path" >/dev/null
)
grep -Fqx $'git\tworktree\tadd\t'"$unborn_path" "$unborn_git_log"
unborn_record=$(record_for_path "$unborn_path")
test "$(jq -r '.status' "$unborn_record")" = owned
test "$(jq -r '.initial_head' "$unborn_record")" = "$unborn_zero_oid"
unborn_head_ref=$("$REAL_GIT" -C "$unborn_path" symbolic-ref -q HEAD)
test "$unborn_head_ref" = refs/heads/managed-unborn
set +e
"$REAL_GIT" -C "$unborn_path" rev-parse --verify HEAD >/dev/null 2>&1
unborn_head_status=$?
"$REAL_GIT" -C "$unborn_path" show-ref --exists "$unborn_head_ref"
unborn_ref_status=$?
set -e
test "$unborn_head_status" -ne 0
test "$unborn_ref_status" -eq 2
"$RESOURCE" cleanup-session add-unborn-session
test ! -e "$unborn_path"
test "$(jq -r '.status' "$unborn_record")" = removed
test "$(jq -r '.last_reason' "$unborn_record")" = clean-unchanged-inactive

# If the add guardian is killed after stable identity capture, recovery proves
# the exact unborn target from its zero OID before publishing ownership.
new_case add-unborn-guardian-recovery
unborn_recovery_repo="$HOME/repo"
unborn_recovery_path="$HOME/managed-unborn"
unborn_recovery_ready="$HOME/identity-ready"
unborn_recovery_release="$HOME/identity-release"
mkdir -p "$unborn_recovery_repo"
"$REAL_GIT" -C "$unborn_recovery_repo" init -q
unborn_recovery_probe=$("$REAL_GIT" -C "$unborn_recovery_repo" hash-object --stdin </dev/null)
unborn_recovery_zero=$(printf '%0*d' "${#unborn_recovery_probe}" 0)
begin_session add-unborn-recovery-session
(
  cd "$unborn_recovery_repo"
  exec env DOTFILES_AGENT_TEST_ADD_IDENTITY_READY="$unborn_recovery_ready" \
    DOTFILES_AGENT_TEST_ADD_IDENTITY_RELEASE="$unborn_recovery_release" \
    "$ADDING_PAUSE_WORKTREE" add "$unborn_recovery_path"
) >/dev/null &
unborn_recovery_parent_pid=$!
trap ': >"$unborn_recovery_release"; kill "$unborn_recovery_parent_pid" 2>/dev/null || true' EXIT
wait_for_file "$unborn_recovery_ready"
unborn_recovery_guardian_pid=$(<"$unborn_recovery_ready")
kill -KILL "$unborn_recovery_guardian_pid"
: >"$unborn_recovery_release"
set +e
wait "$unborn_recovery_parent_pid"
unborn_recovery_status=$?
set -e
trap - EXIT
test "$unborn_recovery_status" -eq 137
unborn_recovery_record=$(record_for_path "$unborn_recovery_path")
test "$(jq -r '.status' "$unborn_recovery_record")" = adding
test "$(jq -r '.last_reason' "$unborn_recovery_record")" = adding-validated
test "$(jq -r '.initial_head' "$unborn_recovery_record")" = "$unborn_recovery_zero"
"$RESOURCE" cleanup-session add-unborn-recovery-session
test -d "$unborn_recovery_path"
test "$(jq -r '.status' "$unborn_recovery_record")" = owned
test "$(jq -r '.last_reason' "$unborn_recovery_record")" = adding-recovered
"$RESOURCE" cleanup-session add-unborn-recovery-session
test ! -e "$unborn_recovery_path"
test "$(jq -r '.status' "$unborn_recovery_record")" = removed

# Object-format detection produces the matching 64-character zero OID for an
# unborn SHA-256 repository and carries it through removal.
new_case add-unborn-sha256
unborn_sha256_repo="$HOME/repo"
unborn_sha256_path="$HOME/managed-unborn"
mkdir -p "$unborn_sha256_repo"
"$REAL_GIT" -C "$unborn_sha256_repo" init -q --object-format=sha256
unborn_sha256_probe=$("$REAL_GIT" -C "$unborn_sha256_repo" hash-object --stdin </dev/null)
unborn_sha256_zero=$(printf '%0*d' "${#unborn_sha256_probe}" 0)
test "${#unborn_sha256_zero}" -eq 64
begin_session add-unborn-sha256-session
(
  cd "$unborn_sha256_repo"
  "$WORKTREE" add "$unborn_sha256_path" >/dev/null
)
unborn_sha256_record=$(record_for_path "$unborn_sha256_path")
test "$(jq -r '.status' "$unborn_sha256_record")" = owned
test "$(jq -r '.initial_head' "$unborn_sha256_record")" = "$unborn_sha256_zero"
"$RESOURCE" cleanup-session add-unborn-sha256-session
test ! -e "$unborn_sha256_path"
test "$(jq -r '.status' "$unborn_sha256_record")" = removed

# Reaping a dead owner uses the same exact zero-OID identity proof before
# removing an unchanged unborn worktree.
new_case add-unborn-reap
unborn_reap_repo="$HOME/repo"
unborn_reap_path="$HOME/managed-unborn"
mkdir -p "$unborn_reap_repo"
"$REAL_GIT" -C "$unborn_reap_repo" init -q
sleep infinity &
unborn_reap_owner_pid=$!
trap 'kill "$unborn_reap_owner_pid" 2>/dev/null || true' EXIT
begin_session add-unborn-reap-session "$unborn_reap_owner_pid"
(
  cd "$unborn_reap_repo"
  "$WORKTREE" add "$unborn_reap_path" >/dev/null
)
unborn_reap_record=$(record_for_path "$unborn_reap_path")
kill "$unborn_reap_owner_pid"
wait "$unborn_reap_owner_pid" 2>/dev/null || true
trap - EXIT
"$RESOURCE" reap
test ! -e "$unborn_reap_path"
test "$(jq -r '.status' "$unborn_reap_record")" = removed

# Creating the first commit changes the semantic HEAD away from the owned zero
# OID, so cleanup preserves the worktree even when its status is clean.
new_case add-unborn-first-commit
unborn_commit_repo="$HOME/repo"
unborn_commit_path="$HOME/managed-unborn"
mkdir -p "$unborn_commit_repo"
"$REAL_GIT" -C "$unborn_commit_repo" init -q
"$REAL_GIT" -C "$unborn_commit_repo" config user.name fixture
"$REAL_GIT" -C "$unborn_commit_repo" config user.email fixture@example.invalid
begin_session add-unborn-first-commit-session
(
  cd "$unborn_commit_repo"
  "$WORKTREE" add "$unborn_commit_path" >/dev/null
)
unborn_commit_record=$(record_for_path "$unborn_commit_path")
"$REAL_GIT" -C "$unborn_commit_path" commit --allow-empty -qm first
test -n "$("$REAL_GIT" -C "$unborn_commit_path" rev-parse --verify 'HEAD^{commit}')"
"$RESOURCE" cleanup-session add-unborn-first-commit-session
test -d "$unborn_commit_path"
test "$(jq -r '.status' "$unborn_commit_record")" = preserved
test "$(jq -r '.last_reason' "$unborn_commit_record")" = head-changed

# Explicit -b/-B branch creation also infers an orphan when commit-ish is
# omitted and no local branches exist.
new_case add-unborn-explicit-branch
unborn_branch_repo="$HOME/repo"
unborn_branch_b_path="$HOME/branch-b"
unborn_branch_B_path="$HOME/branch-B"
mkdir -p "$unborn_branch_repo"
"$REAL_GIT" -C "$unborn_branch_repo" init -q
unborn_branch_probe=$("$REAL_GIT" -C "$unborn_branch_repo" hash-object --stdin </dev/null)
unborn_branch_zero=$(printf '%0*d' "${#unborn_branch_probe}" 0)
begin_session add-unborn-explicit-branch-session
(
  cd "$unborn_branch_repo"
  "$WORKTREE" add -b unborn-branch-b "$unborn_branch_b_path" >/dev/null
  "$WORKTREE" add -B unborn-branch-B "$unborn_branch_B_path" >/dev/null
)
unborn_branch_b_record=$(record_for_path "$unborn_branch_b_path")
unborn_branch_B_record=$(record_for_path "$unborn_branch_B_path")
test "$(jq -r '.status' "$unborn_branch_b_record")" = owned
test "$(jq -r '.initial_head' "$unborn_branch_b_record")" = "$unborn_branch_zero"
test "$(jq -r '.status' "$unborn_branch_B_record")" = owned
test "$(jq -r '.initial_head' "$unborn_branch_B_record")" = "$unborn_branch_zero"
"$RESOURCE" cleanup-session add-unborn-explicit-branch-session
test ! -e "$unborn_branch_b_path"
test ! -e "$unborn_branch_B_path"

# Inferred orphan cannot be combined with --no-checkout. The wrapper fails
# before publishing an intent, matching Git's path-preserving failure.
new_case add-unborn-no-checkout
unborn_no_checkout_repo="$HOME/repo"
unborn_no_checkout_direct="$HOME/direct"
unborn_no_checkout_wrapper="$HOME/managed"
mkdir -p "$unborn_no_checkout_repo"
"$REAL_GIT" -C "$unborn_no_checkout_repo" init -q
begin_session add-unborn-no-checkout-session
set +e
"$REAL_GIT" -C "$unborn_no_checkout_repo" worktree add --no-checkout \
  "$unborn_no_checkout_direct" >/dev/null 2>&1
unborn_no_checkout_direct_status=$?
(
  cd "$unborn_no_checkout_repo"
  "$WORKTREE" add --no-checkout "$unborn_no_checkout_wrapper" >/dev/null 2>&1
)
unborn_no_checkout_wrapper_status=$?
set -e
test "$unborn_no_checkout_direct_status" -ne 0
test "$unborn_no_checkout_wrapper_status" -ne 0
test ! -e "$unborn_no_checkout_direct"
test ! -e "$unborn_no_checkout_wrapper"
if record_for_path "$unborn_no_checkout_wrapper" >/dev/null 2>&1; then
  echo 'invalid unborn --no-checkout add published a ledger record' >&2
  exit 1
fi

# A malformed guessRemote boolean is a Git error, not an implicit false value.
# It must fail before an unborn adding intent is persisted.
new_case add-unborn-invalid-guess-remote
unborn_invalid_config_repo="$HOME/repo"
unborn_invalid_config_direct="$HOME/direct"
unborn_invalid_config_wrapper="$HOME/managed"
unborn_invalid_config_log="$HOME/git.log"
mkdir -p "$unborn_invalid_config_repo"
"$REAL_GIT" -C "$unborn_invalid_config_repo" init -q
"$REAL_GIT" -C "$unborn_invalid_config_repo" config worktree.guessRemote bogus
begin_session add-unborn-invalid-guess-remote-session
set +e
"$REAL_GIT" -C "$unborn_invalid_config_repo" worktree add \
  "$unborn_invalid_config_direct" >/dev/null 2>&1
unborn_invalid_config_direct_status=$?
"$REAL_GIT" -C "$unborn_invalid_config_repo" config --unset worktree.guessRemote
(
  cd "$unborn_invalid_config_repo"
  DOTFILES_AGENT_TEST_GIT_LOG="$unborn_invalid_config_log" \
    DOTFILES_AGENT_TEST_FAIL_GUESS_REMOTE_CONFIG=1 \
    "$AUDIT_WORKTREE" add "$unborn_invalid_config_wrapper" >/dev/null 2>&1
)
unborn_invalid_config_wrapper_status=$?
set -e
test "$unborn_invalid_config_direct_status" -ne 0
test "$unborn_invalid_config_wrapper_status" -ne 0
test ! -e "$unborn_invalid_config_direct"
test ! -e "$unborn_invalid_config_wrapper"
unborn_invalid_config_call=$'git\tconfig\t--type=bool\t--get\tworktree.guessRemote'
test "$(grep -Fxc "$unborn_invalid_config_call" "$unborn_invalid_config_log")" -eq 1
test "$(tail -n 1 "$unborn_invalid_config_log")" = "$unborn_invalid_config_call"
if grep -Fq $'git\tworktree\tadd\t'"$unborn_invalid_config_wrapper" \
  "$unborn_invalid_config_log"; then
  echo 'invalid guessRemote config reached git worktree add' >&2
  exit 1
fi
if record_for_path "$unborn_invalid_config_wrapper" >/dev/null 2>&1; then
  echo 'invalid guessRemote config published an unborn ledger record' >&2
  exit 1
fi

# A remote-ref scan error is not equivalent to finding no matching remote.
# It must stop prediction before an add intent or target can be created.
new_case add-remote-scan-error
remote_error_repo="$HOME/repo"
remote_error_path="$HOME/managed"
remote_error_log="$HOME/git.log"
create_repo "$remote_error_repo"
"$REAL_GIT" -C "$remote_error_repo" config worktree.guessRemote true
begin_session add-remote-scan-error-session
set +e
(
  cd "$remote_error_repo"
  DOTFILES_AGENT_TEST_GIT_LOG="$remote_error_log" \
    DOTFILES_AGENT_TEST_FAIL_REMOTE_REF_SCAN_STATUS=1 \
    "$AUDIT_WORKTREE" add "$remote_error_path" >/dev/null 2>&1
)
remote_error_status=$?
set -e
test "$remote_error_status" -ne 0
test ! -e "$remote_error_path"
remote_error_call=$'git\tfor-each-ref\t--format=%(refname)\trefs/remotes/*/managed'
test "$(tail -n 1 "$remote_error_log")" = "$remote_error_call"
if grep -Fq $'git\tworktree\tadd\t' "$remote_error_log"; then
  echo 'failed remote ref scan reached git worktree add' >&2
  exit 1
fi
if record_for_path "$remote_error_path" >/dev/null 2>&1; then
  echo 'failed remote ref scan published an add ledger record' >&2
  exit 1
fi

# An unborn current HEAD does not trigger inference when another local branch
# exists. A failed real Git add must leave neither a path nor an intent.
new_case add-unborn-existing-local
unborn_local_repo="$HOME/repo"
unborn_local_direct="$HOME/direct"
unborn_local_wrapper="$HOME/managed"
create_repo "$unborn_local_repo"
"$REAL_GIT" -C "$unborn_local_repo" symbolic-ref HEAD refs/heads/unborn-current
begin_session add-unborn-existing-local-session
set +e
"$REAL_GIT" -C "$unborn_local_repo" worktree add \
  "$unborn_local_direct" >/dev/null 2>&1
unborn_local_direct_status=$?
(
  cd "$unborn_local_repo"
  "$WORKTREE" add "$unborn_local_wrapper" >/dev/null 2>&1
)
unborn_local_wrapper_status=$?
set -e
test "$unborn_local_direct_status" -ne 0
test "$unborn_local_wrapper_status" -ne 0
test ! -e "$unborn_local_direct"
test ! -e "$unborn_local_wrapper"
if record_for_path "$unborn_local_wrapper" >/dev/null 2>&1; then
  echo 'failed add with an existing local branch published a ledger record' >&2
  exit 1
fi

# The source linked worktree owns its own HEAD. A committed main-worktree HEAD
# must not override an unborn invoking worktree during pre-intent validation.
new_case add-unborn-linked-source
unborn_linked_repo="$HOME/repo"
unborn_linked_source="$HOME/source-unborn"
unborn_linked_target="$HOME/managed-unborn"
create_repo "$unborn_linked_repo"
unborn_linked_commit=$("$REAL_GIT" -C "$unborn_linked_repo" rev-parse HEAD)
"$REAL_GIT" -C "$unborn_linked_repo" worktree add --orphan -b source-unborn \
  "$unborn_linked_source" >/dev/null
"$REAL_GIT" -C "$unborn_linked_repo" checkout --detach -q "$unborn_linked_commit"
unborn_linked_initial_branch=$("$REAL_GIT" -C "$unborn_linked_repo" \
  for-each-ref --format='%(refname:short)' --count=1 refs/heads)
"$REAL_GIT" -C "$unborn_linked_repo" branch -D "$unborn_linked_initial_branch" >/dev/null
test -z "$("$REAL_GIT" -C "$unborn_linked_repo" for-each-ref \
  --format='%(refname)' refs/heads)"
unborn_linked_probe=$("$REAL_GIT" -C "$unborn_linked_repo" hash-object --stdin </dev/null)
unborn_linked_zero=$(printf '%0*d' "${#unborn_linked_probe}" 0)
begin_session add-unborn-linked-source-session
(
  cd "$unborn_linked_source"
  "$WORKTREE" add "$unborn_linked_target" >/dev/null
)
unborn_linked_record=$(record_for_path "$unborn_linked_target")
test "$(jq -r '.status' "$unborn_linked_record")" = owned
test "$(jq -r '.initial_head' "$unborn_linked_record")" = "$unborn_linked_zero"
"$RESOURCE" cleanup-session add-unborn-linked-source-session
test ! -e "$unborn_linked_target"

# A zero-OID ledger cannot turn an arbitrary rev-parse failure on a committed
# branch into an unborn identity proof.
new_case add-unborn-head-error
unborn_error_repo="$HOME/repo"
unborn_error_path="$HOME/managed"
create_repo "$unborn_error_repo"
unborn_error_probe=$("$REAL_GIT" -C "$unborn_error_repo" hash-object --stdin </dev/null)
unborn_error_zero=$(printf '%0*d' "${#unborn_error_probe}" 0)
begin_session add-unborn-head-error-session
(
  cd "$unborn_error_repo"
  "$WORKTREE" add "$unborn_error_path" >/dev/null
)
unborn_error_record=$(record_for_path "$unborn_error_path")
jq --arg initial_head "$unborn_error_zero" '.initial_head = $initial_head' \
  "$unborn_error_record" >"$HOME/tampered-record.json"
mv -T -- "$HOME/tampered-record.json" "$unborn_error_record"
chmod 600 "$unborn_error_record"
DOTFILES_AGENT_TEST_FAIL_HEAD_PATH="$unborn_error_path" \
  "$AUDIT_RESOURCE" cleanup-session add-unborn-head-error-session
test -d "$unborn_error_path"
test "$(jq -r '.status' "$unborn_error_record")" = preserved
test "$(jq -r '.last_reason' "$unborn_error_record")" = head-missing

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

# Seven-day retention expires records at seven complete 24-hour periods. One
# second before the boundary remains; the exact boundary and one second beyond
# it are removable.
new_case seven-day-retention
begin_session seven-day-fresh-session
fresh_session="$(state_root)/sessions/seven-day-fresh-session.json"
"$RESOURCE" cleanup-session seven-day-fresh-session
begin_session seven-day-exact-session
exact_session="$(state_root)/sessions/seven-day-exact-session.json"
"$RESOURCE" cleanup-session seven-day-exact-session
begin_session seven-day-older-session
older_session="$(state_root)/sessions/seven-day-older-session.json"
"$RESOURCE" cleanup-session seven-day-older-session
fixed_retention_now=$(command date +%s)
jq --argjson timestamp "$((fixed_retention_now - 7 * 24 * 60 * 60 + 1))" \
  '.updated_at = $timestamp' "$fresh_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$fresh_session"
jq --argjson timestamp "$((fixed_retention_now - 7 * 24 * 60 * 60))" \
  '.updated_at = $timestamp' "$exact_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$exact_session"
jq --argjson timestamp "$((fixed_retention_now - 7 * 24 * 60 * 60 - 1))" \
  '.updated_at = $timestamp' "$older_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$older_session"
# shellcheck disable=SC2329 # Exported for the packaged resource subprocess.
date() {
  printf '%s\n' "$DOTFILES_AGENT_TEST_FIXED_NOW"
}
export -f date
DOTFILES_AGENT_TEST_FIXED_NOW=$fixed_retention_now \
  "$SEVEN_DAY_RESOURCE" reap
unset -f date
if [ ! -e "$fresh_session" ]; then
  echo 'seven-day retention expired a ledger before seven complete days' >&2
  exit 1
fi
if [ -e "$exact_session" ]; then
  echo 'seven-day retention kept a ledger at the exact expiry boundary' >&2
  exit 1
fi
if [ -e "$older_session" ]; then
  echo 'seven-day retention kept a ledger beyond the expiry boundary' >&2
  exit 1
fi

# Adding is a recoverable creation phase and is never retention eligible.
new_case adding-retention
begin_session adding-retention-session
adding_retention_common="$HOME/repo/.git"
adding_retention_path="$HOME/managed"
adding_retention_record_id=$(printf '%s\0%s' "$adding_retention_common" \
  "$adding_retention_path" | sha256sum | cut -d ' ' -f 1)
adding_retention_record="$(state_root)/worktrees/$adding_retention_record_id.json"
jq -cn \
  --arg common_dir "$adding_retention_common" \
  --arg path "$adding_retention_path" \
  --arg roster_fingerprint "$(printf '%064d' 0)" \
  '{version: 1, session_id: "adding-retention-session",
    common_dir: $common_dir, path: $path, requested_head: "HEAD",
    roster_fingerprint: $roster_fingerprint, parent_device: "0", parent_inode: "0",
    initial_head: "0000000000000000000000000000000000000000",
    status: "adding", last_reason: "adding", updated_at: 0}' \
  >"$adding_retention_record"
chmod 600 "$adding_retention_record"
"$SEVEN_DAY_RESOURCE" reap
test -f "$adding_retention_record"
test "$(jq -r '.status' "$adding_retention_record")" = adding

# Quarantining is a recoverable transaction state, not a terminal retention
# state, even when its timestamp is older than the configured boundary.
new_case quarantining-retention
begin_session quarantining-retention-session
quarantining_common="$HOME/repo/.git"
quarantining_path="$HOME/managed"
quarantining_path_intent="$HOME/.dotfiles-agent-quarantine.fixture/worktree"
quarantining_git_dir="$HOME/repo/.git/worktrees/managed"
quarantining_device=0
quarantining_inode=0
quarantining_record_id=$(printf '%s\0%s' "$quarantining_common" \
  "$quarantining_path" | sha256sum | cut -d ' ' -f 1)
quarantining_record="$(state_root)/worktrees/$quarantining_record_id.json"
jq -cn \
  --arg common_dir "$quarantining_common" \
  --arg git_dir "$quarantining_git_dir" \
  --arg path "$quarantining_path" \
  --arg quarantine_path "$quarantining_path_intent" \
  --arg worktree_device "$quarantining_device" \
  --arg worktree_inode "$quarantining_inode" \
  '{version: 1, session_id: "quarantining-retention-session",
    common_dir: $common_dir, git_dir: $git_dir, path: $path,
    quarantine_path: $quarantine_path,
    initial_head: "0000000000000000000000000000000000000000",
    status: "quarantining", last_reason: "quarantining", updated_at: 0,
    worktree_device: $worktree_device, worktree_inode: $worktree_inode}' \
  >"$quarantining_record"
chmod 600 "$quarantining_record"
"$SEVEN_DAY_RESOURCE" reap
test -f "$quarantining_record"
test "$(jq -r '.status' "$quarantining_record")" = quarantining

# Removing is also a recoverable transaction phase and is never retention
# eligible, even when its timestamp is older than the configured boundary.
new_case removing-retention
begin_session removing-retention-session
removing_retention_common="$HOME/repo/.git"
removing_retention_path="$HOME/managed"
removing_retention_quarantine="$HOME/.dotfiles-agent-quarantine.fixture/worktree"
removing_retention_git_dir="$HOME/repo/.git/worktrees/managed"
removing_retention_record_id=$(printf '%s\0%s' "$removing_retention_common" \
  "$removing_retention_path" | sha256sum | cut -d ' ' -f 1)
removing_retention_record="$(state_root)/worktrees/$removing_retention_record_id.json"
jq -cn \
  --arg common_dir "$removing_retention_common" \
  --arg git_dir "$removing_retention_git_dir" \
  --arg path "$removing_retention_path" \
  --arg quarantine_path "$removing_retention_quarantine" \
  '{version: 1, session_id: "removing-retention-session",
    common_dir: $common_dir, git_dir: $git_dir, path: $path,
    quarantine_path: $quarantine_path,
    initial_head: "0000000000000000000000000000000000000000",
    status: "removing", last_reason: "removing", updated_at: 0,
    worktree_device: "0", worktree_inode: "0"}' \
  >"$removing_retention_record"
chmod 600 "$removing_retention_record"
"$SEVEN_DAY_RESOURCE" reap
test -f "$removing_retention_record"
test "$(jq -r '.status' "$removing_retention_record")" = removing

# Permission denial, a disappearing magic link, and a stable broken link all
# make process-reference inspection inconclusive and therefore preserve.
assert_proc_failure_preserved proc-permission-denied denied
assert_proc_failure_preserved proc-reference-disappearing disappearing
assert_proc_failure_preserved proc-reference-broken broken
assert_proc_owner_failure_preserved
assert_foreign_proc_failure_ignored

new_case reap-linear-jq
linear_session_count=8
linear_state_root=$(state_root)
linear_owner_start_time=$(proc_start_time $$)
linear_boot_id=$(</proc/sys/kernel/random/boot_id)
linear_updated_at=$(date +%s)
mkdir -p "$linear_state_root/sessions" "$linear_state_root/worktrees" \
  "$linear_state_root/locks"
chmod 700 "$linear_state_root" "$linear_state_root/sessions" \
  "$linear_state_root/worktrees" "$linear_state_root/locks"
for index in $(seq 1 "$linear_session_count"); do
  linear_session_id="linear-session-$index"
  jq -cn \
    --arg session_id "$linear_session_id" \
    --arg boot_id "$linear_boot_id" \
    --arg owner_start_time "$linear_owner_start_time" \
    --argjson owner_pid "$$" \
    --argjson updated_at "$linear_updated_at" \
    '{version: 1, session_id: $session_id, client: "fixture-client",
      owner_pid: $owner_pid, owner_start_time: $owner_start_time,
      boot_id: $boot_id, status: "ended", reason: "cleanup",
      updated_at: $updated_at}' \
    >"$linear_state_root/sessions/$linear_session_id.json"
  chmod 600 "$linear_state_root/sessions/$linear_session_id.json"
  : >"$linear_state_root/locks/$linear_session_id.lock"
  : >"$linear_state_root/locks/linear-orphan-$index.lock"
  chmod 600 "$linear_state_root/locks/$linear_session_id.lock" \
    "$linear_state_root/locks/linear-orphan-$index.lock"
done
linear_jq_counter="$HOME/jq-count"
printf '0\n' >"$linear_jq_counter"
DOTFILES_AGENT_TEST_JQ_COUNTER="$linear_jq_counter" "$COUNTING_RESOURCE" reap
linear_jq_calls=$(<"$linear_jq_counter")
linear_jq_bound=$((linear_session_count * 12))
if ((linear_jq_calls == 0)); then
  echo 'reap did not use the counting jq wrapper' >&2
  exit 1
fi
if ((linear_jq_calls > linear_jq_bound)); then
  echo "reap exceeded linear jq bound: calls=$linear_jq_calls bound=$linear_jq_bound" >&2
  exit 1
fi

# Terminal ledgers use their recorded update time for bounded retention. Ledger
# expiry never authorizes deleting a worktree.
new_case terminal-retention-crash
begin_session crash-retention-session
crash_retention_session="$(state_root)/sessions/crash-retention-session.json"
crash_retention_lock="$(state_root)/locks/crash-retention-session.lock"
"$RESOURCE" cleanup-session crash-retention-session
jq '.updated_at = 0' "$crash_retention_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$crash_retention_session"
set +e
DOTFILES_AGENT_TEST_PRUNE_SESSION=crash-retention-session \
  DOTFILES_AGENT_TEST_PRUNE_MODE=crash-after \
  DOTFILES_AGENT_TEST_PRUNE_MARKER="$HOME/prune-crashed" \
  "$CONTROLLED_PRUNE_RESOURCE" reap
crash_retention_status=$?
set -e
test "$crash_retention_status" -eq 137
test -e "$HOME/prune-crashed"
if [ -e "$crash_retention_lock" ] || [ -L "$crash_retention_lock" ]; then
  echo 'terminal prune crash left an orphan session lock' >&2
  exit 1
fi

new_case terminal-retention-failure
begin_session failure-retention-session
failure_retention_session="$(state_root)/sessions/failure-retention-session.json"
failure_retention_lock="$(state_root)/locks/failure-retention-session.lock"
"$RESOURCE" cleanup-session failure-retention-session
jq '.updated_at = 0' "$failure_retention_session" >"$HOME/session.tmp"
chmod 600 "$HOME/session.tmp"
mv -T "$HOME/session.tmp" "$failure_retention_session"
if DOTFILES_AGENT_TEST_PRUNE_SESSION=failure-retention-session \
  DOTFILES_AGENT_TEST_PRUNE_MODE=fail-once \
  DOTFILES_AGENT_TEST_PRUNE_MARKER="$HOME/prune-failed" \
  "$CONTROLLED_PRUNE_RESOURCE" reap; then
  echo 'terminal ledger deletion failure unexpectedly succeeded' >&2
  exit 1
fi
test -f "$failure_retention_session"
if [ -e "$failure_retention_lock" ] || [ -L "$failure_retention_lock" ]; then
  echo 'terminal ledger deletion failure kept the old session lock' >&2
  exit 1
fi
"$RESOURCE" reap
test ! -e "$failure_retention_session"
test ! -e "$failure_retention_lock"

new_case terminal-retention-orphan-lock
orphan_retention_lock="$(state_root)/locks/orphan-retention-session.lock"
mkdir -p "$(state_root)/locks"
: >"$orphan_retention_lock"
chmod 600 "$orphan_retention_lock"
exec 8<>"$orphan_retention_lock"
flock -x 8
"$RESOURCE" reap &
orphan_reap_pid=$!
set +e
timeout 0.5 tail --pid="$orphan_reap_pid" -f /dev/null
orphan_wait_status=$?
set -e
test "$orphan_wait_status" -eq 124
test -f "$orphan_retention_lock"
flock -u 8
exec 8>&-
wait "$orphan_reap_pid"
if [ -e "$orphan_retention_lock" ] || [ -L "$orphan_retention_lock" ]; then
  echo 'orphan session lock survived migration pruning' >&2
  exit 1
fi

new_case terminal-retention-orphan-begin-race
orphan_begin_session=orphan-begin-session
orphan_begin_lock="$(state_root)/locks/$orphan_begin_session.lock"
orphan_begin_ledger="$(state_root)/sessions/$orphan_begin_session.json"
orphan_begin_ready=$HOME/orphan-begin-ready
orphan_begin_release=$HOME/orphan-begin-release
mkdir -p "$(state_root)/locks"
: >"$orphan_begin_lock"
chmod 600 "$orphan_begin_lock"
DOTFILES_AGENT_TEST_PRUNE_LOCK="$orphan_begin_lock" \
  DOTFILES_AGENT_TEST_PRUNE_MODE=pause-lock-before \
  DOTFILES_AGENT_TEST_PRUNE_MARKER="$orphan_begin_ready" \
  DOTFILES_AGENT_TEST_PRUNE_RELEASE="$orphan_begin_release" \
  "$CONTROLLED_PRUNE_RESOURCE" reap &
orphan_begin_reap_pid=$!
wait_for_file "$orphan_begin_ready"
test -f "$orphan_begin_lock"
(begin_session "$orphan_begin_session") &
orphan_begin_pid=$!
set +e
timeout 0.5 tail --pid="$orphan_begin_pid" -f /dev/null
orphan_begin_wait_status=$?
set -e
test "$orphan_begin_wait_status" -eq 124
test ! -e "$orphan_begin_ledger"
: >"$orphan_begin_release"
wait "$orphan_begin_reap_pid"
wait "$orphan_begin_pid"
test -f "$orphan_begin_lock"
test "$(jq -r '.status' "$orphan_begin_ledger")" = active

new_case terminal-retention
retention_repo="$HOME/repo"
retention_path="$HOME/removed"
create_repo "$retention_repo"
begin_session retention-session
add_managed_worktree "$retention_repo" "$retention_path"
retention_record=$(record_for_path "$retention_path")
retention_session="$(state_root)/sessions/retention-session.json"
retention_lock="$(state_root)/locks/retention-session.lock"
"$RESOURCE" cleanup-session retention-session
test ! -e "$retention_path"
test -f "$retention_lock"
for ledger in "$retention_record" "$retention_session"; do
  jq '.updated_at = 0' "$ledger" >"$HOME/ledger.tmp"
  chmod 600 "$HOME/ledger.tmp"
  mv -T "$HOME/ledger.tmp" "$ledger"
done
exec 8<>"$retention_lock"
flock -x 8
"$RESOURCE" reap &
retention_reap_pid=$!
set +e
timeout 0.5 tail --pid="$retention_reap_pid" -f /dev/null
retention_wait_status=$?
set -e
test "$retention_wait_status" -eq 124
test -f "$retention_record"
test -f "$retention_session"
test -f "$retention_lock"
flock -u 8
exec 8>&-
wait "$retention_reap_pid"
test ! -e "$retention_record"
test ! -e "$retention_session"
if [ -e "$retention_lock" ] || [ -L "$retention_lock" ]; then
  echo 'terminal session lock survived ledger retention pruning' >&2
  exit 1
fi

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
