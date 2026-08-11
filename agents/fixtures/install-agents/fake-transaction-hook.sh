#!/usr/bin/env bash
set -euo pipefail

event=${1:?}
public_path=${2:-}
expected_event=${FIXTURE_TRANSACTION_HOOK_EVENT:-}

[[ -n $expected_event && $event == "$expected_event" ]] || exit 0
[[ -n ${FIXTURE_TRANSACTION_HOOK_MARKER:-} ]] || exit 64
if [[ -e $FIXTURE_TRANSACTION_HOOK_MARKER ]]; then
  exit 0
fi
: >"$FIXTURE_TRANSACTION_HOOK_MARKER"

case ${FIXTURE_TRANSACTION_HOOK_ACTION:-} in
  fail)
    exit 70
    ;;
  mutate-fail)
    [[ -d $public_path && ! -L $public_path ]] || exit 64
    printf '%s\n' changed-during-rollback >>"$public_path/codex-package.json"
    exit 70
    ;;
  replace-client-root-fail)
    [[ -n ${FIXTURE_TRANSACTION_HOOK_ROOT:-} ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_SAVED:-} ]] || exit 64
    mv -T -- "$FIXTURE_TRANSACTION_HOOK_ROOT" "$FIXTURE_TRANSACTION_HOOK_SAVED"
    mkdir -m 0700 -- "$FIXTURE_TRANSACTION_HOOK_ROOT"
    mkdir -m 0700 -- "$FIXTURE_TRANSACTION_HOOK_ROOT/releases"
    printf '%s\n' external >"$FIXTURE_TRANSACTION_HOOK_ROOT/external-marker"
    exit 70
    ;;
  hardlink)
    [[ -n $public_path ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_SAVED:-} ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_IDENTITY:-} ]] || exit 64
    ln -- "$public_path" "$FIXTURE_TRANSACTION_HOOK_SAVED"
    stat -c '%d:%i:%f:%u:%a:%h' -- "$public_path" >"$FIXTURE_TRANSACTION_HOOK_IDENTITY"
    ;;
  replace)
    [[ -n $public_path ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_SAVED:-} ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_TARGET:-} ]] || exit 64
    [[ -n ${FIXTURE_TRANSACTION_HOOK_IDENTITY:-} ]] || exit 64
    mv -T -- "$public_path" "$FIXTURE_TRANSACTION_HOOK_SAVED"
    ln -s -- "$FIXTURE_TRANSACTION_HOOK_TARGET" "$public_path"
    stat -c '%d:%i:%f:%u:%a' -- "$public_path" >"$FIXTURE_TRANSACTION_HOOK_IDENTITY"
    ;;
  *)
    exit 64
    ;;
esac
