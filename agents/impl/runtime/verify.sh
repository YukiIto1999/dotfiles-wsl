set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verify -- COMMAND [ARG...]\n' >&2
  exit 64
}

if [ "${1-}" = -- ]; then
  shift
fi
test "$#" -gt 0 || usage

started=$SECONDS
budget_seconds=@t1BudgetSeconds@
if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
  exec @verificationCache@ "$@"
fi
entry=$(timeout --kill-after=30s "$budget_seconds" @gate@ entry --repo "$top") || exit $?
if [ -n "$entry" ] && [ "$*" = "$entry" ] \
  && [ "$(realpath -e -- "$PWD")" = "$(realpath -e -- "$top")" ]; then
  remaining=$((budget_seconds - (SECONDS - started)))
  if [ "$remaining" -le 0 ]; then
    printf 'verify: T1 の時間予算を入口解決で使い切った\n' >&2
    exit 124
  fi
  exec timeout --kill-after=30s "$remaining" @verificationCache@ "$@"
fi
exec @verificationCache@ "$@"
