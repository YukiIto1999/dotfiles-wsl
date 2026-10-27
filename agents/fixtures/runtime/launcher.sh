#!/usr/bin/env bash
# launcher が起動した client と supervisor の実 process、台帳、GC root、scope の観測から、
# 起動前の拒否、保護と実行の一致、終了の順序、取消の区別、台帳の待ち上限を読む。
# systemd-run、systemctl、nix-store は sandbox にないため、その呼び出しを記録して同じ process で動く fake に替える。
set -euo pipefail

fixture=$PWD/launcher-fixture
home=$fixture/home
repo=$fixture/repo
cache=$home/.cache/dotfiles-wsl
scripts=$fixture/scripts
mkdir -p "$home/.local/bin" "$fixture/profile/bin" "$scripts" "$repo"

fail() {
  echo "$*" >&2
  exit 1
}

wait_for_file() {
  local path=$1
  for _ in $(seq 1 500); do
    [ -e "$path" ] && return 0
    sleep 0.02
  done
  fail "timed out waiting for $path"
}

now_ms() {
  echo $(($(date +%s%N) / 1000000))
}

assert_dead() {
  local pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      fail "process $pid is still alive"
    fi
  done
}

assert_alive() {
  local pid
  for pid in "$@"; do
    kill -0 "$pid" 2>/dev/null || fail "process $pid ended"
  done
}

sessions_empty() {
  test -z "$(ls -A "$cache/sessions")"
}

read_capture() {
  cat "$capture/$1"
}

reset_capture() {
  rm -rf "$fixture/capture"
  mkdir -p "$fixture/capture"
  capture=$fixture/capture
  export CAPTURE=$capture
  : > "$NIX_STORE_LOG"
  : > "$SYSTEMCTL_LOG"
  rm -f "$SYSTEMD_RUN_CAPTURE" "$SYSTEMD_RUN_CAPTURE.pid"
}

# A store-resident client and a copy outside the store.
cp "$FAKE_AGENT" "$home/.local/bin/fake-agent-local"
chmod 0755 "$home/.local/bin/fake-agent-local"
local_agent=$home/.local/bin/fake-agent-local
profile_agent=$fixture/profile/bin/fake-agent
ln -sfn "$FAKE_AGENT" "$profile_agent"

cat > "$scripts/leftovers.sh" <<'SCRIPT'
sleep 300 &
echo $! > "$CAPTURE/child-a.pid"
sleep 300 &
echo $! > "$CAPTURE/child-b.pid"
( setsid "$BASH" "$SCRIPTS/grandchild.sh" & )
for _ in $(seq 1 500); do
  [ -s "$CAPTURE/grandchild.pid" ] && break
  sleep 0.02
done
SCRIPT
# The grandchild takes a while to stop and records what still exists when it is told to.
cat > "$scripts/grandchild.sh" <<'SCRIPT'
trap 'if [ -d "$TMPDIR" ] && [ -d "${DOTFILES_AGENT_WORKTREE_RECORD%/worktrees}/roots" ]; then echo yes; else echo no; fi > "$CAPTURE/grandchild-saw-resources"; sleep 0.5; exit 0' TERM
echo $$ > "$CAPTURE/grandchild.pid"
while :; do
  sleep 0.05
