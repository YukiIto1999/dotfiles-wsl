#!/usr/bin/env bash
set -euo pipefail

threshold=20
actual=20

if ((actual > threshold)); then
  exit 0
fi

printf 'FAIL: expected %d to reach threshold %d\n' "$actual" "$threshold" >&2
exit 1
