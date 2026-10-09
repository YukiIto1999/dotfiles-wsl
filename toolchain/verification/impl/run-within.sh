#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: dotfiles-run-within SECONDS COMMAND [ARG...]\n' >&2
  exit 64
}

[ "$#" -ge 2 ] || usage
budget_seconds=$1
shift

pid=
interrupted=0
cancel() {
  interrupted=1
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi
}
trap cancel INT TERM HUP
[ "$interrupted" -eq 0 ] || exit 130
# 外側の30秒猶予より先に子孫を止めるため同じ猶予は不可
timeout --kill-after=5s "$budget_seconds" "$@" &
pid=$!
[ "$interrupted" -eq 0 ] || cancel
while :; do
  status=0
  wait "$pid" || status=$?
  # signal で中断された wait は job の終了を待たずに戻るため単発の wait は不可
  kill -0 "$pid" 2>/dev/null || break
done
if [ "$interrupted" -ne 0 ] || [ "$status" -eq 124 ]; then
  kill -KILL -- "-$pid" 2>/dev/null || true
fi
trap - INT TERM HUP
# signal を受けて 0 で終わる子が成功に見えるため子の status への委任は不可
[ "$interrupted" -eq 0 ] || exit 130
exit "$status"
