#!/usr/bin/env bash
set -euo pipefail

enroll=${1:?enrollment command is required}
age_keygen=${2:?age-keygen path is required}
sops=${3:?sops path is required}
keyctl=${4:?key control command is required}

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

dotfiles=$test_root/dotfiles-wsl
secrets_dir=$dotfiles/secrets
config=$secrets_dir/.sops.yaml
encrypted=$secrets_dir/secrets.yaml
recovery_key=$test_root/recovery-key.txt
wrong_recovery_key=$test_root/wrong-recovery-key.txt

mkdir -p "$secrets_dir" "$test_root/var/lib"
"$age_keygen" -o "$recovery_key" >/dev/null 2>&1
"$age_keygen" -o "$wrong_recovery_key" >/dev/null 2>&1
chmod 0600 "$recovery_key" "$wrong_recovery_key"

select_key_dir() {
  local name=$1
  key_dir=$test_root/var/lib/$name
  active_key=$key_dir/key.txt
  next_key=$key_dir/key.next
  journal=$key_dir/enrollment.json
  receipt=$key_dir/enrollment-receipt.json
  generation_root=$test_root/generations/$name
  current_system=$generation_root/run/current-system
  system_profile=$generation_root/profiles/system
  installer_log=$generation_root/installer.log
}

use_key_dir() {
  select_key_dir "$1"
  mkdir -m 0700 -- "$key_dir"
  mkdir -p -- "$generation_root/run" "$generation_root/profiles" "$generation_root/store"
}

use_migration_key_dir() {
  use_key_dir "$1"
  cp "$recovery_key" "$active_key"
  chmod 0400 "$active_key"
}

activate_generation() {
  local source_ciphertext=${1:-$encrypted}
  local generation_number generation_counter closure ciphertext installer manifest contract profile_dir profile_name
  profile_dir=$(dirname -- "$system_profile")
  profile_name=$(basename -- "$system_profile")
  generation_counter=$generation_root/next-generation
  generation_number=1
  if [[ -f $generation_counter ]]; then
    generation_number=$(< "$generation_counter")
  fi
  printf '%d\n' "$((generation_number + 1))" > "$generation_counter"
  closure=$generation_root/store/system-$generation_number
  ciphertext=$closure/secrets.yaml
  installer=$closure/reinstall-secrets
  manifest=$closure/sops-manifest.json
  contract=$closure/etc/dotfiles/sops-generation.json

  mkdir -p -- "$closure/etc/dotfiles"
  cp -- "$source_ciphertext" "$ciphertext"
  cat > "$installer" <<EOF
#!$BASH
set -euo pipefail
env -i HOME=/var/empty PATH=$(dirname -- "$sops") SOPS_AGE_KEY_FILE=$active_key \
  $sops decrypt $ciphertext >/dev/null
printf '%s\n' $generation_number >> $installer_log
EOF
  chmod 0555 "$installer"
  jq -n \
    --arg ageKeyFile "$active_key" \
    --arg ciphertext "$ciphertext" \
    --arg ciphertextSha256 "$(sha256sum "$ciphertext" | cut -d ' ' -f 1)" \
    '{ageKeyFile: $ageKeyFile,
      secrets: [{sopsFile: $ciphertext, sopsFileHash: $ciphertextSha256}]}' > "$manifest"
  jq -n \
    --arg ciphertext "$ciphertext" \
    --arg ciphertextSha256 "$(sha256sum "$ciphertext" | cut -d ' ' -f 1)" \
    --arg manifest "$manifest" \
    --arg installer "$installer" \
    '{schemaVersion: 1, ciphertext: {path: $ciphertext, sha256: $ciphertextSha256},
      sopsManifest: $manifest, reinstallSecrets: $installer}' > "$contract"
  ln -s -- "$closure" "$profile_dir/$profile_name-$generation_number-link"
  ln -sfn -- "$profile_name-$generation_number-link" "$system_profile"
  ln -sfn -- "$closure" "$current_system"
}

fake_nix_env=$test_root/fake-nix-env
cat > "$fake_nix_env" <<EOF
#!$BASH
set -euo pipefail
[[ \$1 == --profile && \$3 == --delete-generations ]]
profile=\$2
shift 3
profile_dir=\$(dirname -- "\$profile")
profile_name=\$(basename -- "\$profile")
for generation in "\$@"; do
  [[ \$generation =~ ^[0-9]+\$ ]]
  rm -f -- "\$profile_dir/\$profile_name-\$generation-link"
done
if [[ \${SOPS_ENROLL_TEST_NIX_ENV_FAIL_AFTER_DELETE:-0} == 1 ]]; then
  exit 73
fi
EOF
chmod +x "$fake_nix_env"

# 現在の runtime key と recovery key が同じ、実環境の migration 開始状態を再現する。
use_migration_key_dir migration-host
recovery_recipient=$("$age_keygen" -y "$recovery_key")

