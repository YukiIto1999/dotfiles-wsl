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

# 別 session の孫が検証の返却時点でまだ動くかを判定する観測
# 引数 $1: 当該 fixture が起動した Linux process 番号
# 戻り値: 読取可能な非 zombie process なら0でそれ以外は1
# 返却後の待ち直しは別 session の孫の回収を返却時点で検証できないため不可
process_alive() {
  local proc_stat
  proc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  [[ ${proc_stat##*) } != [ZX]* ]]
}

cat >command.sh <<'SH'
setsid bash -c 'printf "%s\n" "$$" >grandchild.pid; sleep 4; touch late' </dev/null >/dev/null 2>&1 &
wait
SH
rm -f stopped late grandchild.pid
status=0
"$WITHIN" 2 bash command.sh || status=$?
[ "$status" -eq 124 ] || fail "a command that started a grandchild in its own session ended with status $status instead of 124"
[ -s grandchild.pid ] || fail 'the command never started the delayed writer in its own session'
if process_alive "$(<grandchild.pid)"; then
  fail 'a grandchild in its own session was still running when the standalone budget returned'
fi
test ! -e late || fail 'a grandchild in its own session wrote after the standalone budget returned'
