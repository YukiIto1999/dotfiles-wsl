#!/usr/bin/env bash
set -euo pipefail
source_root="${BASH_SOURCE[0]%/scripts/*}"
cat "$source_root/references/contract.txt"