cat > "$config" <<EOF
keys:
  - &recovery $recovery_recipient
creation_rules:
  - path_regex: ^secrets\\.yaml$
    key_groups:
      - age:
          - *recovery
EOF

printf '%s\n' 'fixture: enrollment-secret' > "$encrypted"
SOPS_AGE_KEY_FILE=$recovery_key \
  "$sops" --config "$config" --encrypt --in-place "$encrypted"

activate_generation "$encrypted"
booted_generation_ciphertext=$test_root/booted-generation-secrets.yaml
cp -- "$encrypted" "$booted_generation_ciphertext"

git -C "$dotfiles" init -q
git -C "$dotfiles" config user.name fixture
git -C "$dotfiles" config user.email fixture@example.invalid
git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm initial
common_git_dir=$(git -C "$dotfiles" rev-parse --path-format=absolute --git-common-dir)

# 古い clone が観測した transaction ID で、新しい root transaction を破棄できない。
use_key_dir keyctl-aba
first_root_status=$(SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" stage)
first_transaction_id=$(jq -r '.transactionId' <<< "$first_root_status")
SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" abort "$first_transaction_id"
second_root_status=$(SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" stage)
second_transaction_id=$(jq -r '.transactionId' <<< "$second_root_status")
test "$first_transaction_id" != "$second_transaction_id"
if SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" abort "$first_transaction_id" \
  > "$test_root/stale-root-abort-output" 2>&1; then
  echo 'a stale transaction id aborted a newer root transaction' >&2
  exit 1
fi
test "$(jq -r '.transactionId' < <(SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" status))" = \
  "$second_transaction_id"
SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" abort "$second_transaction_id"

# root identity file は recipient を一つだけ持つ。複数 identity を journal 観測へ流さない。
use_key_dir multiple-identities
SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" stage >/dev/null
chmod 0600 "$next_key"
cat "$wrong_recovery_key" >> "$next_key"
chmod 0400 "$next_key"
if SOPS_ENROLL_TEST_KEY_DIR=$key_dir "$keyctl" status \
  > "$test_root/multiple-identities-output" 2>&1; then
  echo 'key control accepted multiple identities in key.next' >&2
  exit 1
fi
grep -Fq 'must contain exactly one age identity' "$test_root/multiple-identities-output"
rm -r -- "$key_dir"

select_key_dir migration-host

run_enroll() {
  (
    cd "$dotfiles"
    SOPS_ENROLL_TEST_KEY_DIR=$key_dir \
      SOPS_ENROLL_TEST_DOTFILES=$dotfiles \
      SOPS_ENROLL_TEST_CURRENT_SYSTEM=$current_system \
      SOPS_ENROLL_TEST_SYSTEM_PROFILE=$system_profile \
      SOPS_ENROLL_TEST_NIX_ENV=$fake_nix_env \
      "$enroll" "$@"
  )
}

run_enroll_at() {
  local worktree=$1
  shift
  (
    cd "$worktree"
    SOPS_ENROLL_TEST_KEY_DIR=$key_dir \
      SOPS_ENROLL_TEST_DOTFILES=$dotfiles \
      SOPS_ENROLL_TEST_CURRENT_SYSTEM=$current_system \
      SOPS_ENROLL_TEST_SYSTEM_PROFILE=$system_profile \
      SOPS_ENROLL_TEST_NIX_ENV=$fake_nix_env \
      "$enroll" "$@"
  )
}

# recovery identity も一つだけ許し、複数 identity を一つの recipient と誤認しない。
multiple_recovery_key=$test_root/multiple-recovery-key.txt
cp -- "$recovery_key" "$multiple_recovery_key"
cat "$wrong_recovery_key" >> "$multiple_recovery_key"
chmod 0600 "$multiple_recovery_key"
if run_enroll prepare \
  --recovery-key "$multiple_recovery_key" \
  --host-id multiple-recovery > "$test_root/multiple-recovery-output" 2>&1; then
  echo 'enrollment accepted multiple recovery identities' >&2
  exit 1
fi
grep -Fq 'recovery key must contain exactly one age identity' \
  "$test_root/multiple-recovery-output"
test ! -e "$journal"
test ! -e "$next_key"
rm -f -- "$common_git_dir/dotfiles-operation.lock"

# rebuild と共有する common-dir lock が取られている間は enrollment を開始しない。
lock_target=$test_root/lock-target
printf '%s\n' 'preserve-lock-target' > "$lock_target"
ln -s "$lock_target" "$common_git_dir/dotfiles-operation.lock"
if run_enroll status > "$test_root/enrollment-symlink-lock-output" 2>&1; then
  echo 'enrollment accepted a symlinked operation lock' >&2
  exit 1
