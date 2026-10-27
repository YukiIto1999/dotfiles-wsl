set -euo pipefail

swap_file=$1
active_swaps=$(swapon --show=NAME --noheadings --raw)
if grep -Fxq -- "$swap_file" <<< "$active_swaps"; then
  exit 0
fi
exec swapon --priority 10 "$swap_file"
