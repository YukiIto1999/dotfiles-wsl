#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'run-within: %s\n' "$*" >&2
  exit 1
}

cat >command.sh <<'SH'
trap 'sleep 1; touch stopped; exit 0' TERM
(sleep 4; touch late) &
wait
SH

rm -f stopped late
status=0
timeout --preserve-status --kill-after=10s 2 "$WITHIN" 60 bash command.sh || status=$?
[ "$status" -ne 0 ] || fail 'a command cancelled by its caller exited 0'
test -e stopped || fail 'the caller deadline returned before the command finished stopping'
sleep 3
test ! -e late || fail 'a descendant outlived the caller deadline'

rm -f stopped late
status=0
"$WITHIN" 2 bash command.sh || status=$?
[ "$status" -eq 124 ] || fail "the standalone budget ended with status $status instead of 124"
test -e stopped || fail 'the standalone budget returned before the command finished stopping'
sleep 3
test ! -e late || fail 'a descendant outlived the standalone budget'

cat >command.sh <<'SH'
(
  trap '' TERM
  sleep 4
  touch late
) &
wait
SH
rm -f stopped late
status=0
"$WITHIN" 2 bash command.sh || status=$?
[ "$status" -eq 124 ] || fail "an orphaning command ended with status $status instead of 124"
sleep 3
test ! -e late || fail 'a TERM-ignoring descendant outlived its command'