fi
grep -Fq 'lock must be a regular file' "$test_root/enrollment-symlink-lock-output"
grep -Fqx 'preserve-lock-target' "$lock_target"
rm "$common_git_dir/dotfiles-operation.lock"

exec 7> "$common_git_dir/dotfiles-operation.lock"
chmod 0600 "$common_git_dir/dotfiles-operation.lock"
flock -n 7
if run_enroll status > "$test_root/enrollment-lock-output" 2>&1; then
  echo 'enrollment ignored the shared dotfiles operation lock' >&2
  exit 1
fi
grep -Fq 'another dotfiles state transition is running' "$test_root/enrollment-lock-output"
flock -u 7

# existing host は current/profile が同じ旧暗号文 generation に収束していなければ開始しない。
profile_target=$(readlink -f -- "$system_profile")
mismatched_target=$generation_root/store/mismatched-system
mkdir -p -- "$mismatched_target"
ln -sfn -- "$mismatched_target" "$current_system"
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id mismatched-generation > "$test_root/mismatched-generation-output" 2>&1; then
  echo 'prepare accepted different current and profile generations' >&2
  exit 1
fi
grep -Fq 'current system and system profile must converge before enrollment' \
  "$test_root/mismatched-generation-output"
test ! -e "$journal"
test ! -e "$next_key"
ln -sfn -- "$profile_target" "$current_system"

# current generation の contract/manifest が壊れていれば migration baseline にしない。
baseline_contract=$profile_target/etc/dotfiles/sops-generation.json
baseline_manifest=$(jq -r '.sopsManifest' "$baseline_contract")
saved_baseline_contract=$test_root/saved-baseline-contract.json
saved_baseline_manifest=$test_root/saved-baseline-manifest.json
cp -- "$baseline_contract" "$saved_baseline_contract"
cp -- "$baseline_manifest" "$saved_baseline_manifest"
for malformed_contract in missing-contract wrong-age-key wrong-ciphertext-hash; do
  case $malformed_contract in
    missing-contract)
      rm -f -- "$baseline_contract"
      ;;
    wrong-age-key)
      jq '.ageKeyFile = "/wrong/key.txt"' "$saved_baseline_manifest" > "$baseline_manifest"
      ;;
    wrong-ciphertext-hash)
      jq '.secrets[0].sopsFileHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
        "$saved_baseline_manifest" > "$baseline_manifest"
      ;;
  esac
  if run_enroll prepare \
    --recovery-key "$recovery_key" \
    --host-id "$malformed_contract" > "$test_root/$malformed_contract-output" 2>&1; then
    printf 'prepare accepted malformed current generation contract: %s\n' "$malformed_contract" >&2
    exit 1
  fi
  grep -Fq 'current generation has no valid SOPS generation contract' \
    "$test_root/$malformed_contract-output"
  cp -- "$saved_baseline_contract" "$baseline_contract"
  cp -- "$saved_baseline_manifest" "$baseline_manifest"
  test ! -e "$journal"
  test ! -e "$next_key"
done

prepare_output=$test_root/prepare-output
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id fixture-nixos > "$prepare_output"
grep -Fq 'PREPARED: fixture-nixos' "$prepare_output"
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml
test -f "$next_key"
test -f "$journal"

status_output=$test_root/status.json
run_enroll status > "$status_output"
test "$(jq -r '.state' "$status_output")" = prepared
test "$(jq -r '.hostId' "$status_output")" = fixture-nixos
host_recipient=$(jq -r '.nextRecipient' "$status_output")
test -n "$host_recipient"
test "$host_recipient" != "$recovery_recipient"

if run_enroll apply \
  --recovery-key "$recovery_key" > "$test_root/missing-yes-output" 2>&1; then
  echo 'apply accepted a transaction without --yes' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = prepared
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml

apply_output=$test_root/apply-output
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$apply_output"
grep -Fq 'PENDING: activate the prepared SOPS generation' "$apply_output"
test "$(jq -r '.state' < <(run_enroll status))" = generation-pending
test "$(jq -r '.phase' "$common_git_dir/dotfiles-sops-enroll/active.json")" = generation-pending
test "$("$age_keygen" -y "$active_key")" = "$recovery_recipient"
test "$("$age_keygen" -y "$next_key")" = "$host_recipient"
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$booted_generation_ciphertext" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$next_key "$sops" --decrypt "$encrypted" >/dev/null

# current/profile が新暗号文の generation を指すまでは、再実行しても鍵を昇格しない。
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/generation-still-pending-output"
grep -Fq 'PENDING: activate the prepared SOPS generation' \
  "$test_root/generation-still-pending-output"
test "$("$age_keygen" -y "$active_key")" = "$recovery_recipient"

activate_generation "$encrypted"
if SOPS_ENROLL_TEST_FAIL_AFTER_GENERATION_READY=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/generation-ready-interrupted-output" 2>&1; then
  echo 'generation-ready test hook did not interrupt before history closure' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = generation-ready
