set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verify -- COMMAND [ARG...]\n' >&2
  exit 64
}

started_ms=$((${EPOCHREALTIME/[.,]/} / 1000))
budget_seconds=
budget_error=
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

# 入口の一覧のいずれかが呼び出しの綴りと一致するか。一覧は entry_file に一行ずつ入る
names_entry() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$1" ] || return 0
  done <"$entry_file"
  return 1
}

if [ "${1-}" = -- ]; then
  shift
fi
test "$#" -gt 0 || usage

if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
  exec @verificationCache@ -- "$@"
fi
trap 'interrupted=true; [ -z "$bounded_pid" ] || kill -s TERM "$bounded_pid" 2>/dev/null || true' HUP INT TERM XFSZ
entry_file=$(mktemp)
policy_file=$(mktemp)
trap 'rm -f -- "$entry_file" "$policy_file"' EXIT
status=0
if @gate@ snapshot --repo "$top" >"$policy_file" 2>"$entry_file"; then
  if budget=$(@gate@ budget --repo "$top" --policy "$policy_file" 2>&1) && [[ $budget =~ ^[1-9][0-9]*$ ]]; then
    budget_seconds=$budget
  else
    budget_error=$budget
  fi
else
  budget_error=$(cat "$entry_file")
fi
if [ -n "$budget_seconds" ]; then
  if ! refresh_remaining; then
    exit 124
  fi
  run_bounded @gate@ entry --repo "$top" --policy "$policy_file" >"$entry_file" || status=$?
else
  # 読めない予算の既定値補完と期限なしの評価は不可のため、評価器を起動せず入口になり得る綴りだけを集める
  @gate@ candidates --repo "$top" >"$entry_file" || status=$?
fi
[ "$interrupted" = false ] || status=130
[ "$status" -eq 0 ] || exit "$status"
if names_entry "$*" \
  && [ "$(realpath -e -- "$PWD")" = "$(realpath -e -- "$top")" ]; then
  if [ -z "$budget_seconds" ]; then
    printf 'verify: T1 の入口 %s の時間予算を決められないため実行しない\n%s\n' "$*" "$budget_error" >&2
    exit 78
  fi
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
      run_bounded rm -f -- "$entry_file" "$policy_file" || status=$?
      trap - EXIT
    else
      status=124
    fi
    if [ "$status" -eq 0 ] && [ "$interrupted" = false ]; then
      if [ -n "$published" ]; then
        printf 'completed=true\n' >>"$published" || status=$?
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
rm -f -- "$entry_file" "$policy_file"
trap - EXIT
exec @verificationCache@ -- "$@"
