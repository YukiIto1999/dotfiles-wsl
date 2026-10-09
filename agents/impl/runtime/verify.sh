set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verify -- COMMAND [ARG...]\n' >&2
  exit 64
}

started_ms=$((${EPOCHREALTIME/[.,]/} / 1000))
budget_seconds=@t1BudgetSeconds@
remaining=

refresh_remaining() {
  local left=$((budget_seconds * 1000 - (${EPOCHREALTIME/[.,]/} / 1000 - started_ms)))
  [ "$left" -gt 0 ] || return 1
  printf -v remaining '%d.%03d' "$((left / 1000))" "$((left % 1000))"
}

bounded_pid=
interrupted=false
run_bounded() {
  local status
  [ "$interrupted" = false ] || return 130
  timeout --kill-after=30s "$remaining" "$@" <&0 &
  bounded_pid=$!
  if [ "$interrupted" = true ]; then
    kill -s TERM "$bounded_pid" 2>/dev/null || true
  fi
  while :; do
    if wait "$bounded_pid"; then status=0; else status=$?; fi
    [ -n "$(jobs -rp)" ] || break
  done
  bounded_pid=
  return "$status"
}

if [ "${1-}" = -- ]; then
  shift
fi
test "$#" -gt 0 || usage

if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
  exec @verificationCache@ -- "$@"
fi
trap 'interrupted=true; [ -z "$bounded_pid" ] || kill -s TERM "$bounded_pid" 2>/dev/null || true' HUP INT TERM
entry_file=$(mktemp)
trap 'rm -f -- "$entry_file"' EXIT
if ! refresh_remaining; then
  exit 124
fi
status=0
run_bounded @gate@ entry --repo "$top" >"$entry_file" || status=$?
[ "$interrupted" = false ] || status=130
[ "$status" -eq 0 ] || exit "$status"
entry=$(cat "$entry_file")
if [ -n "$entry" ] && [ "$*" = "$entry" ] \
  && [ "$(realpath -e -- "$PWD")" = "$(realpath -e -- "$top")" ]; then
  if ! refresh_remaining; then
    printf 'verify: T1 の時間予算を入口解決で使い切った\n' >&2
    exit 124
  fi
  receipt=${EPOCHREALTIME/[.,]/}.$$
  status=0
  run_bounded @verificationCache@ --receipt "$receipt" -- "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    if refresh_remaining; then
      run_bounded @gate@ publish --repo "$top" --pending "$receipt" >"$entry_file" || status=$?
    else
      status=124
    fi
  fi
  if [ "$status" -eq 0 ]; then
    published=$(cat "$entry_file")
    if refresh_remaining; then
      run_bounded rm -f -- "$entry_file" || status=$?
      trap - EXIT
    else
      status=124
    fi
    if [ "$status" -eq 0 ] && [ "$interrupted" = false ]; then
      if [ -n "$published" ]; then
        printf 'completed=true\n' >>"$published"
      fi
      refresh_remaining || status=124
    fi
  fi
  if [ "$status" -eq 0 ] && [ "$interrupted" = true ]; then
    status=130
  fi
  if [ "$status" -ne 0 ]; then
    (trap '' HUP INT TERM; exec @gate@ discard --pending "$receipt") || true
    exit "$status"
  fi
  exit 0
fi
rm -f -- "$entry_file"
trap - EXIT
exec @verificationCache@ -- "$@"
