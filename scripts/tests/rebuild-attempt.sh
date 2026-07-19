#!/usr/bin/env bash
set -euo pipefail

attempt_source=${1:?rebuild attempt source path is required}
# shellcheck source=/dev/null
source "$attempt_source"

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

state_root=$test_root/dotfiles-rebuild
expected_uid=$EUID
expected_gid=$(id -g)
transaction_id=0123456789abcdef0123456789abcdef
attempt_id=fedcba9876543210fedcba9876543210
mkdir -m 0700 -- "$state_root"

attempt_root=$(dotfiles_rebuild_prepare_attempt_directory \
  "$state_root" "$expected_uid" "$expected_gid" "$transaction_id" 1 "$attempt_id")
printf '%s\n' '{"schemaVersion":1}' | dotfiles_rebuild_create_attempt_json \
  "$attempt_root" "$expected_uid" "$expected_gid" intent.json
intent_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
  "$state_root" "$attempt_root/intent.json" "$expected_uid" 600)
dotfiles_rebuild_verify_artifact_metadata \
  "$state_root" "$intent_metadata" "$expected_uid" 600 \
  "attempts/$transaction_id/1-$attempt_id/intent.json"

printf '%s\n' '{"schemaVersion":2}' > "$attempt_root/intent.json"
if dotfiles_rebuild_verify_artifact_metadata \
  "$state_root" "$intent_metadata" "$expected_uid" 600 \
  "attempts/$transaction_id/1-$attempt_id/intent.json" 2>/dev/null; then
  echo "tampered activation artifact was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schemaVersion":1}' > "$attempt_root/intent.json"
intent_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
  "$state_root" "$attempt_root/intent.json" "$expected_uid" 600)
wrong_path_metadata=$(jq -c '.path = "attempts/other/intent.json"' <<< "$intent_metadata")
if dotfiles_rebuild_verify_artifact_metadata \
  "$state_root" "$wrong_path_metadata" "$expected_uid" 600 \
  "attempts/$transaction_id/1-$attempt_id/intent.json" 2>/dev/null; then
  echo "activation artifact with a substituted path was accepted" >&2
  exit 1
fi

ln "$attempt_root/intent.json" "$attempt_root/intent-hardlink.json"
if dotfiles_rebuild_verify_artifact_metadata \
  "$state_root" "$intent_metadata" "$expected_uid" 600 \
  "attempts/$transaction_id/1-$attempt_id/intent.json" 2>/dev/null; then
  echo "hard-linked activation artifact was accepted" >&2
  exit 1
fi

schema2_receipt=$test_root/schema-2.json
printf '%s\n' '{"schemaVersion":2}' > "$schema2_receipt"
chmod 0600 "$schema2_receipt"
migration_file=$(dotfiles_rebuild_preserve_schema2_receipt \
  "$state_root" "$expected_uid" "$expected_gid" "$transaction_id" "$schema2_receipt")
replayed_migration_file=$(dotfiles_rebuild_preserve_schema2_receipt \
  "$state_root" "$expected_uid" "$expected_gid" "$transaction_id" "$schema2_receipt")
[[ $replayed_migration_file == "$migration_file" ]]
cmp -s -- "$schema2_receipt" "$migration_file"

second_attempt_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
second_attempt_root=$(dotfiles_rebuild_prepare_attempt_directory \
  "$state_root" "$expected_uid" "$expected_gid" "$transaction_id" 2 "$second_attempt_id")
dotfiles_rebuild_prepare_partial_log \
  "$second_attempt_root" "$expected_uid" "$expected_gid"
printf '%s\n' 'activation output' > "$second_attempt_root/activation.log.partial"
# finalize の chmod 後、rename 前で停止した durable transitional state。
chmod 0400 "$second_attempt_root/activation.log.partial"
dotfiles_rebuild_finalize_attempt_log \
  "$second_attempt_root" "$expected_uid" "$expected_gid"
dotfiles_rebuild_validate_attempt_file \
  "$second_attempt_root/activation.log" "$expected_uid" 400
