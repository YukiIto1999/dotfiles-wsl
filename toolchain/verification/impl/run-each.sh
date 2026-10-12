#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: dotfiles-run-each JOBS COMMAND [ARG...] -- ITEM...\n' >&2
  exit 64
}

[ "$#" -ge 4 ] || usage
limit=$1
shift
case $limit in
'' | *[!0-9]* | 0*) usage ;;
esac
command=()
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  command+=("$1")
  shift
done
[ "${#command[@]}" -gt 0 ] || usage
[ "$#" -ge 2 ] || usage
shift
items=("$@")

declare -A item_of started_at
pids=()
next=0
status=0
interrupted=0

# 子孫の同一process groupへの維持: 外側のrun-withinによるgroup停止
stop_running() {
  local pid
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}

trap 'interrupted=1; stop_running' INT TERM HUP
trap 'stop_running; wait' EXIT

start() {
  local item=$1
  "${command[@]}" "$item" &
  pids+=("$!")
  item_of[$!]=$item
  started_at[$!]=$SECONDS
  printf 'run-each: start %s\n' "$item" >&2
}

while :; do
  while [ "$status" -eq 0 ] && [ "$interrupted" -eq 0 ] \
    && [ "${#pids[@]}" -lt "$limit" ] && [ "$next" -lt "${#items[@]}" ]; do
    start "${items[next]}"
    next=$((next + 1))
  done
  [ "${#pids[@]}" -gt 0 ] || break
  finished=
  code=0
  wait -n -p finished "${pids[@]}" || code=$?
  # signal中断時の空PIDへの対応: wait -pによる変数の解除
  [ -n "${finished:-}" ] || continue
  remaining=()
  for pid in "${pids[@]}"; do
    [ "$pid" = "$finished" ] || remaining+=("$pid")
  done
  pids=("${remaining[@]}")
  began=${started_at[$finished]}
  printf 'run-each: %s exited %d after %ds\n' "${item_of[$finished]}" "$code" "$((SECONDS - began))" >&2
  if [ "$code" -ne 0 ] && [ "$status" -eq 0 ] && [ "$interrupted" -eq 0 ]; then
    status=$code
    stop_running
  fi
done
trap - INT TERM HUP
# 取消後の子のstatusへの委任の禁止: signalで0終了する子による成功誤判定
[ "$interrupted" -eq 0 ] || exit 130
exit "$status"