test "$(jq -r '.phase' "$common_git_dir/dotfiles-sops-enroll/active.json")" = generation-checking
test "$("$age_keygen" -y "$active_key")" = "$recovery_recipient"
test "$("$age_keygen" -y "$next_key")" = "$host_recipient"
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/generation-ready-output"
grep -Fq 'APPLIED: fixture-nixos' "$test_root/generation-ready-output"
grep -Fq 'closed incompatible system generations: 1' "$test_root/generation-ready-output"
test ! -e "$(dirname -- "$system_profile")/$(basename -- "$system_profile")-1-link"
test -e "$(dirname -- "$system_profile")/$(basename -- "$system_profile")-2-link"
grep -Fqx '2' "$installer_log"

test "$(yq -r '.keys.recovery' "$config")" = "$recovery_recipient"
test "$(yq -r '.keys.hosts["fixture-nixos"]' "$config")" = "$host_recipient"
test "$(yq -r '.creation_rules[].key_groups[0].age[]' "$config" | sort -u | wc -l)" -eq 2
diff --brief \
  <(yq -r '.creation_rules[].key_groups[0].age[]' "$config" | sort) \
  <(yq -r '.sops.age[].recipient' "$encrypted" | sort)
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null
test "$("$age_keygen" -y "$active_key")" = "$host_recipient"
test ! -e "$next_key"
test ! -e "$journal"
test -f "$receipt"
test "$(jq -r '.freshEnrollment' "$receipt")" = false
test "$(jq -r '.closedGenerations | length' "$receipt")" -eq 1
test "$(jq -r '.closedGenerations[0].generation' "$receipt")" -eq 1

# 完了 receipt は cleanup 再開の根拠なので、生成側が保証する契約を読み取り側でも検証する。
valid_receipt=$test_root/valid-migration-receipt.json
cp -- "$receipt" "$valid_receipt"
for invalid_receipt_case in \
  '.candidateSystem = null' \
  '.historyToClose = []' \
  '.closedGenerations[0].generation = 0' \
  '.closedGenerations[0].reason = ""' \
  '.startedAt = 0' \
  '.completedAt = null'; do
  invalid_receipt=$test_root/invalid-receipt.json
  jq "$invalid_receipt_case" "$valid_receipt" > "$invalid_receipt"
  chmod 0600 "$invalid_receipt"
  mv -f -- "$invalid_receipt" "$receipt"
  if run_enroll status > "$test_root/invalid-receipt-output" 2>&1; then
    echo "invalid enrollment receipt was accepted: $invalid_receipt_case" >&2
    exit 1
  fi
  grep -Fq 'enrollment receipt is invalid' "$test_root/invalid-receipt-output"
done
cp -- "$valid_receipt" "$receipt"
chmod 0600 "$receipt"

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm enrolled

# 同じ host id の上書きは enrollment ではなく rotation なので拒否する。
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id fixture-nixos > "$test_root/duplicate-host-output" 2>&1; then
  echo 'prepare overwrote an existing host recipient' >&2
  exit 1
fi
grep -Fq 'host id is already enrolled' "$test_root/duplicate-host-output"
test ! -e "$journal"
test ! -e "$next_key"

# 同じ current host identity を別 ID で再登録する操作も rotation なので拒否する。
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id renamed-fixture > "$test_root/renamed-host-output" 2>&1; then
  echo 'prepare enrolled the current host identity under another host id' >&2
  exit 1
fi
grep -Fq 'current host identity is already enrolled as fixture-nixos' \
  "$test_root/renamed-host-output"
test ! -e "$journal"
test ! -e "$next_key"

# 現在の暗号文を復号できない recovery identity では root 側の staging を始めない。
if run_enroll prepare \
  --recovery-key "$wrong_recovery_key" \
  --host-id wrong-recovery > "$test_root/wrong-recovery-output" 2>&1; then
  echo 'prepare accepted an unrelated recovery identity' >&2
  exit 1
fi
grep -Fq 'recovery identity cannot decrypt the current ciphertext' "$test_root/wrong-recovery-output"
test ! -e "$journal"
test ! -e "$next_key"

# recovery は正しくても current identity が recipient model 外なら staging 前に中止する。
use_key_dir broken-current
cp "$wrong_recovery_key" "$active_key"
chmod 0400 "$active_key"
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id broken-current > "$test_root/broken-current-output" 2>&1; then
  echo 'prepare accepted a current host identity that could not decrypt' >&2
  exit 1
fi
grep -Fq 'current host identity is neither recovery nor an enrolled host' \
  "$test_root/broken-current-output"
test ! -e "$journal"
test ! -e "$next_key"

