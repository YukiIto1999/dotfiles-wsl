#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${REBUILD_RACE_COMMIT:-} && ${1:-} == -C && ${2:-} == "$REBUILD_CHECKOUT" && ${3:-} == update-index && ${4:-} == -q && ${5:-} == --refresh && ! -e $REBUILD_RACE_RESULT ]]; then
  if "@git@" -C "$REBUILD_CHECKOUT" update-ref HEAD "$REBUILD_RACE_COMMIT" "$REBUILD_RACE_BASE"; then
    printf 'changed\n' >"$REBUILD_RACE_RESULT"
  else
    printf 'blocked\n' >"$REBUILD_RACE_RESULT"
  fi
fi
exec "@git@" "$@"