done
SCRIPT
# Members of the scope that the supervisor does not own: the scope's cgroup is not empty after it returns.
cat > "$scripts/stray-scope-member.sh" <<'SCRIPT'
unit=dotfiles-agent-${DOTFILES_AGENT_SESSION_ID#"$DOTFILES_AGENT_PROJECT_ID".}.scope
scope=$DOTFILES_AGENT_CGROUP_ROOT/user.slice/user-$(id -u).slice/user@$(id -u).service/agents.slice/$unit
mkdir -p "$scope"
printf '%s\n' "$$" > "$scope/cgroup.procs"
SCRIPT

git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -qm initial
cd "$repo"

export HOME=$home
export NIX_STORE_LOG=$fixture/nix-store.log
export SYSTEMCTL_LOG=$fixture/systemctl.log
export SYSTEMD_RUN_CAPTURE=$fixture/systemd-run
export DOTFILES_AGENT_CGROUP_ROOT=$fixture/cgroup
export SCRIPTS=$scripts
unset CARGO_HOME CARGO_TARGET_DIR CARGO_BUILD_BUILD_DIR XDG_CACHE_HOME TMPDIR
# GC が作る前の cache root が他の mode でも、launcher は自分の directory を 0700 に締める。
mkdir -p "$cache/sessions" "$cache/cargo-build"
chmod 0777 "$cache" "$cache/sessions" "$cache/cargo-build"
reset_capture

# ---- A normal session: registration, environment, scope command, exit status, and release order.
HOLD_READY=$fixture/hold.ready HOLD_RELEASE=$fixture/hold.release FAKE_STATUS=23 \
  "$LAUNCHER" fixture-client "$local_agent" 'space arg' $'line\narg' '' 'ユニコード' -- --protect &
launcher_pid=$!
wait_for_file "$fixture/hold.ready"
session_dir=$(read_capture session-dir)
test -d "$session_dir"
owner_start_time=$(awk '{print $22}' "/proc/$launcher_pid/stat")
test "$(jq -r '.owner_pid' "$capture/metadata.json")" = "$launcher_pid"
test "$(jq -r '.owner_start_time' "$capture/metadata.json")" = "$owner_start_time"
test "$(jq -r '.client' "$capture/metadata.json")" = fixture-client
test "$(jq -r '.project_id' "$capture/metadata.json")" = "$(read_capture project-id)"
test "$(jq -r '.session_id' "$capture/metadata.json")" = "$(read_capture session-id)"
test "$(jq -r '.boot_id' "$capture/metadata.json")" = "$(cat /proc/sys/kernel/random/boot_id)"
test "$(jq -r '.owner_pid | type' "$capture/metadata.json")" = number
test "$(jq -r '.owner_start_time | type' "$capture/metadata.json")" = string
: > "$fixture/hold.release"
status=0
wait "$launcher_pid" || status=$?
test "$status" -eq 23
rm -f "$fixture/hold.ready" "$fixture/hold.release"

test "$(read_capture client)" = fixture-client
test "$(read_capture env-TMPDIR)" = "set:$session_dir/tmp"
for name in CARGO_HOME CARGO_BUILD_BUILD_DIR CARGO_TARGET_DIR XDG_CACHE_HOME; do
  test "$(read_capture "env-$name")" = unset || fail "the lifecycle changed $name"
done
test "$(read_capture git-command)" = "$AGENT_SHIM_DIR/bin/git"
test "$(read_capture argv0)" = "$local_agent"
mapfile -d '' -t argv < "$capture/argv"
test "${#argv[@]}" -eq 6
test "${argv[0]}" = 'space arg'
test "${argv[1]}" = $'line\narg'
test -z "${argv[2]}"
test "${argv[3]}" = 'ユニコード'
test "${argv[4]}" = --
test "${argv[5]}" = --protect
test "$(read_capture cwd)" = "$(realpath "$repo")"
test "$(read_capture session-mode)" = 700
test "$(read_capture tmp-mode)" = 700
test "$(read_capture metadata-mode)" = 600
test "$(read_capture lock-mode)" = 600
for directory in "$cache" "$cache/sessions" "$cache/cargo-build" "$cache/shared" \
  "$cache/shared/cargo-home" "$cache/shared/xdg-cache"; do
  test "$(stat -c %a "$directory")" = 700 || fail "$directory is not 0700"
done
test "$(stat -c %a "$cache/shared/.dotfiles-agent-cache.json")" = 600
jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$cache/shared/.dotfiles-agent-cache.json" >/dev/null
sessions_empty
test ! -e "$session_dir"

# The scope runs the supervisor under a capped slice, as the process systemd-run started.
mapfile -d '' -t launch < "$SYSTEMD_RUN_CAPTURE"
separator=0
while [ "${launch[$separator]}" != -- ]; do
  separator=$((separator + 1))
done
scope_options=("${launch[@]:0:separator}")
scope_command=("${launch[@]:separator+1}")
session_id=$(read_capture session-id)
scope_slice=
for option in "${scope_options[@]}"; do
  case $option in
    --slice=*) scope_slice=${option#--slice=} ;;
  esac
done
case " $CAPPED_SLICES " in
  *" $scope_slice "*) ;;
  *) fail "the lifecycle used a slice without a declared memory cap: $scope_slice" ;;
