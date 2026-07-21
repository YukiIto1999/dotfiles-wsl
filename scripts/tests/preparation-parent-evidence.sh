#!/usr/bin/env bash
set -Eeuo pipefail

receipt_source=${1:?rebuild receipt source is required}
probe_mode=${2:-full}
test_root=$(mktemp -d)
trap 'chmod -R u+w -- "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

state_root=$test_root/state
parent_id=11111111111111111111111111111111
child_id=22222222222222222222222222222222
uid=$EUID
gid=$(id -g)
mkdir -p "$state_root/successor-preparations" "$state_root/lineage" \
  "$state_root/successor-garbage"
chmod 0700 "$state_root" "$state_root/successor-preparations" "$state_root/lineage" \
  "$state_root/successor-garbage"

parent=$(jq -cn --arg id "$parent_id" \
  '{schemaVersion: 3, transactionId: $id, state: "verification-failed"}')
printf '%s\n' "$parent" > "$state_root/active.json"
chmod 0600 "$state_root/active.json"
parent_sha=$(sha256sum "$state_root/active.json" | cut -d ' ' -f 1)
parent_bytes=$(stat -c '%s' "$state_root/active.json")
parent_metadata=$(jq -cn \
  --arg path "lineage/$parent_id/verification-failed.json" \
  --arg sha "$parent_sha" --argjson bytes "$parent_bytes" \
  '{path: $path, sha256: $sha, bytes: $bytes}')
child=$(jq -cn --arg parent "$parent_id" --arg child "$child_id" \
  --argjson parentReceipt "$parent_metadata" '
  {
    schemaVersion: 4,
    transactionId: $child,
    state: "prepared",
    lineage: {
      kind: "verification-successor",
      protocolVersion: 2,
      parentTransactionId: $parent,
      parentReceipt: $parentReceipt,
      execution: {},
      createdAt: "fixture"
    },
    candidate: "/nix/store/child",
    recoveryTarget: "/nix/store/parent",
    previous: {running: "/nix/store/parent"},
    activation: {status: "pending", attempts: []},
    verification: {status: "pending"},
    failureStage: null,
    rollback: null,
    abort: null,
    cancellation: null,
    supersession: null
  }')
preparation=$state_root/successor-preparations/$parent_id-$child_id.json
printf '%s\n' "$child" > "$preparation"
chmod 0400 "$preparation"

# shellcheck disable=SC1090 # The production library path is an explicit test input.
source "$receipt_source"
dotfiles_rebuild_validate_receipt_file() {
  local file=$1 expected_uid=$2 expected_mode=${6:-600} metadata
  [[ -f $file && ! -L $file ]] || return 1
  metadata=$(stat -c '%u|%a|%h' -- "$file") || return 1
  [[ $metadata == "$expected_uid|$expected_mode|1" ]]
}

validate_preparation() {
  dotfiles_rebuild_validate_successor_preparation \
    "$state_root" "$preparation" "$uid" "$gid" /fixture /nix/store fixture \
    "$parent_id" "$child_id" >/dev/null
}

validate_preparation
mv "$state_root/active.json" "$test_root/parent.json"

if [[ $probe_mode == zero-evidence-red ]]; then
  if validate_preparation; then
    exit 1
  fi
  exit 0
fi

[[ $probe_mode == full ]]

set +e
validate_preparation
validation_status=$?
set -e
[[ $validation_status -eq 1 ]]

source_lineage=$state_root/lineage/$parent_id
mkdir -m 0700 "$source_lineage"
cp "$test_root/parent.json" "$source_lineage/verification-failed.json"
chmod 0400 "$source_lineage/verification-failed.json"
validate_preparation

# Both active and source evidence may coexist during preservation, but both
# must identify the same immutable parent bytes.
cp "$test_root/parent.json" "$state_root/active.json"
chmod 0600 "$state_root/active.json"
validate_preparation
rm "$state_root/active.json"

garbage_lineage=$state_root/successor-garbage/$parent_id-$child_id/lineage
mkdir -p "${garbage_lineage%/*}"
chmod 0700 "${garbage_lineage%/*}"
mv "$source_lineage" "$garbage_lineage"
validate_preparation

chmod 0600 "$garbage_lineage/verification-failed.json"
printf '\n' >> "$garbage_lineage/verification-failed.json"
chmod 0400 "$garbage_lineage/verification-failed.json"
set +e
validate_preparation
validation_status=$?
set -e
[[ $validation_status -eq 1 ]]
