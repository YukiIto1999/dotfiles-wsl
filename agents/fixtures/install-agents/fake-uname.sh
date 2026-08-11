#!/usr/bin/env bash
set -euo pipefail

[[ ${1-} == -m ]] || exit 64
printf '%s\n' "$FIXTURE_ARCH"