esac
test "$(printf '%s\n' "${scope_options[@]}" | sort)" = "$(printf '%s\n' --collect \
  --expand-environment=no --quiet --scope --user "--slice=$scope_slice" \
  "--unit=dotfiles-agent-${session_id#"$(read_capture project-id)".}.scope" | sort)"
test "${scope_command[0]}" = "$SUPERVISE"
test "${scope_command[1]}" = --term-grace
test "${scope_command[3]}" = --kill-grace
test "${scope_command[5]}" = --result
test "${scope_command[6]}" = "$session_dir/supervisor.json"
test "${scope_command[7]}" = --argv0
test "${scope_command[8]}" = "$local_agent"
test "${scope_command[9]}" = --
test "${scope_command[10]}" = "$local_agent"
test "${#scope_command[@]}" -eq 17
test "$(cat "$SYSTEMD_RUN_CAPTURE.pid")" = "$(read_capture supervisor-pid)"

# ---- A store client behind a profile link: the dependencies and the resolved executable are rooted
# before the client starts, and the rooted executable is the one that runs.
reset_capture
"$LAUNCHER" --protect "$DEPENDENCY_A" --protect "$DEPENDENCY_B" fixture-client "$profile_agent" one
test "$(read_capture argv0)" = "$FAKE_AGENT"
store_object() {
  local path=$1 rest
  rest=${path#/nix/store/}
  echo "/nix/store/${rest%%/*}"
}
launcher_object=$(store_object "$(realpath "$LAUNCHER")")
printf '%s\n' \
  "${launcher_object##*/} $launcher_object" \
  "${DEPENDENCY_A##*/} $DEPENDENCY_A" \
  "${DEPENDENCY_B##*/} $DEPENDENCY_B" \
  "${FAKE_AGENT##*/} $FAKE_AGENT" | sort > "$fixture/expected-roots"
diff "$fixture/expected-roots" "$capture/roots"
test "$(grep -c -- '--indirect' "$NIX_STORE_LOG")" -eq 4
test "$(grep -c -- '--option substitute false' "$NIX_STORE_LOG")" -eq 4
sessions_empty

# A profile update that lands after the executable was resolved does not change what runs.
reset_capture
FAKE_PROFILE_SWITCH=$profile_agent FAKE_PROFILE_SWITCH_TO=$FAKE_AGENT_NEXT \
  FAKE_PROFILE_SWITCH_OBJECT=-fake-agent \
  "$LAUNCHER" fixture-client "$profile_agent"
test "$(readlink "$profile_agent")" = "$FAKE_AGENT_NEXT"
test "$(read_capture argv0)" = "$FAKE_AGENT" || fail "the executable ran from a profile that moved: $(read_capture argv0)"
ln -sfn "$FAKE_AGENT" "$profile_agent"

# A multi-call binary reached through a symlink still starts under the name it was published as, while the rooted file is the one that runs.
ln -sfn "$DEPENDENCY_A/bin/echo" "$fixture/profile/bin/echo"
reset_capture
test "$("$LAUNCHER" fixture-client "$fixture/profile/bin/echo" 'hello world')" = 'hello world'
test "$(grep -c -- '--indirect' "$NIX_STORE_LOG")" -eq 2

# A dependency that cannot be protected stops the start: no client, no scope, and the roots already taken go with the session.
reset_capture
status=0
FAKE_NIX_STORE_FAIL=${DEPENDENCY_B##*/} \
  "$LAUNCHER" --protect "$DEPENDENCY_A" --protect "$DEPENDENCY_B" fixture-client "$profile_agent" 2>"$fixture/stderr" || status=$?
test "$status" -ne 0
test ! -e "$capture/agent-pid"
test ! -e "$SYSTEMD_RUN_CAPTURE"
grep -Fq "${DEPENDENCY_A##*/}" "$NIX_STORE_LOG"
grep -Fq 'cannot protect' "$fixture/stderr"
sessions_empty
status=0
FAKE_NIX_STORE_FAIL=${FAKE_AGENT##*/} \
  "$LAUNCHER" fixture-client "$profile_agent" 2>/dev/null || status=$?
test "$status" -ne 0
test ! -e "$capture/agent-pid"
sessions_empty
status=0
"$LAUNCHER" --protect /not/a/store/path fixture-client "$profile_agent" 2>/dev/null || status=$?
test "$status" -ne 0
test ! -e "$capture/agent-pid"

# Inputs that cannot start a client are refused before any ledger is written.
for bad_client in '' -x 'a/b' 'a b'; do
  status=0
  "$LAUNCHER" "$bad_client" "$local_agent" 2>/dev/null || status=$?
  test "$status" -ne 0
done
status=0
"$LAUNCHER" fixture-client relative/agent 2>/dev/null || status=$?
test "$status" -ne 0
status=0
"$LAUNCHER" fixture-client "$fixture/missing-agent" 2>/dev/null || status=$?
test "$status" -ne 0
status=0
"$LAUNCHER" fixture-client "$fixture" 2>/dev/null || status=$?
test "$status" -ne 0
status=0
"$LAUNCHER" fixture-client 2>/dev/null || status=$?
test "$status" -ne 0
test ! -e "$capture/agent-pid"
sessions_empty

# ---- A scope that cannot be created leaves the client unstarted and nothing behind.
reset_capture
status=0
SYSTEMD_RUN_FAIL=1 "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr" || status=$?
test "$status" -ne 0
test ! -e "$capture/agent-pid"
grep -Fq 'the client was not started' "$fixture/stderr"
sessions_empty

# ---- TMPDIR belongs to the caller whenever it is given.
reset_capture
env -u TMPDIR "$LAUNCHER" fixture-client "$local_agent"
test "$(read_capture env-TMPDIR)" = "set:$(read_capture session-dir)/tmp"
grep -Fxq tmp "$capture/session-listing"
env 'TMPDIR=' "$LAUNCHER" fixture-client "$local_agent"
test "$(read_capture env-TMPDIR)" = 'set:'
if grep -Fxq tmp "$capture/session-listing"; then fail 'a managed scratch was created for an explicit empty TMPDIR'; fi
env TMPDIR=/explicit/tmp "$LAUNCHER" fixture-client "$local_agent"
test "$(read_capture env-TMPDIR)" = 'set:/explicit/tmp'
if grep -Fxq tmp "$capture/session-listing"; then fail 'a managed scratch was created for an explicit TMPDIR'; fi
# The scratch that an enclosing session assigned is not a caller's choice.
env TMPDIR="$cache/sessions/outer.session/tmp" DOTFILES_AGENT_SESSION_ID=outer.session \
  "$LAUNCHER" fixture-client "$local_agent"
test "$(read_capture env-TMPDIR)" = "set:$(read_capture session-dir)/tmp"
test "$(read_capture session-dir)" != "$cache/sessions/outer.session"
sessions_empty

# ---- The caller's cache variables reach the client untouched; the lifecycle chooses none of them.
reset_capture
CARGO_HOME='' XDG_CACHE_HOME=/explicit-xdg CARGO_TARGET_DIR=/explicit-target \
  "$LAUNCHER" fixture-client "$local_agent"
test "$(read_capture env-CARGO_HOME)" = 'set:'
test "$(read_capture env-XDG_CACHE_HOME)" = 'set:/explicit-xdg'
test "$(read_capture env-CARGO_TARGET_DIR)" = 'set:/explicit-target'
test "$(read_capture env-CARGO_BUILD_BUILD_DIR)" = unset

# ---- A signal that ends the client reaches the caller as its status.
reset_capture
status=0
FAKE_SIGNAL=TERM "$LAUNCHER" fixture-client "$local_agent" || status=$?
test "$status" -eq 143
sessions_empty

# ---- Two children and a delayed grandchild outlive a client that exits normally. The launcher returns
# only after all of them ended, and the scratch and roots were still there while they stopped.
reset_capture
status=0
AGENT_ACTION="\"$BASH\" \"$scripts/leftovers.sh\"" FAKE_STATUS=5 \
  "$LAUNCHER" fixture-client "$profile_agent" || status=$?
test "$status" -eq 5
assert_dead "$(read_capture child-a.pid)" "$(read_capture child-b.pid)" "$(read_capture grandchild.pid)"
test "$(read_capture grandchild-saw-resources)" = yes
sessions_empty

# ---- Session cancellation ends one session's whole tree and leaves another session untouched.
reset_capture
capture_b=$fixture/capture-b
mkdir -p "$capture_b"
CAPTURE=$capture_b HOLD_READY=$fixture/b.ready HOLD_RELEASE=$fixture/b.release \
  "$LAUNCHER" client-b "$local_agent" &
launcher_b=$!
wait_for_file "$fixture/b.ready"
capture_a=$fixture/capture-a
mkdir -p "$capture_a"
CAPTURE=$capture_a HOLD_READY=$fixture/a.ready HOLD_RELEASE=$fixture/a.release \
  AGENT_ACTION="\"$BASH\" \"$scripts/leftovers.sh\"" \
  "$LAUNCHER" client-a "$local_agent" &
launcher_a=$!
wait_for_file "$fixture/a.ready"
session_a=$(cat "$capture_a/session-dir")
session_b=$(cat "$capture_b/session-dir")
test "$session_a" != "$session_b"
kill -TERM "$launcher_a"
status=0
wait "$launcher_a" || status=$?
test "$status" -eq 143
assert_dead "$(cat "$capture_a/child-a.pid")" "$(cat "$capture_a/child-b.pid")" \
  "$(cat "$capture_a/grandchild.pid")" "$(cat "$capture_a/agent-pid")" "$launcher_a"
test ! -e "$session_a"
assert_alive "$launcher_b" "$(cat "$capture_b/agent-pid")"
test -d "$session_b"
test -f "$session_b/metadata.json"
: > "$fixture/b.release"
status=0
wait "$launcher_b" || status=$?
test "$status" -eq 0
test ! -e "$session_b"

# ---- An operation-level cancel (SIGINT, SIGQUIT) is the client's input, not the end of the session.
reset_capture
HOLD_READY=$fixture/c.ready HOLD_RELEASE=$fixture/c.release FAKE_STATUS=4 \
  "$LAUNCHER" fixture-client "$local_agent" &
launcher_c=$!
wait_for_file "$fixture/c.ready"
session_c=$(read_capture session-dir)
kill -INT "$launcher_c"
kill -QUIT "$launcher_c"
sleep 0.5
assert_alive "$launcher_c" "$(read_capture agent-pid)"
test -f "$session_c/metadata.json"
: > "$fixture/c.release"
status=0
wait "$launcher_c" || status=$?
test "$status" -eq 4
sessions_empty

# ---- The stalled reaper lock delays a start by at most five seconds and then refuses it.
reset_capture
exec 9<>"$cache/gc.lock"
flock -x 9
started=$(now_ms)
status=0
"$LAUNCHER" fixture-client "$local_agent" 9>&- 2>"$fixture/stderr" || status=$?
elapsed=$(($(now_ms) - started))
test "$status" -ne 0
test "$elapsed" -ge 4500 || fail "refused before the ledger wait ended: ${elapsed}ms"
test "$elapsed" -lt 9000 || fail "the reaper lock delayed the start by ${elapsed}ms"
test ! -e "$capture/agent-pid"
grep -Fq 'gc.lock was not released' "$fixture/stderr"
sessions_empty
# A lock released inside the wait lets the start through.
started=$(now_ms)
"$LAUNCHER" fixture-client "$local_agent" 9>&- &
launcher_pid=$!
sleep 1
flock -u 9
status=0
wait "$launcher_pid" || status=$?
elapsed=$(($(now_ms) - started))
exec 9>&-
test "$status" -eq 0
test "$elapsed" -ge 1000
test "$elapsed" -lt 5500
test -e "$capture/agent-pid"
sessions_empty

# ---- The end of a session never waits for the reaper lock, and the client never holds it.
reset_capture
HOLD_READY=$fixture/d.ready HOLD_RELEASE=$fixture/d.release "$LAUNCHER" fixture-client "$local_agent" &
launcher_pid=$!
wait_for_file "$fixture/d.ready"
for descriptor in "/proc/$(read_capture agent-pid)/fd"/*; do
  if [ "$(readlink "$descriptor")" = "$cache/gc.lock" ]; then
    fail 'the client inherited the gc.lock descriptor'
  fi
done
exec 9<>"$cache/gc.lock"
flock -x 9
: > "$fixture/d.release"
status=0
timeout 10 tail --pid="$launcher_pid" -f /dev/null || status=$?
flock -u 9
exec 9>&-
test "$status" -eq 0 || fail "the launcher waited for gc.lock at exit: status $status"
wait "$launcher_pid"
sessions_empty

# ---- A stalled ledger write delays a start by at most five seconds, takes no lock with it, and refuses it.
reset_capture
control=$fixture/stall-registration
printf 'mv before */metadata.json\n' > "$control"
rm -f "$control.ready" "$control.release"
started=$(now_ms)
status=0
DOTFILES_AGENT_TEST_STALL=$control "$STALLING_LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr" || status=$?
elapsed=$(($(now_ms) - started))
test "$status" -ne 0
test -e "$control.ready"
test "$elapsed" -ge 4500
test "$elapsed" -lt 9000 || fail "the ledger write delayed the start by ${elapsed}ms"
test ! -e "$capture/agent-pid"
grep -Fq 'did not accept the session' "$fixture/stderr"
flock -n -x "$cache/gc.lock" true || fail 'a stalled ledger write kept the reaper lock'
: > "$control.release"
sleep 0.3

# ---- A stalled release delays the end by at most five seconds, keeps the resources for the reaper, and
# does not turn the client's success into success.
reset_capture
control=$fixture/stall-release
printf 'rm before */sessions/*\n' > "$control"
rm -f "$control.ready" "$control.release"
started=$(now_ms)
status=0
DOTFILES_AGENT_TEST_STALL=$control "$STALLING_LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr" || status=$?
elapsed=$(($(now_ms) - started))
test "$status" -eq 70
test "$elapsed" -ge 4500
test "$elapsed" -lt 9000 || fail "the release delayed the end by ${elapsed}ms"
session_stalled=$(read_capture session-dir)
test -d "$session_stalled"
test -f "$session_stalled/metadata.json"
grep -Fq 'cannot release the session resources' "$fixture/stderr"
: > "$control.release"
for _ in $(seq 1 100); do
  [ -e "$session_stalled" ] || break
  sleep 0.05
done
# The orphaned release may have been cut off with the bounded subshell; either way nothing is left for the reaper to reclaim.
rm -rf "$session_stalled"
test ! -e "$session_stalled"
sessions_empty

# ---- Members left in the scope after the supervisor returned are stopped and awaited before release.
reset_capture
rm -rf "$DOTFILES_AGENT_CGROUP_ROOT"
status=0
FAKE_SYSTEMCTL_EFFECTIVE=1 AGENT_ACTION="\"$BASH\" \"$scripts/stray-scope-member.sh\"" \
  "$LAUNCHER" fixture-client "$local_agent" || status=$?
test "$status" -eq 0
session_id=$(read_capture session-id)
project_id=$(read_capture project-id)
unit=dotfiles-agent-${session_id#"$project_id".}.scope
grep -Fxq -- "--user kill --kill-whom=all --signal=SIGKILL $unit" "$SYSTEMCTL_LOG"
sessions_empty

# A scope that stays occupied keeps the roots and scratch and fails the session, even for a client that succeeded.
reset_capture
rm -rf "$DOTFILES_AGENT_CGROUP_ROOT"
started=$(now_ms)
status=0
AGENT_ACTION="\"$BASH\" \"$scripts/stray-scope-member.sh\"" \
  "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr" || status=$?
elapsed=$(($(now_ms) - started))
test "$status" -eq 70
test "$elapsed" -ge 9000
session_stuck=$(read_capture session-dir)
test -f "$session_stuck/metadata.json"
test -d "$session_stuck/roots"
grep -Fq 'did not become empty' "$fixture/stderr"
rm -rf "$session_stuck" "$DOTFILES_AGENT_CGROUP_ROOT"

# A supervisor that dies before confirming the end keeps the resources as well.
reset_capture
rm -rf "$DOTFILES_AGENT_CGROUP_ROOT"
HOLD_READY=$fixture/e.ready HOLD_RELEASE=$fixture/e.release "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr" &
launcher_pid=$!
wait_for_file "$fixture/e.ready"
session_e=$(read_capture session-dir)
kill -KILL "$(read_capture supervisor-pid)"
status=0
wait "$launcher_pid" || status=$?
test "$status" -ne 0
test -f "$session_e/metadata.json"
grep -Fq 'did not confirm' "$fixture/stderr"
: > "$fixture/e.release"
sleep 0.3
rm -rf "$session_e"

# ---- The session removes the worktrees it created while they are clean and at their initial HEAD.
worktree_repo=$fixture/worktree-repo
git init -q "$worktree_repo"
git -C "$worktree_repo" config user.name fixture
git -C "$worktree_repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$worktree_repo/tracked"
git -C "$worktree_repo" add tracked
git -C "$worktree_repo" commit -qm initial
printf 'inner/\n' >> "$worktree_repo/.git/info/exclude"
git -C "$worktree_repo" worktree add -q --detach "$fixture/preexisting"
reset_capture
cat > "$scripts/worktrees.sh" <<'SCRIPT'
set -euo pipefail
git worktree add -q --detach "$WORKTREES/clean"
git worktree add -q -b changed "$WORKTREES/changed"
git -C "$WORKTREES/changed" commit -q --allow-empty -m change
git worktree add -q --detach "$WORKTREES/untracked"
: > "$WORKTREES/untracked/new-file"
git worktree add -q --detach "$WORKTREES/modified"
printf 'modified\n' > "$WORKTREES/modified/tracked"
SCRIPT
status=0
(
  cd "$worktree_repo"
  WORKTREES=$fixture FAKE_STATUS=31 AGENT_ACTION="\"$BASH\" \"$scripts/worktrees.sh\"" \
    "$LAUNCHER" fixture-client "$local_agent"
) || status=$?
test "$status" -eq 31
test ! -e "$fixture/clean"
test -d "$fixture/changed"
test -d "$fixture/untracked"
test -d "$fixture/modified"
test -d "$fixture/preexisting"
git -C "$worktree_repo" worktree list --porcelain > "$fixture/worktree-list"
if grep -Fxq "worktree $fixture/clean" "$fixture/worktree-list"; then
  fail 'removed worktree is still registered'
fi

worktree_registered() {
  git -C "$worktree_repo" worktree list --porcelain > "$fixture/worktree-list"
  grep -Fxq "worktree $1" "$fixture/worktree-list"
}

discard_session() {
  local session=$1 path
  shift
  for path in "$@"; do
    git -C "$worktree_repo" worktree unlock "$path" 2>/dev/null || true
    git -C "$worktree_repo" worktree remove --force "$path"
  done
  rm -rf "$session"
}

cat > "$scripts/nested-worktrees.sh" <<'SCRIPT'
set -euo pipefail
git worktree add -q --detach "$TMPDIR/clean"
git worktree add -q --detach "$TMPDIR/untracked"
printf 'untracked\n' > "$TMPDIR/untracked/sentinel"
git worktree add -q --detach "$TMPDIR/modified"
printf 'modified\n' > "$TMPDIR/modified/tracked"
git worktree add -q --detach "$TMPDIR/advanced"
git -C "$TMPDIR/advanced" commit -q --allow-empty -m advanced
git worktree add -q --detach "$TMPDIR/locked"
git worktree lock "$TMPDIR/locked"
git worktree add -q --detach "$EXTERNAL"
printf 'external\n' > "$EXTERNAL/sentinel"
printf 'scratch\n' > "$TMPDIR/scratch"
SCRIPT
reset_capture
status=0
(
  cd "$worktree_repo"
  EXTERNAL=$fixture/nested-external FAKE_STATUS=33 AGENT_ACTION="\"$BASH\" \"$scripts/nested-worktrees.sh\"" \
    "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr"
) || status=$?
test "$status" -eq 33
nested_session=$(read_capture session-dir)
nested_tmp=$nested_session/tmp
grep -Fq 'Git kept worktrees inside the session' "$fixture/stderr"
test -f "$nested_session/metadata.json"
test "$(cat "$nested_tmp/scratch")" = scratch
test ! -e "$nested_tmp/clean"
if worktree_registered "$nested_tmp/clean"; then
  fail 'removed nested worktree is still registered'
fi
for name in untracked modified advanced locked; do
  test -d "$nested_tmp/$name" || fail "the session scratch lost the worktree $name"
  worktree_registered "$nested_tmp/$name" || fail "Git lost the registration of the worktree $name"
done
test "$(cat "$nested_tmp/untracked/sentinel")" = untracked
test "$(cat "$nested_tmp/modified/tracked")" = modified
test "$(git -C "$nested_tmp/advanced" log -1 --format=%s)" = advanced
test "$(cat "$nested_tmp/locked/tracked")" = tracked
test -e "$(git -C "$nested_tmp/locked" rev-parse --absolute-git-dir)/locked"
test "$(cat "$fixture/nested-external/sentinel")" = external
worktree_registered "$fixture/nested-external"
discard_session "$nested_session" "$nested_tmp/untracked" "$nested_tmp/modified" "$nested_tmp/advanced" \
  "$nested_tmp/locked" "$fixture/nested-external"
sessions_empty

cat > "$scripts/nested-clean.sh" <<'SCRIPT'
set -euo pipefail
git worktree add -q --detach "$TMPDIR/only-clean"
git worktree add -q --detach "$EXTERNAL"
printf 'external\n' > "$EXTERNAL/sentinel"
SCRIPT
reset_capture
(
  cd "$worktree_repo"
  EXTERNAL=$fixture/clean-nested-external AGENT_ACTION="\"$BASH\" \"$scripts/nested-clean.sh\"" \
    "$LAUNCHER" fixture-client "$local_agent"
)
clean_nested=$(read_capture session-dir)/tmp/only-clean
sessions_empty
if worktree_registered "$clean_nested"; then
  fail 'the removed clean nested worktree is still registered'
fi
test "$(cat "$fixture/clean-nested-external/sentinel")" = external
worktree_registered "$fixture/clean-nested-external"
git -C "$worktree_repo" worktree remove --force "$fixture/clean-nested-external"

cat > "$scripts/term-worktree.sh" <<'SCRIPT'
set -euo pipefail
git worktree add -q --detach "$TMPDIR/term-retained"
printf 'term\n' > "$TMPDIR/term-retained/sentinel"
SCRIPT
reset_capture
(
  cd "$worktree_repo"
  HOLD_READY=$fixture/term.ready HOLD_RELEASE=$fixture/term.release \
    AGENT_ACTION="\"$BASH\" \"$scripts/term-worktree.sh\"" \
    exec "$LAUNCHER" fixture-client "$local_agent"
) &
launcher_pid=$!
wait_for_file "$fixture/term.ready"
term_session=$(read_capture session-dir)
kill -TERM "$launcher_pid"
status=0
wait "$launcher_pid" || status=$?
test "$status" -eq 143
test -f "$term_session/metadata.json"
test "$(cat "$term_session/tmp/term-retained/sentinel")" = term
worktree_registered "$term_session/tmp/term-retained"
discard_session "$term_session" "$term_session/tmp/term-retained"
sessions_empty

git -C "$worktree_repo" worktree add -q --detach "$fixture/symlink-target"
cat > "$scripts/symlink-record.sh" <<'SCRIPT'
set -euo pipefail
ln -s "$TARGET" "$TMPDIR/link"
printf '%s\0%s\0' "$(realpath "$TMPDIR")/link" "$(git -C "$TARGET" rev-parse HEAD)" >> "$DOTFILES_AGENT_WORKTREE_RECORD"
SCRIPT
reset_capture
(
  cd "$worktree_repo"
  TARGET=$fixture/symlink-target AGENT_ACTION="\"$BASH\" \"$scripts/symlink-record.sh\"" \
    "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr"
)
link_session=$(read_capture session-dir)
grep -Fq 'Git kept worktrees inside the session' "$fixture/stderr"
test -L "$link_session/tmp/link"
test -d "$fixture/symlink-target"
worktree_registered "$fixture/symlink-target"
discard_session "$link_session" "$fixture/symlink-target"
sessions_empty

cat > "$scripts/enclosing-worktrees.sh" <<'SCRIPT'
set -euo pipefail
git worktree add -q --detach "$TMPDIR/outer"
git worktree add -q --detach "$TMPDIR/outer/inner"
printf 'inner\n' > "$TMPDIR/outer/inner/sentinel"
SCRIPT
reset_capture
(
  cd "$worktree_repo"
  AGENT_ACTION="\"$BASH\" \"$scripts/enclosing-worktrees.sh\"" \
    "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr"
)
enclosing_session=$(read_capture session-dir)
grep -Fq 'Git kept worktrees inside the session' "$fixture/stderr"
test "$(cat "$enclosing_session/tmp/outer/inner/sentinel")" = inner
worktree_registered "$enclosing_session/tmp/outer"
worktree_registered "$enclosing_session/tmp/outer/inner"
discard_session "$enclosing_session" "$enclosing_session/tmp/outer/inner" "$enclosing_session/tmp/outer"
sessions_empty

cat > "$scripts/bad-record.sh" <<'SCRIPT'
set -euo pipefail
record=$DOTFILES_AGENT_WORKTREE_RECORD
printf 'scratch\n' > "$TMPDIR/sentinel"
case $RECORD_SHAPE in
  truncated) printf '%s\0' /only/a/path > "$record" ;;
  relative) printf '%s\0%s\0' relative/path "$RECORD_HEAD" > "$record" ;;
  dotted) printf '%s\0%s\0' /some/../path "$RECORD_HEAD" > "$record" ;;
  badhead) printf '%s\0%s\0' /some/path not-a-commit > "$record" ;;
  symlink) ln -s "$RECORD_TARGET" "$record" ;;
