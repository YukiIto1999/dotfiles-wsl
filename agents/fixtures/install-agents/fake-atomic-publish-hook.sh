#!/usr/bin/env bash
set -euo pipefail

event=${1:?}
source_directory=${2:?}
source_name=${3:?}
destination_directory=${4:?}
destination_name=${5:?}

source_filter_path=$source_directory
source_descriptor_view=
if [[ $source_directory =~ ^[0-9]+$ ]]; then
  source_descriptor_view=/proc/self/fd/$source_directory
  source_filter_path=$(readlink -f -- "$source_descriptor_view")
fi
if [[ $event == *quarantine* && -n $source_descriptor_view ]]; then
  source_directory=$source_descriptor_view
  destination_directory=$source_descriptor_view
fi

[[ $event == "${FIXTURE_ATOMIC_HOOK_EVENT:-}" ]] || exit 0
[[ -z ${FIXTURE_ATOMIC_HOOK_SOURCE:-} || $source_filter_path == "$FIXTURE_ATOMIC_HOOK_SOURCE" ]] \
  || exit 0
[[ -n ${FIXTURE_ATOMIC_HOOK_ACTION:-} ]] || exit 64
[[ -n ${FIXTURE_ATOMIC_HOOK_MARKER:-} ]] || exit 64
[[ ! -e $FIXTURE_ATOMIC_HOOK_MARKER ]] || exit 0
: >"$FIXTURE_ATOMIC_HOOK_MARKER"

if [[ $event == before-quarantine-move ]]; then
  [[ $destination_name =~ ^\.atomic-quarantine\.[0-9a-f]{32}$ ]] || exit 65
  [[ $(stat -c %a -- "$destination_directory/$destination_name") == 700 ]] || exit 65
  [[ $(stat -c %u -- "$destination_directory/$destination_name") == "$(id -u)" ]] || exit 65
fi

case $FIXTURE_ATOMIC_HOOK_ACTION in
  replace-directory)
    [[ -n ${FIXTURE_ATOMIC_HOOK_SAVED:-} ]] || exit 64
    if [[ -n $source_descriptor_view ]]; then
      source_directory=$source_filter_path
    fi
    mv -T -- "$source_directory" "$FIXTURE_ATOMIC_HOOK_SAVED"
    mkdir -m 0700 -- "$source_directory"
    ;;
  replace-object)
    [[ -n ${FIXTURE_ATOMIC_HOOK_SAVED:-} ]] || exit 64
    [[ -n ${FIXTURE_ATOMIC_HOOK_TARGET:-} ]] || exit 64
    mv -T -- "$source_directory/$source_name" "$FIXTURE_ATOMIC_HOOK_SAVED"
    ln -s -- "$FIXTURE_ATOMIC_HOOK_TARGET" "$source_directory/$source_name"
    ;;
  replace-quarantine)
    [[ -n ${FIXTURE_ATOMIC_HOOK_SAVED:-} ]] || exit 64
    [[ -n ${FIXTURE_ATOMIC_HOOK_TARGET:-} ]] || exit 64
    mv -T -- "$source_directory/$source_name" "$FIXTURE_ATOMIC_HOOK_SAVED"
    ln -s -- "$FIXTURE_ATOMIC_HOOK_TARGET" "$source_directory/$source_name"
    ;;
  remove-quarantine)
    rmdir -- "$source_directory/$source_name"
    ;;
  force-mismatch)
    exit 75
    ;;
  *) exit 64 ;;
esac

# Keep every argument live so shellcheck catches interface drift.
test -n "$destination_directory/$destination_name"
