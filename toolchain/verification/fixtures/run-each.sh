#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'run-each: %s\n' "$*" >&2
  exit 1
}

await() {
  local file=$1 tries=0
  until [ -e "$file" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 300 ] || fail "timed out waiting for $file"
    sleep 0.1
  done
}

cat >worker.sh <<'SH'
item=$1
printf '%s\n' "$item" >>started
case $item in
fail)
  until [ -e ready.hold ]; do sleep 0.1; done
  exit 7
  ;;
hold*)
  sleep 30 &
  child=$!
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; touch "stopped.$item"; [ "$item" != hold-zero ] || exit 0; exit 143' TERM
  touch "ready.$item"
  wait "$child"
  touch "finished.$item"
  ;;
*)
  touch "active.$item"
  running=(active.*)
  printf '%s\n' "${#running[@]}" >>concurrency
  sleep 2
  rm -f "active.$item"
  ;;
esac
SH

status=0
timeout 60 "$EACH" 2 bash worker.sh -- a b c d || status=$?
[ "$status" -eq 0 ] || fail "successful items ended with status $status"
[ "$(sort started | tr '\n' ' ')" = 'a b c d ' ] || fail 'not every item ran exactly once'
grep -qx 2 concurrency || fail 'two items never ran at the same time'
if grep -q '^[3-9]' concurrency; then
  fail 'more items ran at once than the job limit'
fi

rm -f started concurrency ready.* stopped.* finished.*
status=0
timeout 60 "$EACH" 2 bash worker.sh -- hold fail never || status=$?
[ "$status" -eq 7 ] || fail "the first failure ended with status $status instead of 7"
test -e stopped.hold || fail 'a failure returned before the running item finished stopping'
test ! -e finished.hold || fail 'a running item survived the failure of another item'
if grep -qx never started; then
  fail 'an item started after another item had failed'
fi

rm -f started ready.* stopped.* finished.*
"$EACH" 2 bash worker.sh -- hold-zero hold2 never &
runner=$!
await ready.hold-zero
await ready.hold2
kill -TERM "$runner"
status=0
wait "$runner" || status=$?
[ "$status" -eq 130 ] || fail "a cancelled run ended with status $status instead of 130"
test -e stopped.hold-zero || fail 'the cancelled run returned before the first item stopped'
test -e stopped.hold2 || fail 'the cancelled run returned before the second item stopped'
if grep -qx never started; then
  fail 'an item started after the run was cancelled'
fi

for invalid in '0 true -- item' '2 true' '2 true --' '2 -- item other' 'two true -- item'; do
  status=0
  read -r -a invalid_args <<<"$invalid"
  "$EACH" "${invalid_args[@]}" 2>/dev/null || status=$?
  [ "$status" -eq 64 ] || fail "invalid arguments '$invalid' ended with status $status instead of 64"
done