esac
SCRIPT
record_head=$(git -C "$worktree_repo" rev-parse HEAD)
: > "$fixture/record-target"
for shape in truncated relative dotted badhead symlink; do
  reset_capture
  status=0
  (
    cd "$worktree_repo"
    RECORD_SHAPE=$shape RECORD_HEAD=$record_head RECORD_TARGET=$fixture/record-target \
      AGENT_ACTION="\"$BASH\" \"$scripts/bad-record.sh\"" \
      "$LAUNCHER" fixture-client "$local_agent" 2>"$fixture/stderr"
  ) || status=$?
  test "$status" -eq 70 || fail "a $shape worktree record ended the session with status $status"
  bad_session=$(read_capture session-dir)
  test "$(cat "$bad_session/tmp/sentinel")" = scratch || fail "a $shape worktree record lost the session scratch"
  grep -Fq 'cannot be verified' "$fixture/stderr"
  rm -rf "$bad_session"
done
sessions_empty

# ---- A linked worktree belongs to the project of its main checkout.
git -C "$repo" worktree add -qb linked "$fixture/linked"
mkdir -p "$fixture/outside"
declare -A checkout_project_ids=()
for checkout in "$repo" "$fixture/linked" "$fixture/outside"; do
  reset_capture
  (cd "$checkout" && "$LAUNCHER" fixture-client "$local_agent")
  checkout_project_ids[$checkout]=$(read_capture project-id)
