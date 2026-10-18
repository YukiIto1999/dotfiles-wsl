#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/supervise-fixture
mkdir -p "$fixture/cwd with space"
cd "$fixture"

fail() {
  echo "$1" >&2
  exit 1
}

wait_for_file() {
  local path=$1
  for _ in $(seq 1 400); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $path"
}

now_ms() {
  echo $(($(date +%s%N) / 1000000))
}

# A zombie that nobody collected has ended; only a process that still runs counts as alive.
alive() {
  local stat state
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  state=${stat##*) }
  [ "${state%% *}" != Z ]
}

assert_dead() {
  local pid
  for pid in "$@"; do
    if alive "$pid"; then
      fail "process $pid is still alive after the supervisor returned"
    fi
  done
}

result_field() {
  jq -r "$2" "$1"
}

mkdir -p out
cat > client-argv.sh <<'SCRIPT'
printf '%s\0' "$@" > "$OUT/argv"
pwd -P > "$OUT/cwd"
cat > "$OUT/stdin"
exit 23
SCRIPT

(
  cd "cwd with space"
  # A background command of a non-interactive shell starts with SIGINT and SIGQUIT ignored;
  # the supervisor must not pass that on to the command.
  printf 'piped input' | OUT=$fixture/out "$SUPERVISE" --result "$fixture/result-argv.json" -- \
    "$BASH" "$fixture/client-argv.sh" '' 'space arg' $'new\nline' 'ユニコード' --term-grace 1 -- &
  wait $!
) && status=0 || status=$?
test "$status" -eq 23
mapfile -d '' -t argv < out/argv
test "${#argv[@]}" -eq 7
test -z "${argv[0]}"
test "${argv[1]}" = 'space arg'
test "${argv[2]}" = $'new\nline'
test "${argv[3]}" = 'ユニコード'
test "${argv[4]}" = --term-grace
test "${argv[5]}" = 1
test "${argv[6]}" = --
test "$(cat out/cwd)" = "$(realpath "$fixture/cwd with space")"
test "$(cat out/stdin)" = 'piped input'
test "$(result_field result-argv.json .phase)" = finished
test "$(result_field result-argv.json .client_status)" = 23
test "$(result_field result-argv.json .drained)" = true

status=0
"$SUPERVISE" -- "$BASH" -c 'kill -PIPE "$$"; exit 99' || status=$?
test "$status" -eq 141

# The command runs once, and a command that cannot start leaves no result of a started command.
status=0
"$SUPERVISE" --result "$fixture/result-missing.json" -- "$fixture/does-not-exist" 2>/dev/null || status=$?
test "$status" -eq 127
test "$(result_field result-missing.json .spawned)" = false
status=0
"$SUPERVISE" -- relative-command 2>/dev/null || status=$?
test "$status" -eq 2

# Two children and a grandchild outlive a client that exits normally. The supervisor returns only
# after the kernel shows none of them left, and keeps the client's own status.
cat > client-leftovers.sh <<'SCRIPT'
sleep 300 &
echo $! > child-a.pid
sleep 300 &
echo $! > child-b.pid
( setsid sleep 300 & echo $! > grandchild.pid )
exit "${CLIENT_STATUS:-0}"
SCRIPT
for client_status in 0 9; do
  rm -f child-a.pid child-b.pid grandchild.pid
  status=0
  CLIENT_STATUS=$client_status "$SUPERVISE" --result "$fixture/result-leftovers.json" -- \
    "$BASH" "$fixture/client-leftovers.sh" || status=$?
  test "$status" -eq "$client_status"
  assert_dead "$(cat child-a.pid)" "$(cat child-b.pid)" "$(cat grandchild.pid)"
  test "$(result_field result-leftovers.json .drained)" = true
  test "$(result_field result-leftovers.json .client_status)" = "$client_status"
done

# A process that needs time to stop is awaited until it is really gone, not until a deadline passes.
cat > client-slow-stop.sh <<'SCRIPT'
( setsid "$BASH" -c 'trap "sleep 1; exit 0" TERM; echo $$ > slow.pid; while :; do sleep 0.05; done' & )
for _ in $(seq 1 400); do [ -s slow.pid ] && break; sleep 0.05; done
exit 0
SCRIPT
rm -f slow.pid
started=$(now_ms)
"$SUPERVISE" --term-grace 20 -- "$BASH" "$fixture/client-slow-stop.sh"
elapsed=$(($(now_ms) - started))
assert_dead "$(cat slow.pid)"
test "$elapsed" -ge 1000 || fail "supervisor returned before the slow process stopped: ${elapsed}ms"
test "$elapsed" -lt 15000 || fail "supervisor waited for the grace period instead of the process: ${elapsed}ms"

# A process that ignores SIGTERM gets the whole grace period first and is then killed and confirmed gone.
cat > client-stubborn.sh <<'SCRIPT'
( setsid "$BASH" -c 'trap "" TERM; echo $$ > stubborn.pid; while :; do sleep 0.05; done' & )
for _ in $(seq 1 400); do [ -s stubborn.pid ] && break; sleep 0.05; done
exit 0
SCRIPT
rm -f stubborn.pid
started=$(now_ms)
"$SUPERVISE" --term-grace 1 --kill-grace 5 --result "$fixture/result-stubborn.json" -- \
  "$BASH" "$fixture/client-stubborn.sh"
elapsed=$(($(now_ms) - started))
assert_dead "$(cat stubborn.pid)"
test "$elapsed" -ge 1000 || fail "SIGKILL arrived before the grace period ended: ${elapsed}ms"
test "$(result_field result-stubborn.json .drained)" = true

# SIGTERM to the supervisor cancels the whole session: the client and everything below it end first.
cat > client-wait.sh <<'SCRIPT'
sleep 300 &
echo $! > cancel-child.pid
( setsid sleep 300 & echo $! > cancel-grandchild.pid )
: > cancel.ready
sleep 300
SCRIPT
rm -f cancel.ready cancel-child.pid cancel-grandchild.pid
"$SUPERVISE" --term-grace 5 --result "$fixture/result-cancel.json" -- \
  "$BASH" "$fixture/client-wait.sh" &
supervisor_pid=$!
wait_for_file cancel.ready
kill -TERM "$supervisor_pid"
status=0
wait "$supervisor_pid" || status=$?
test "$status" -eq 143
assert_dead "$(cat cancel-child.pid)" "$(cat cancel-grandchild.pid)"
assert_dead "$supervisor_pid"
test "$(result_field result-cancel.json .cancelled)" = true
test "$(result_field result-cancel.json .drained)" = true

# SIGINT only cancels an operation inside the client. It never ends the session.
cat > client-operation.sh <<'SCRIPT'
: > operation.ready
while [ ! -e operation.release ]; do sleep 0.05; done
exit 7
SCRIPT
rm -f operation.ready operation.release
"$SUPERVISE" --result "$fixture/result-operation.json" -- "$BASH" "$fixture/client-operation.sh" &
supervisor_pid=$!
wait_for_file operation.ready
kill -INT "$supervisor_pid"
kill -QUIT "$supervisor_pid"
sleep 0.5
kill -0 "$supervisor_pid" || fail 'the supervisor ended the session on an operation-level signal'
test "$(result_field result-operation.json .phase)" = started
: > operation.release
status=0
wait "$supervisor_pid" || status=$?
test "$status" -eq 7
test "$(result_field result-operation.json .cancelled)" = false

# A lock the caller passes with --hold-fd stays held by the supervisor, not by the command, until every owned
# process ended. A caller that is killed outright does not release it.
cat > client-hold.sh <<'SCRIPT'
echo $PPID > "$OUT/supervisor.pid"
echo $$ > "$OUT/client.pid"
( setsid sleep 300 & echo $! > "$OUT/grandchild.pid" )
: > "$OUT/ready"
while [ ! -e "$OUT/release" ]; do sleep 0.05; done
exit 0
SCRIPT
lock_is_held() {
  ! flock -n "$fixture/job.lock" true
}
assert_lock_held() {
  if ! lock_is_held; then fail "$1"; fi
}
assert_lock_free() {
  if lock_is_held; then fail "$1"; fi
}

# The caller closes its own copy while the session runs: only the supervisor holds the lock now.
hold_out=$fixture/hold-out
rm -rf "$hold_out"
mkdir -p "$hold_out"
: > "$fixture/job.lock"
exec 8<>"$fixture/job.lock"
flock -x 8
OUT=$hold_out "$SUPERVISE" --hold-fd 8 --result "$fixture/result-hold.json" -- \
  "$BASH" "$fixture/client-hold.sh" &
supervisor_pid=$!
wait_for_file "$hold_out/ready"
exec 8>&-
assert_lock_held 'the lock was released while the supervised session was running'
for descriptor in "/proc/$(cat "$hold_out/client.pid")/fd"/*; do
  if [ "$(readlink "$descriptor")" = "$fixture/job.lock" ]; then
    fail 'the command inherited the held lock descriptor'
  fi
done
: > "$hold_out/release"
status=0
wait "$supervisor_pid" || status=$?
test "$status" -eq 0
assert_dead "$(cat "$hold_out/grandchild.pid")"
assert_lock_free 'the lock outlived the supervised session'

# The caller is killed with SIGKILL: the supervisor goes on, still holding the lock, until the session ends.
hold_out=$fixture/hold-killed-out
rm -rf "$hold_out"
mkdir -p "$hold_out"
OUT=$hold_out SUPERVISE=$SUPERVISE LOCK=$fixture/job.lock "$BASH" -c '
  exec 8<>"$LOCK"
  flock -x 8
  "$SUPERVISE" --hold-fd 8 -- "$BASH" "'"$fixture"'/client-hold.sh"
  status=$?
  exit "$status"
' &
runner_pid=$!
wait_for_file "$hold_out/ready"
kill -KILL "$runner_pid"
wait "$runner_pid" 2>/dev/null || true
supervisor_pid=$(cat "$hold_out/supervisor.pid")
alive "$supervisor_pid" || fail 'the supervisor ended with its caller'
assert_lock_held 'the lock was released when the caller was killed'
: > "$hold_out/release"
for _ in $(seq 1 200); do
  alive "$supervisor_pid" || break
  sleep 0.05
done
assert_dead "$supervisor_pid" "$(cat "$hold_out/grandchild.pid")"
assert_lock_free 'the lock outlived the supervised session after its caller was killed'

# A descriptor that is not open is refused before the command starts.
rm -f "$fixture/never-started"
status=0
"$SUPERVISE" --hold-fd 9 -- "$BASH" -c ': > "'"$fixture"'/never-started"' 2>/dev/null || status=$?
test "$status" -eq 70
test ! -e "$fixture/never-started"

hold_out=$fixture/parent-death-out
rm -rf "$hold_out"
mkdir -p "$hold_out"
OUT=$hold_out SUPERVISE=$SUPERVISE RESULT=$fixture/result-parent-death.json "$BASH" -c '
  "$SUPERVISE" --parent-death-cancels "$$" --result "$RESULT" -- "$BASH" "'"$fixture"'/client-hold.sh"
  status=$?
  exit "$status"
' &
runner_pid=$!
wait_for_file "$hold_out/ready"
supervisor_pid=$(cat "$hold_out/supervisor.pid")
kill -KILL "$runner_pid"
wait "$runner_pid" 2>/dev/null || true
for _ in $(seq 1 200); do
  alive "$supervisor_pid" || break
  sleep 0.05
done
assert_dead "$supervisor_pid" "$(cat "$hold_out/client.pid")" "$(cat "$hold_out/grandchild.pid")"
test "$(result_field result-parent-death.json .cancelled)" = true
test "$(result_field result-parent-death.json .drained)" = true

hold_out=$fixture/early-parent-death
mkdir -p "$hold_out"
cat > "$fixture/delayed-supervisor.sh" <<'SCRIPT'
: > "$OUT/supervisor-ready"
while [ ! -e "$OUT/release" ]; do sleep 0.02; done
exec "$SUPERVISE" --parent-death-cancels "$1" --result "$RESULT" -- "$BASH" -c ': > "$OUT/client-started"'
SCRIPT
OUT=$hold_out SUPERVISE=$SUPERVISE RESULT=$fixture/result-early-parent-death.json \
  DELAYED=$fixture/delayed-supervisor.sh "$BASH" -c '
  "$BASH" "$DELAYED" "$$" &
  echo $! > "$OUT/supervisor.pid"
  wait
' &
runner_pid=$!
wait_for_file "$hold_out/supervisor-ready"
supervisor_pid=$(cat "$hold_out/supervisor.pid")
kill -KILL "$runner_pid"
wait "$runner_pid" 2>/dev/null || true
: > "$hold_out/release"
for _ in $(seq 1 200); do
  alive "$supervisor_pid" || break
  sleep 0.05
done
assert_dead "$supervisor_pid"
test ! -e "$hold_out/client-started" || fail 'a caller that died before supervisor startup still started its command'
test "$(result_field result-early-parent-death.json .spawned)" = false
test "$(result_field result-early-parent-death.json .cancelled)" = true
test "$(result_field result-early-parent-death.json .drained)" = true

# Without --hold-fd the supervisor leaves every inherited descriptor alone: the command still holds what its caller passed.
: > "$fixture/inherited-file"
cat > client-inherited.sh <<'SCRIPT'
readlink /proc/self/fd/7 > "$OUT/inherited-fd"
SCRIPT
OUT=$fixture/out "$SUPERVISE" -- "$BASH" "$fixture/client-inherited.sh" 7<"$fixture/inherited-file"
test "$(cat out/inherited-fd)" = "$fixture/inherited-file"

# The executed file and argv[0] are independent: --argv0 changes only the name the command is started under.
OUT=$fixture/out "$SUPERVISE" --argv0 custom-name -- "$BASH" -c \
  'IFS= read -r -d "" first < /proc/self/cmdline; printf "%s\n" "$first" > "$OUT/argv0"'
test "$(cat out/argv0)" = custom-name
OUT=$fixture/out "$SUPERVISE" -- "$BASH" -c \
  'IFS= read -r -d "" first < /proc/self/cmdline; printf "%s\n" "$first" > "$OUT/argv0"'
test "$(cat out/argv0)" = "$BASH"

# Processes that outlive SIGKILL need an uninterruptible kernel state a sandbox cannot create, so the wait past
# the SIGKILL grace is covered by drain_transition.py with injected failures and not by the cases below.
result_lacks_strong_contract_fields() {
  test "$(result_field result-stubborn.json 'has("completion") or has("kill_grace_expired")')" = false
}

option_after_separator_belongs_to_command() {
  local status=0
  "$SUPERVISE" --result "$fixture/result-flag-argv.json" -- "$BASH" -c 'test "$1" = --require-drained' bash --require-drained || status=$?
  test "$status" -eq 0
  test "$(result_field result-flag-argv.json 'has("completion")')" = false
}

require_drained_without_command_is_a_usage_error() {
  local status=0
  "$SUPERVISE" --require-drained 2>/dev/null || status=$?
  test "$status" -eq 2
}

require_drained_healthy_command_is_joined() {
  local status=0
  "$SUPERVISE" --require-drained --result "$fixture/result-required-healthy.json" -- "$BASH" -c 'exit 0' || status=$?
  test "$status" -eq 0
  test "$(result_field result-required-healthy.json .phase)" = finished
  test "$(result_field result-required-healthy.json .completion)" = require-drained
  test "$(result_field result-required-healthy.json .drained)" = true
  test "$(result_field result-required-healthy.json .kill_grace_expired)" = false
}

require_drained_leftovers_keep_the_client_status() {
  local client_status status
  for client_status in 0 9; do
    rm -f child-a.pid child-b.pid grandchild.pid
    status=0
    CLIENT_STATUS=$client_status "$SUPERVISE" --require-drained --result "$fixture/result-required-leftovers.json" -- \
      "$BASH" "$fixture/client-leftovers.sh" || status=$?
    test "$status" -eq "$client_status"
    assert_dead "$(cat child-a.pid)" "$(cat child-b.pid)" "$(cat grandchild.pid)"
    test "$(result_field result-required-leftovers.json .drained)" = true
    test "$(result_field result-required-leftovers.json .client_status)" = "$client_status"
    test "$(result_field result-required-leftovers.json .completion)" = require-drained
    test "$(result_field result-required-leftovers.json .kill_grace_expired)" = false
  done
}

require_drained_awaits_slow_and_stubborn_processes() {
  local started elapsed
  rm -f slow.pid
  started=$(now_ms)
  "$SUPERVISE" --require-drained --term-grace 20 --result "$fixture/result-required-slow.json" -- \
    "$BASH" "$fixture/client-slow-stop.sh"
  elapsed=$(($(now_ms) - started))
  assert_dead "$(cat slow.pid)"
  test "$elapsed" -ge 1000 || fail "supervisor returned before the slow process stopped: ${elapsed}ms"
  test "$elapsed" -lt 15000 || fail "supervisor waited for the grace period instead of the process: ${elapsed}ms"
  test "$(result_field result-required-slow.json .kill_grace_expired)" = false

  rm -f stubborn.pid
  started=$(now_ms)
  "$SUPERVISE" --require-drained --term-grace 1 --kill-grace 5 --result "$fixture/result-required-stubborn.json" -- \
    "$BASH" "$fixture/client-stubborn.sh"
  elapsed=$(($(now_ms) - started))
  assert_dead "$(cat stubborn.pid)"
  test "$elapsed" -ge 1000 || fail "SIGKILL arrived before the grace period ended: ${elapsed}ms"
  test "$(result_field result-required-stubborn.json .drained)" = true
  test "$(result_field result-required-stubborn.json .kill_grace_expired)" = false
}

require_drained_session_cancellation_joins_every_process() {
  local supervisor_pid status=0
  rm -f cancel.ready cancel-child.pid cancel-grandchild.pid
  "$SUPERVISE" --require-drained --term-grace 5 --result "$fixture/result-required-cancel.json" -- \
    "$BASH" "$fixture/client-wait.sh" &
  supervisor_pid=$!
  wait_for_file cancel.ready
  kill -TERM "$supervisor_pid"
  wait "$supervisor_pid" || status=$?
  test "$status" -eq 143
  assert_dead "$(cat cancel-child.pid)" "$(cat cancel-grandchild.pid)"
  assert_dead "$supervisor_pid"
  test "$(result_field result-required-cancel.json .cancelled)" = true
  test "$(result_field result-required-cancel.json .drained)" = true
  test "$(result_field result-required-cancel.json .completion)" = require-drained
}

require_drained_parent_death_cancels_and_joins() {
  local hold_out=$fixture/required-parent-death-out runner_pid supervisor_pid
  rm -rf "$hold_out"
  mkdir -p "$hold_out"
  OUT=$hold_out SUPERVISE=$SUPERVISE RESULT=$fixture/result-required-parent-death.json "$BASH" -c '
    "$SUPERVISE" --require-drained --parent-death-cancels "$$" --result "$RESULT" -- "$BASH" "'"$fixture"'/client-hold.sh"
    status=$?
    exit "$status"
  ' &
  runner_pid=$!
  wait_for_file "$hold_out/ready"
  supervisor_pid=$(cat "$hold_out/supervisor.pid")
  kill -KILL "$runner_pid"
  wait "$runner_pid" 2>/dev/null || true
  for _ in $(seq 1 200); do
    alive "$supervisor_pid" || break
    sleep 0.05
  done
  assert_dead "$supervisor_pid" "$(cat "$hold_out/client.pid")" "$(cat "$hold_out/grandchild.pid")"
  test "$(result_field result-required-parent-death.json .cancelled)" = true
  test "$(result_field result-required-parent-death.json .drained)" = true
  test "$(result_field result-required-parent-death.json .completion)" = require-drained
}

require_drained_supervisor_holds_the_lock_until_the_join() {
  local hold_out=$fixture/required-hold-out supervisor_pid status=0
  rm -rf "$hold_out"
  mkdir -p "$hold_out"
  : > "$fixture/job.lock"
  exec 8<>"$fixture/job.lock"
  flock -x 8
  OUT=$hold_out "$SUPERVISE" --require-drained --hold-fd 8 --result "$fixture/result-required-hold.json" -- \
    "$BASH" "$fixture/client-hold.sh" &
  supervisor_pid=$!
  wait_for_file "$hold_out/ready"
  exec 8>&-
  assert_lock_held 'the lock was released while the supervised session was running'
  : > "$hold_out/release"
  wait "$supervisor_pid" || status=$?
  test "$status" -eq 0
  assert_dead "$(cat "$hold_out/grandchild.pid")"
  assert_lock_free 'the lock outlived the supervised session'
  test "$(result_field result-required-hold.json .drained)" = true
}

# 明示選択したSIGINTによるsession取消完了の検査
# 引数なし
# 戻り値: SIGQUITで継続しSIGINTで子孫回収した場合の0
# 副作用: fixture内のcommandと子孫の起動
# 失敗: 取消方針か完了記録か子孫回収の不一致による検査終了
interrupt_cancels_ends_the_session_on_sigint_only() {
  local supervisor_pid status=0
  rm -f cancel.ready cancel-child.pid cancel-grandchild.pid
  "$SUPERVISE" --require-drained --interrupt-cancels --term-grace 5 --result "$fixture/result-interrupt-cancel.json" -- \
    "$BASH" "$fixture/client-wait.sh" &
  supervisor_pid=$!
  wait_for_file cancel.ready
  kill -QUIT "$supervisor_pid"
  sleep 0.5
  kill -0 "$supervisor_pid" || fail 'the supervisor ended the session on SIGQUIT'
  test "$(result_field result-interrupt-cancel.json .phase)" = started
  kill -INT "$supervisor_pid"
  wait "$supervisor_pid" || status=$?
  test "$status" -eq 143
  assert_dead "$(cat cancel-child.pid)" "$(cat cancel-grandchild.pid)"
  assert_dead "$supervisor_pid"
  test "$(result_field result-interrupt-cancel.json .cancelled)" = true
  test "$(result_field result-interrupt-cancel.json .drained)" = true
}

result_lacks_strong_contract_fields
option_after_separator_belongs_to_command
require_drained_without_command_is_a_usage_error
require_drained_healthy_command_is_joined
require_drained_leftovers_keep_the_client_status
require_drained_awaits_slow_and_stubborn_processes
require_drained_session_cancellation_joins_every_process
require_drained_parent_death_cancels_and_joins
require_drained_supervisor_holds_the_lock_until_the_join
interrupt_cancels_ends_the_session_on_sigint_only