# managed generation があるのに active key がない壊れた既存ホストを fresh と誤認しない。
use_key_dir missing-active-key
activate_generation "$encrypted"
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id missing-active-key > "$test_root/missing-active-key-output" 2>&1; then
  echo 'prepare treated a managed host without key.txt as a fresh host' >&2
  exit 1
fi
grep -Fq 'managed SOPS generation exists but the active host key is missing' \
  "$test_root/missing-active-key-output"
test ! -e "$journal"
test ! -e "$next_key"

# candidate を next key で復号できなければ、staging と candidate を取り消す。
use_key_dir failed-next
if SOPS_ENROLL_TEST_FAIL_VERIFY_NEXT=1 run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id failed-next > "$test_root/next-failure-output" 2>&1; then
  echo 'prepare accepted a candidate that next key could not decrypt' >&2
  exit 1
fi
test ! -e "$journal"
test ! -e "$next_key"
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml

# candidate 更新後、hash を marker に記録する前の停止では未知の候補を削除しない。
use_key_dir unrecorded-staged-candidate
if SOPS_ENROLL_TEST_FAIL_BEFORE_CANDIDATE_HASH_MARKER=1 run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id unrecorded-staged-candidate > "$test_root/unrecorded-staged-output" 2>&1; then
  echo 'prepare ignored failure before recording the candidate hash' >&2
  exit 1
fi
grep -Fq 'unrecorded transaction content changed; preserved at' \
  "$test_root/unrecorded-staged-output"
test ! -e "$journal"
test ! -e "$next_key"
unrecorded_marker=$common_git_dir/dotfiles-sops-enroll/active.json
unrecorded_transaction=$(jq -r '.transactionId' "$unrecorded_marker")
unrecorded_candidate=$common_git_dir/dotfiles-sops-enroll/$unrecorded_transaction/secrets
test "$(jq -r '.newConfigHash // ""' "$unrecorded_marker")" = ""
test -d "$unrecorded_candidate"
if run_enroll abort > "$test_root/unrecorded-staged-abort-output" 2>&1; then
  echo 'abort deleted a candidate whose hash was never recorded' >&2
  exit 1
fi
grep -Fq "unrecorded transaction content changed; preserved at $unrecorded_candidate" \
  "$test_root/unrecorded-staged-abort-output"
cp -- "$config" "$unrecorded_candidate/.sops.yaml"
cp -- "$encrypted" "$unrecorded_candidate/secrets.yaml"
run_enroll abort > "$test_root/unrecorded-staged-cleanup-output"
grep -Fq 'recovered cleanup after completed root abort' \
  "$test_root/unrecorded-staged-cleanup-output"
test ! -e "$unrecorded_marker"

# candidate の hash 記録後に並行変更が入った場合は、root staging だけを戻して内容を保全する。
use_key_dir changed-staged-candidate
if SOPS_ENROLL_TEST_MUTATE_CANDIDATE_BEFORE_ROOT_PREPARE=1 run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id changed-staged-candidate > "$test_root/changed-staged-candidate-output" 2>&1; then
  echo 'prepare accepted a candidate changed before root prepare' >&2
  exit 1
fi
grep -Fq 'prepared candidate changed before root journal update' \
  "$test_root/changed-staged-candidate-output"
test ! -e "$journal"
test ! -e "$next_key"
changed_staged_marker=$common_git_dir/dotfiles-sops-enroll/active.json
changed_staged_transaction=$(jq -r '.transactionId' "$changed_staged_marker")
changed_staged_candidate=$common_git_dir/dotfiles-sops-enroll/$changed_staged_transaction/secrets
grep -Fq '# concurrent staged candidate edit' "$changed_staged_candidate/.sops.yaml"
if run_enroll abort > "$test_root/changed-staged-abort-output" 2>&1; then
  echo 'abort deleted a changed staged candidate' >&2
  exit 1
fi
grep -Fq "transaction backup changed; preserved at $changed_staged_candidate" \
  "$test_root/changed-staged-abort-output"
sed -i '$d' "$changed_staged_candidate/.sops.yaml"
run_enroll abort > "$test_root/changed-staged-cleanup-output"
grep -Fq 'recovered cleanup after completed root abort' \
  "$test_root/changed-staged-cleanup-output"
test ! -e "$changed_staged_marker"

# key staging 後、journal 作成前の停止は orphan として観測し、明示的に破棄する。
use_key_dir orphaned-next
if SOPS_ENROLL_TEST_FAIL_AFTER_KEY_STAGE=1 run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id orphaned-next > "$test_root/orphan-output" 2>&1; then
  echo 'prepare test hook did not interrupt after key staging' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = orphaned-next
run_enroll abort > "$test_root/orphan-abort-output"
grep -Fq 'ABORTED: orphaned key.next' "$test_root/orphan-abort-output"
test ! -e "$journal"
test ! -e "$next_key"

