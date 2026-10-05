# shellcheck shell=bash

set -euo pipefail

[[ ${1-} == show ]] || exit 64
shift

declare -A requested=()
units=()
for argument in "$@"; do
  case $argument in
    --property=*)
      IFS=, read -ra properties <<<"${argument#--property=}"
      for property in "${properties[@]}"; do
        case $property in
          Id | LoadState | Slice) requested[$property]=1 ;;
          *) exit 64 ;;
        esac
      done
      ;;
    -*) exit 64 ;;
    *) units+=("$argument") ;;
  esac
done
((${#units[@]} > 0 && ${#requested[@]} > 0)) || exit 64
printf '%s\n' "${units[@]}" >>"$FAKE_SYSTEMCTL_LOG"

separator=''
for unit in "${units[@]}"; do
  printf '%s' "$separator"
  separator=$'\n'
  load=not-found
  slice=''
  while IFS='|' read -r known known_slice; do
    if [[ $known == "$unit" ]]; then
      load=loaded
      slice=$known_slice
    fi
  done <"$FAKE_SCOPES"
  # systemd が property 表の順で出力するため要求の順での出力は不可
  [[ ! -v requested[Id] ]] || printf 'Id=%s\n' "$unit"
  [[ ! -v requested[LoadState] ]] || printf 'LoadState=%s\n' "$load"
  [[ ! -v requested[Slice] ]] || printf 'Slice=%s\n' "$slice"
done
