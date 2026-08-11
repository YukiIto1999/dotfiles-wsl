#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  if [[ $argument == --extract || $argument == -x* ]]; then
    if [[ -n ${FIXTURE_TAR_LOG:-} ]]; then
      printf '%s\n' extract >>"$FIXTURE_TAR_LOG"
    fi
    break
  fi
done

exec @tarCommand@ "$@"