# swap intent 記録後は repository 交換前でも abort せず、apply で前進復旧する。
use_key_dir swap-intent-host
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id swap-intent-nixos > /dev/null
swap_intent_transaction=$(jq -r '.transactionId' < <(run_enroll status))
swap_intent_candidate=$common_git_dir/dotfiles-sops-enroll/$swap_intent_transaction/secrets
swap_intent_config=$test_root/swap-intent-config.yaml
cp -- "$config" "$swap_intent_config"
if SOPS_ENROLL_TEST_MUTATE_BEFORE_REPO_SWAP=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/swap-intent-output" 2>&1; then
  echo 'apply exchanged repository files that changed immediately before swap' >&2
  exit 1
fi
grep -Fq 'repository SOPS files changed immediately before exchange' \
  "$test_root/swap-intent-output"
test "$(jq -r '.state' < <(run_enroll status))" = swap-intent
grep -Fq '# concurrent worktree edit' "$config"
test -d "$swap_intent_candidate"
cp -- "$swap_intent_config" "$config"
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml
if run_enroll abort > "$test_root/swap-intent-abort-output" 2>&1; then
  echo 'abort reopened a transaction after swap intent' >&2
  exit 1
fi
grep -Fq 'only a staged, prepared, or orphaned-next transaction can be aborted' \
  "$test_root/swap-intent-abort-output"
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/swap-intent-resumed-output"
grep -Fq 'APPLIED: swap-intent-nixos' "$test_root/swap-intent-resumed-output"

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm swap-intent-resumed

# directory exchange 後、journal 更新前に停止しても hash 観測から前進復旧する。
use_key_dir resumed-host
linked_worktree=$test_root/linked-worktree
git -C "$dotfiles" worktree add --quiet --detach "$linked_worktree" HEAD
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id resumed-nixos > /dev/null
if run_enroll_at "$linked_worktree" status > "$test_root/linked-status-output" 2>&1; then
  echo 'a linked worktree accessed the configured worktree enrollment' >&2
  exit 1
fi
grep -Fq 'enrollment is restricted to the configured dotfiles worktree' \
  "$test_root/linked-status-output"
if run_enroll_at "$linked_worktree" abort > "$test_root/linked-abort-output" 2>&1; then
  echo 'a linked worktree aborted another worktree transaction' >&2
  exit 1
fi
grep -Fq 'enrollment is restricted to the configured dotfiles worktree' \
  "$test_root/linked-abort-output"
test "$(jq -r '.state' < <(run_enroll status))" = prepared
resumed_transaction=$(jq -r '.transactionId' < <(run_enroll status))
resumed_candidate=$common_git_dir/dotfiles-sops-enroll/$resumed_transaction/secrets
resumed_old_config=$test_root/resumed-old-config.yaml
cp -- "$config" "$resumed_old_config"
if SOPS_ENROLL_TEST_MUTATE_BACKUP_AFTER_REPO_SWAP=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/interrupted-output" 2>&1; then
  echo 'apply accepted a repository backup changed immediately after swap' >&2
  exit 1
fi
grep -Fq 'repository backup changed after exchange' "$test_root/interrupted-output"
test "$(jq -r '.state' < <(run_enroll status))" = swap-intent
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
grep -Fq '# concurrent backup edit' "$resumed_candidate/.sops.yaml"
cp -- "$resumed_old_config" "$resumed_candidate/.sops.yaml"

run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/resumed-output"
grep -Fq 'APPLIED: resumed-nixos' "$test_root/resumed-output"
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null
test ! -e "$journal"
test ! -e "$next_key"

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm resumed

# generation 削除後、journal 更新前に停止しても、旧鍵を保持したまま残存世代を再観測して完了する。
use_migration_key_dir history-crash-host
activate_generation "$encrypted"
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id history-crash-nixos > /dev/null
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/history-crash-pending-output"
old_history_contract=$(readlink -f -- "$system_profile")/etc/dotfiles/sops-generation.json
rm -f -- "$old_history_contract"
activate_generation "$encrypted"
if SOPS_ENROLL_TEST_NIX_ENV_FAIL_AFTER_DELETE=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/history-crash-output" 2>&1; then
  echo 'history-close test hook did not interrupt after generation deletion' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = history-close-intent
test "$("$age_keygen" -y "$active_key")" = "$recovery_recipient"
test "$(find "$(dirname -- "$system_profile")" -maxdepth 1 -type l \
  -name "$(basename -- "$system_profile")-[0-9]*-link" | wc -l)" -eq 1
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/history-crash-resumed-output"
grep -Fq 'APPLIED: history-crash-nixos' "$test_root/history-crash-resumed-output"
test "$(jq -r '.closedGenerations | length' "$receipt")" -eq 1
test "$(jq -r '.closedGenerations[0].reason' "$receipt")" = missing-or-invalid-contract

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm history-crash-resumed