done
test "${checkout_project_ids[$fixture/linked]}" = "${checkout_project_ids[$repo]}"
test "${checkout_project_ids[$fixture/outside]}" != "${checkout_project_ids[$repo]}"
test "${#checkout_project_ids[$fixture/outside]}" -eq 64

# ---- A cache root that is not the launcher's own directory stays, and the client does not start.
expect_cache_refusal() {
  local bad_home=$1 status=0
  reset_capture
  HOME=$bad_home "$LAUNCHER" fixture-client "$local_agent" 2>/dev/null || status=$?
  test "$status" -eq 70
  test ! -e "$capture/agent-pid"
}

symlink_build_home=$fixture/symlink-build-home
mkdir -p "$symlink_build_home/.cache/dotfiles-wsl" "$fixture/symlink-build-target"
printf 'kept\n' > "$fixture/symlink-build-target/payload"
ln -s "$fixture/symlink-build-target" "$symlink_build_home/.cache/dotfiles-wsl/cargo-build"
expect_cache_refusal "$symlink_build_home"
test -L "$symlink_build_home/.cache/dotfiles-wsl/cargo-build"
test "$(cat "$fixture/symlink-build-target/payload")" = kept

symlink_home=$fixture/symlink-home
mkdir -p "$symlink_home/.cache/dotfiles-wsl/sessions"
ln -s "$repo" "$symlink_home/.cache/dotfiles-wsl/shared"
expect_cache_refusal "$symlink_home"

wrong_type_home=$fixture/wrong-type-home
mkdir -p "$wrong_type_home/.cache/dotfiles-wsl/sessions"
printf 'not a directory\n' > "$wrong_type_home/.cache/dotfiles-wsl/shared"
expect_cache_refusal "$wrong_type_home"

malformed_home=$fixture/malformed-home
mkdir -p "$malformed_home/.cache/dotfiles-wsl/sessions" \
  "$malformed_home/.cache/dotfiles-wsl/shared/cargo-home" \
  "$malformed_home/.cache/dotfiles-wsl/shared/xdg-cache"
printf '{}\n' > "$malformed_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"
expect_cache_refusal "$malformed_home"
