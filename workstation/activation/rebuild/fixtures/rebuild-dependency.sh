#!/usr/bin/env bash
set -euo pipefail

command_name=${0##*/}
{
  printf '%s' "$command_name"
  printf ' %q' "$@"
  printf '\n'
} >> "$REBUILD_CALL_LOG"

case $command_name in
  nix)
    [[ $1 == build ]]
    [[ ${REBUILD_BUILD_STATUS:-0} == 0 ]] || exit "$REBUILD_BUILD_STATUS"
    printf '%s\n' "$REBUILD_CANDIDATE"
    ;;
  nix-env)
    [[ $* == "--list-generations --profile $REBUILD_SYSTEM_PROFILE" ]]
    [[ ${REBUILD_HISTORY_STATUS:-0} == 0 ]] || exit "$REBUILD_HISTORY_STATUS"
    cat "$REBUILD_GENERATIONS"
    ;;
  nvd)
    [[ $1 == diff && $3 == "$REBUILD_CANDIDATE" ]]
    ;;
  sudo)
    exec "$@"
    ;;
  nixos-rebuild)
    [[ $1 == switch ]]
    if [[ ${REBUILD_PARTIAL_SWITCH:-0} == 1 ]]; then
      ln -sfn "$REBUILD_CANDIDATE" "$REBUILD_SYSTEM_PROFILE"
    fi
    [[ ${REBUILD_SWITCH_STATUS:-0} == 0 ]] || exit "$REBUILD_SWITCH_STATUS"
    ;;
  *)
    printf 'unexpected fixture dependency: %s\n' "$command_name" >&2
    exit 1
    ;;
esac