# key exchange 後、journal 更新前の停止も recipient 観測から再開する。
use_migration_key_dir key-swap-host
activate_generation "$encrypted"
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id key-swap-nixos > /dev/null
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/key-swap-pending-output"
grep -Fq 'PENDING: activate the prepared SOPS generation' \
  "$test_root/key-swap-pending-output"
activate_generation "$encrypted"
if SOPS_ENROLL_TEST_FAIL_AFTER_KEY_SWAP=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/key-swap-output" 2>&1; then
  echo 'apply test hook did not interrupt after the key exchange' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = history-closed
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/key-swap-resumed-output"
grep -Fq 'APPLIED: key-swap-nixos' "$test_root/key-swap-resumed-output"
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm key-swap-resumed

# 旧 key 削除後、receipt 書込み前の停止は verified journal から完了する。
use_migration_key_dir old-key-delete-host
activate_generation "$encrypted"
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id old-key-delete-nixos > /dev/null
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/old-key-delete-pending-output"
activate_generation "$encrypted"
if SOPS_ENROLL_TEST_FAIL_AFTER_OLD_KEY_DELETE=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/old-key-delete-output" 2>&1; then
  echo 'old-key deletion hook did not interrupt before receipt creation' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = verified
test ! -e "$next_key"
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/old-key-delete-resumed-output"
grep -Fq 'APPLIED: old-key-delete-nixos' "$test_root/old-key-delete-resumed-output"
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm old-key-delete-resumed

# root finalize 後、worktree backup 削除前の停止は receipt から cleanup を完了する。
use_key_dir finalized-host
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id finalized-nixos > /dev/null
if SOPS_ENROLL_TEST_FAIL_AFTER_FINALIZE=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/finalize-output" 2>&1; then
  echo 'apply test hook did not interrupt after root finalization' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = idle
finalized_transaction=$(jq -r '.transactionId' "$receipt")
finalized_candidate=$common_git_dir/dotfiles-sops-enroll/$finalized_transaction/secrets
finalized_backup=$test_root/finalized-backup.yaml
cp -- "$finalized_candidate/.sops.yaml" "$finalized_backup"
printf '\n# edit retained during receipt cleanup\n' >> "$finalized_candidate/.sops.yaml"
if run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/finalize-backup-output" 2>&1; then
  echo 'receipt cleanup deleted a changed repository backup' >&2
  exit 1
fi
grep -Fq "transaction backup changed; preserved at $finalized_candidate" \
  "$test_root/finalize-backup-output"
grep -Fq '# edit retained during receipt cleanup' "$finalized_candidate/.sops.yaml"
cp -- "$finalized_backup" "$finalized_candidate/.sops.yaml"
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/finalize-resumed-output"
grep -Fq 'recovered cleanup after completed root finalization' "$test_root/finalize-resumed-output"
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm finalized-resumed

# active key がない fresh host でも、promotion 後の停止を current recipient から再開する。
use_key_dir fresh-host
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id fresh-nixos > /dev/null
if SOPS_ENROLL_TEST_FAIL_AFTER_KEY_SWAP=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/fresh-key-swap-output" 2>&1; then
  echo 'fresh-host apply test hook did not interrupt after key promotion' >&2
  exit 1
fi
fresh_status=$(run_enroll status)
test "$(jq -r '.state' <<< "$fresh_status")" = repo-swapped
test "$(jq -r '.currentRecipient' <<< "$fresh_status")" = "$(jq -r '.nextRecipient' <<< "$fresh_status")"
test "$(jq -r '.stagedRecipient // ""' <<< "$fresh_status")" = ""
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/fresh-resumed-output"
grep -Fq 'APPLIED: fresh-nixos' "$test_root/fresh-resumed-output"
test "$(jq -r '.freshEnrollment' "$receipt")" = true
SOPS_AGE_KEY_FILE=$recovery_key "$sops" --decrypt "$encrypted" >/dev/null
SOPS_AGE_KEY_FILE=$active_key "$sops" --decrypt "$encrypted" >/dev/null

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm fresh-resumed

# verified 後に active ciphertext が変われば、旧 key を削除せず停止する。
use_migration_key_dir verified-hash-host
activate_generation "$encrypted"
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id verified-hash-nixos > /dev/null
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/verified-pending-output"
grep -Fq 'PENDING: activate the prepared SOPS generation' \
  "$test_root/verified-pending-output"
activate_generation "$encrypted"
if SOPS_ENROLL_TEST_FAIL_AFTER_MARK_VERIFIED=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/verified-hook-output" 2>&1; then
  echo 'apply test hook did not interrupt after mark-verified' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = verified
test "$("$age_keygen" -y "$next_key")" = "$recovery_recipient"

# verified 後でも profile history を再観測し、非互換世代が増えていれば旧鍵を削除しない。
verified_system_target=$(readlink -f -- "$system_profile")
verified_profile_link=$(readlink -- "$system_profile")
activate_generation "$booted_generation_ciphertext"
incompatible_profile_link=$(readlink -- "$system_profile")
ln -sfn -- "$verified_profile_link" "$system_profile"
ln -sfn -- "$verified_system_target" "$current_system"
if run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/finalize-history-output" 2>&1; then
  echo 'apply deleted the old key with an incompatible rollback generation present' >&2
  exit 1
fi
grep -Fq 'an incompatible system generation blocks old-key deletion' \
  "$test_root/finalize-history-output"
test -e "$journal"
test "$("$age_keygen" -y "$next_key")" = "$recovery_recipient"
rm -f -- "$(dirname -- "$system_profile")/$incompatible_profile_link"

expected_verified_ciphertext=$test_root/expected-verified-secrets.yaml
cp "$encrypted" "$expected_verified_ciphertext"
SOPS_AGE_KEY_FILE=$recovery_key "$sops" set \
  "$encrypted" '["fixture"]' '"changed-after-verification"'
chmod 0644 "$encrypted"
if run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/verified-hash-output" 2>&1; then
  echo 'apply finalized ciphertext that changed after verification' >&2
  exit 1
fi
grep -Fq 'repository SOPS hashes match neither side of the prepared transaction' \
  "$test_root/verified-hash-output"
test -e "$journal"
test "$("$age_keygen" -y "$next_key")" = "$recovery_recipient"
cp "$expected_verified_ciphertext" "$encrypted"
if SOPS_ENROLL_TEST_MUTATE_BEFORE_FINAL_HASH=1 run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/final-hash-output" 2>&1; then
  echo 'apply finalized ciphertext that changed after its last decryption' >&2
  exit 1
fi
grep -Fq 'active SOPS files changed after verification' "$test_root/final-hash-output"
test -e "$journal"
test "$("$age_keygen" -y "$next_key")" = "$recovery_recipient"
cp "$expected_verified_ciphertext" "$encrypted"
run_enroll apply \
  --recovery-key "$recovery_key" \
  --yes > "$test_root/verified-hash-resumed-output"
grep -Fq 'APPLIED: verified-hash-nixos' "$test_root/verified-hash-resumed-output"
test ! -e "$next_key"

git -C "$dotfiles" add --force secrets/.sops.yaml secrets/secrets.yaml
git -C "$dotfiles" commit -qm verified-hash-resumed

# prepared までは明示的に abort でき、tracked file と root state の双方を戻せる。
use_key_dir aborted-host
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id aborted-nixos > /dev/null
run_enroll abort > "$test_root/abort-output"
grep -Fq 'ABORTED: aborted-nixos' "$test_root/abort-output"
test ! -e "$journal"
test ! -e "$next_key"
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml

# root abort 後に停止しても、残った user transaction は次の abort で回収する。
use_key_dir abort-cleanup-host
run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id abort-cleanup-nixos > /dev/null
if SOPS_ENROLL_TEST_FAIL_AFTER_ROOT_ABORT=1 run_enroll abort \
  > "$test_root/abort-cleanup-hook-output" 2>&1; then
  echo 'abort test hook did not interrupt after root abort' >&2
  exit 1
fi
test "$(jq -r '.state' < <(run_enroll status))" = idle
active_marker=$common_git_dir/dotfiles-sops-enroll/active.json
saved_active_marker=$test_root/saved-active-marker.json
cp "$active_marker" "$saved_active_marker"
jq '.transactionId = ".."' "$saved_active_marker" > "$active_marker"
chmod 0600 "$active_marker"
if run_enroll abort > "$test_root/invalid-marker-output" 2>&1; then
  echo 'abort accepted a transaction marker with a path traversal id' >&2
  exit 1
fi
grep -Fq 'user transaction marker is invalid' "$test_root/invalid-marker-output"
test -d "$common_git_dir/objects"
cp "$saved_active_marker" "$active_marker"
chmod 0600 "$active_marker"
run_enroll abort > "$test_root/abort-cleanup-resumed-output"
grep -Fq 'recovered cleanup after completed root abort' "$test_root/abort-cleanup-resumed-output"
test ! -e "$journal"
test ! -e "$next_key"
git -C "$dotfiles" diff --quiet HEAD -- secrets/.sops.yaml secrets/secrets.yaml

printf '%s\n' '# dirty target' >> "$config"
if run_enroll prepare \
  --recovery-key "$recovery_key" \
  --host-id dirty-target > "$test_root/dirty-output" 2>&1; then
  echo 'prepare accepted dirty target files' >&2
  exit 1
fi
grep -Fq 'the entire worktree must be clean before enrollment' "$test_root/dirty-output"
test ! -e "$journal"
test ! -e "$next_key"
