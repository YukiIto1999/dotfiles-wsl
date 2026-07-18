#!/usr/bin/env bash
set -euo pipefail

allow_test_hooks=@allowTestHooks@
if (( allow_test_hooks == 1 )); then
  key_dir=${SOPS_ENROLL_TEST_KEY_DIR:?SOPS_ENROLL_TEST_KEY_DIR is required by the test build}
  current_system=${SOPS_ENROLL_TEST_CURRENT_SYSTEM:-/nonexistent/current-system}
  system_profile=${SOPS_ENROLL_TEST_SYSTEM_PROFILE:-/nonexistent/system-profile}
  nix_env=${SOPS_ENROLL_TEST_NIX_ENV:-false}
  expected_uid=$EUID
else
  key_dir=@sopsKeyDirectory@
  current_system=/run/current-system
  system_profile=/nix/var/nix/profiles/system
  nix_env=@nixEnv@
  expected_uid=0
  if (( EUID != 0 )); then
    echo 'dotfiles-sops-keyctl must run as root' >&2
    exit 2
  fi
fi

active_key=$key_dir/key.txt
next_key=$key_dir/key.next
journal=$key_dir/enrollment.json
receipt=$key_dir/enrollment-receipt.json
lock_file=$key_dir/enrollment.lock
sops_runtime_path=@sopsRuntimePath@
sops_verifier=@sopsVerifier@
systemd_run=@systemdRun@

die() {
  printf 'dotfiles-sops-keyctl: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  dotfiles-sops-keyctl stage|status|verify-installed|abort-orphan
  dotfiles-sops-keyctl TRANSACTION-OPERATION TRANSACTION-ID

Operations:
  stage               stage a new host identity and start a transaction
  status              print the observed transaction state as JSON
  validate-fresh      reject a managed generation whose active key is missing
  verify-next ID      decrypt stdin with key.next
  verify-previous     decrypt stdin with key.txt before promotion
  prepare             record candidate hashes from a JSON object on stdin
  arm-swap            close the abort path before repository exchange
  mark-repo-swapped   record that the repository directory was exchanged
  mark-generation-pending
                       retain the previous key until a compatible generation is active
  advance-generation  verify current/profile and both identities against the new generation
  arm-history-close   record incompatible system generations before deletion
  close-history       delete the recorded incompatible generations and verify the remainder
  promote             exchange key.txt and key.next
  verify-current      decrypt stdin with key.txt
  reinstall-current   run the current generation's exact sops-nix installer
  verify-installed    decrypt stdin with the key recorded by the last receipt
  mark-verified       record recovery and current-key verification
  finalize            remove the previous key and retain a receipt
  abort ID            discard the named transaction before repository exchange
  abort-orphan        discard key.next only when no journal exists
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
operation=$1
transaction_id_argument=
baseline_hash_argument=
case $operation in
  stage | status | validate-fresh | verify-installed | abort-orphan)
    [[ $# -eq 1 ]] || usage
    ;;
  validate-baseline)
    [[ $# -eq 2 && $2 =~ ^[0-9a-f]{64}$ ]] || usage
    baseline_hash_argument=$2
    ;;
  verify-next | verify-previous | prepare | arm-swap | mark-repo-swapped | mark-generation-pending | advance-generation | arm-history-close | close-history | promote | verify-current | reinstall-current | mark-verified | finalize | abort)
    [[ $# -eq 2 && $2 =~ ^[0-9a-f]{32}$ ]] || usage
    transaction_id_argument=$2
    ;;
  *) usage ;;
esac

ensure_key_dir() {
  if [[ ! -e $key_dir ]]; then
    [[ $operation == stage || $operation == validate-fresh ]] || die 'key directory does not exist'
    install -d -m 0700 -- "$key_dir"
    if (( allow_test_hooks != 1 )); then
      chown 0:0 -- "$key_dir"
    fi
  fi

  [[ ! -L $key_dir && -d $key_dir ]] || die 'key directory must be a real directory'
  local metadata
  metadata=$(stat -c '%u|%a' -- "$key_dir")
  [[ $metadata == "$expected_uid|700" ]] || die 'key directory must have the expected owner and mode 0700'
}

validate_file() {
  local path=$1 mode=$2 label=$3 metadata
  [[ ! -L $path && -f $path ]] || die "$label must be a regular file"
  metadata=$(stat -c '%u|%a|%h' -- "$path")
  [[ $metadata == "$expected_uid|$mode|1" ]] || die "$label has invalid owner, mode, or link count"
}

recipient_of() {
  local path=$1 recipient
  recipient=$(age-keygen -y "$path") || die "${path##*/} is not a valid age identity"
  [[ $recipient != *$'\n'* && $recipient =~ ^age1[0-9a-z]+$ ]] || \
    die "${path##*/} must contain exactly one age identity"
  printf '%s\n' "$recipient"
}

write_json_file() {
  local target=$1 mode=$2
  local temporary
  temporary=$(mktemp "$key_dir/.write.XXXXXX")
  trap 'rm -f -- "$temporary"' RETURN
  cat > "$temporary"
  chmod "$mode" "$temporary"
  if (( allow_test_hooks != 1 )); then
    chown 0:0 -- "$temporary"
  fi
  sync -d "$temporary"
  mv -fT -- "$temporary" "$target"
  sync -f "$key_dir"
  trap - RETURN
}

read_journal() {
  [[ -e $journal ]] || die 'no active enrollment transaction'
  validate_file "$journal" 600 'enrollment journal'
  jq -e '
    .version == 1 and
    (.transactionId | type == "string" and test("^[0-9a-f]{32}$")) and
    (.state | IN("staged", "prepared", "swap-intent", "repo-swapped", "generation-pending",
      "generation-ready", "history-close-intent", "history-closed", "key-promoted", "verified")) and
    (.hostId == null or (.hostId | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))) and
    (.previousRecipient == null or (.previousRecipient | type == "string" and startswith("age1"))) and
    (.nextRecipient | type == "string" and startswith("age1")) and
    (.startedAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    all(.oldConfigHash, .oldSecretsHash, .newConfigHash, .newSecretsHash;
      . == null or (type == "string" and test("^[0-9a-f]{64}$"))) and
    (.candidateSystem == null or (.candidateSystem | type == "string" and startswith("/"))) and
    (.historyToClose == null or (.historyToClose | type == "array")) and
    (.closedGenerations | type == "array") and
    all(((.historyToClose // []) + .closedGenerations)[];
      (.generation | type == "number" and . > 0 and floor == .) and
      (.system | type == "string" and startswith("/")) and
      (.reason | type == "string" and length > 0)) and
    (if .state == "staged" then
       .hostId == null and .oldConfigHash == null and .historyToClose == null
     else
       .hostId != null and all(.oldConfigHash, .oldSecretsHash, .newConfigHash, .newSecretsHash;
         type == "string")
     end)
  ' "$journal" >/dev/null || die 'enrollment journal is invalid'
  if [[ -n $transaction_id_argument ]]; then
    [[ $(jq -r '.transactionId' "$journal") == "$transaction_id_argument" ]] || \
      die 'transaction id does not match the active enrollment journal'
  fi
}

read_receipt() {
  validate_file "$receipt" 600 'enrollment receipt'
  jq -e '
    .version == 1 and
    .state == "complete" and
    (.transactionId | type == "string" and test("^[0-9a-f]{32}$")) and
    (.hostId | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
    (.previousRecipient == null or (.previousRecipient | type == "string" and startswith("age1"))) and
    (.nextRecipient | type == "string" and startswith("age1")) and
    (.freshEnrollment | type == "boolean") and
    (.freshEnrollment == (.previousRecipient == null)) and
    (.startedAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.completedAt | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    .completedAt >= .startedAt and
    .historyToClose == null and
    (.closedGenerations | type == "array") and
    all(.closedGenerations[];
      (.generation | type == "number" and . > 0 and floor == .) and
      (.system | type == "string" and startswith("/")) and
      (.reason | type == "string" and length > 0)) and
    (if .freshEnrollment then
       .candidateSystem == null and (.closedGenerations | length) == 0
     else
       (.candidateSystem | type == "string" and startswith("/"))
     end) and
    all(.oldConfigHash, .oldSecretsHash, .newConfigHash, .newSecretsHash;
      type == "string" and test("^[0-9a-f]{64}$"))
  ' "$receipt" >/dev/null || die 'enrollment receipt is invalid'
}

journal_state() {
  jq -r '.state' "$journal"
}

require_state() {
  local expected=$1 actual
  actual=$(journal_state)
  [[ $actual == "$expected" ]] || die "operation requires state $expected; observed $actual"
}

write_updated_journal() {
  local filter=$1
  shift
  jq "$@" "$filter" "$journal" | write_json_file "$journal" 0600
}

observed_recipient() {
  local path=$1
  if [[ -e $path ]]; then
    validate_file "$path" 400 "${path##*/}"
    recipient_of "$path"
  fi
}

print_status() {
  local current_recipient next_recipient
  current_recipient=$(observed_recipient "$active_key")
  if [[ ! -e $journal ]]; then
    if [[ -e $next_key ]]; then
      validate_file "$next_key" 400 'orphaned key.next'
      jq -n \
        --arg current "$current_recipient" \
        --arg staged "$(recipient_of "$next_key")" \
        '{state: "orphaned-next",
          currentRecipient: (if $current == "" then null else $current end),
          stagedRecipient: $staged}'
      return
    fi
    if [[ -e $receipt ]]; then
      read_receipt
      jq --arg current "$current_recipient" \
        '{state: "idle",
          currentRecipient: (if $current == "" then null else $current end),
          lastReceipt: .}' "$receipt"
    else
      jq -n --arg current "$current_recipient" \
        '{state: "idle",
          currentRecipient: (if $current == "" then null else $current end),
          lastReceipt: null}'
    fi
    return
  fi

  read_journal
  next_recipient=$(observed_recipient "$next_key")
  jq \
    --arg current "$current_recipient" \
    --arg next "$next_recipient" \
    '. + {
      currentRecipient: (if $current == "" then null else $current end),
      stagedRecipient: (if $next == "" then null else $next end)
    }' "$journal"
}

verify_ciphertext() {
  local key=$1
  if (( allow_test_hooks == 1 )); then
    env -i \
      HOME=/root \
      PATH="$sops_runtime_path" \
      SOPS_AGE_KEY_FILE="$key" \
      sops decrypt \
        --input-type yaml \
        --filename-override secrets.yaml >/dev/null
    return
  fi

  "$systemd_run" \
    --quiet \
    --wait \
    --pipe \
    --collect \
    --service-type=exec \
    --property=DynamicUser=yes \
    --property=PrivateNetwork=yes \
    --property=PrivateTmp=yes \
    --property=PrivateDevices=yes \
    --property=NoNewPrivileges=yes \
    --property=ProtectSystem=strict \
    --property=ProtectHome=yes \
    --property=RestrictAddressFamilies=AF_UNIX \
    --property="LoadCredential=age.key:$key" \
    "$sops_verifier"
}

hash_file() {
  sha256sum "$1" | cut -d ' ' -f 1
}

load_generation_contract() {
  local system_path=$1 contract resolved_contract
  contract=$system_path/etc/dotfiles/sops-generation.json
  [[ -f $contract ]] || return 1
  resolved_contract=$(realpath -e -- "$contract") || return 1
  if (( allow_test_hooks != 1 )); then
    [[ $resolved_contract == /nix/store/* ]] || return 1
  fi
  jq -e '
    .schemaVersion == 1 and
    (.ciphertext.path | type == "string" and startswith("/")) and
    (.ciphertext.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.sopsManifest | type == "string" and startswith("/")) and
    (.reinstallSecrets | type == "string" and startswith("/"))
  ' "$contract" >/dev/null || return 1
  generation_ciphertext=$(jq -r '.ciphertext.path' "$contract")
  generation_ciphertext_hash=$(jq -r '.ciphertext.sha256' "$contract")
  generation_sops_manifest=$(jq -r '.sopsManifest' "$contract")
  generation_installer=$(jq -r '.reinstallSecrets' "$contract")
  [[ -f $generation_ciphertext && -f $generation_sops_manifest && -x $generation_installer ]] || return 1
  if (( allow_test_hooks != 1 )); then
    [[ $generation_ciphertext == /nix/store/* && $generation_sops_manifest == /nix/store/* &&
      $generation_installer == /nix/store/* ]] || return 1
  fi
  [[ $(hash_file "$generation_ciphertext") == "$generation_ciphertext_hash" ]] || return 1
  # shellcheck disable=SC2016 # ageKeyFile and ciphertext fields are jq variables.
  jq -e \
    --arg ageKeyFile "$active_key" \
    --arg ciphertext "$generation_ciphertext" \
    --arg ciphertextHash "$generation_ciphertext_hash" '
      .ageKeyFile == $ageKeyFile and
      (.secrets | type == "array" and length > 0) and
      all(.secrets[]; .sopsFile == $ciphertext and .sopsFileHash == $ciphertextHash)
    ' "$generation_sops_manifest" >/dev/null || return 1
}

observe_converged_generation() {
  local expected_hash=$1
  generation_pending_reason=
  generation_current_target=$(realpath -e -- "$current_system" 2>/dev/null) || {
    generation_pending_reason='current system does not resolve to a generation'
    return 1
  }
  generation_profile_target=$(realpath -e -- "$system_profile" 2>/dev/null) || {
    generation_pending_reason='system profile does not resolve to a generation'
    return 1
  }
  if [[ $generation_current_target != "$generation_profile_target" ]]; then
    generation_pending_reason='current system and system profile have not converged'
    return 1
  fi
  if ! load_generation_contract "$generation_current_target"; then
    generation_pending_reason='current generation has no valid SOPS generation contract'
    return 1
  fi
  if [[ $generation_ciphertext_hash != "$expected_hash" ]]; then
    generation_pending_reason='current generation still references a different SOPS ciphertext'
    return 1
  fi
}

verify_generation_with_both_keys() {
  local expected_hash=$1 expected_previous
  observe_converged_generation "$expected_hash" || return 1
  expected_previous=$(jq -r '.previousRecipient // ""' "$journal")
  [[ -n $expected_previous ]] || die 'generation barrier requires a previous identity'
  validate_file "$active_key" 400 'key.txt'
  validate_file "$next_key" 400 'key.next'
  [[ $(recipient_of "$active_key") == "$expected_previous" ]] || \
    die 'current key changed before the generation barrier closed'
  [[ $(recipient_of "$next_key") == "$(jq -r '.nextRecipient' "$journal")" ]] || \
    die 'staged key changed before the generation barrier closed'
  verify_ciphertext "$active_key" < "$generation_ciphertext" || \
    die 'previous key cannot decrypt the current generation ciphertext'
  verify_ciphertext "$next_key" < "$generation_ciphertext" || \
    die 'staged key cannot decrypt the current generation ciphertext'
}

collect_incompatible_generations() {
  local expected_hash=$1 verification_key=${2:-$next_key}
  local profile_dir profile_name link link_name generation target reason
  local observations='[]' incompatible='[]'
  profile_dir=$(dirname -- "$system_profile")
  profile_name=$(basename -- "$system_profile")
  shopt -s nullglob
  local links=("$profile_dir/$profile_name"-[0-9]*-link)
  shopt -u nullglob
  (( ${#links[@]} > 0 )) || die 'system profile has no generations'

  for link in "${links[@]}"; do
    [[ -L $link ]] || die 'system generation entry must be a symbolic link'
    link_name=${link##*/}
    [[ $link_name =~ ^${profile_name}-([0-9]+)-link$ ]] || \
      die 'system generation entry has an invalid name'
    generation=${BASH_REMATCH[1]}
    target=$(realpath -e -- "$link") || die 'system generation target does not exist'
    reason=
    if ! load_generation_contract "$target"; then
      reason='missing-or-invalid-contract'
    elif [[ $generation_ciphertext_hash != "$expected_hash" ]]; then
      reason='different-ciphertext'
    elif ! verify_ciphertext "$verification_key" < "$generation_ciphertext" >/dev/null 2>&1; then
      reason='staged-key-cannot-decrypt'
    fi
    entry=$(jq -n \
      --argjson generation "$generation" \
      --arg system "$target" \
      --arg reason "$reason" \
      '{generation: $generation, system: $system,
        compatible: ($reason == ""), reason: (if $reason == "" then null else $reason end)}')
    observations=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$observations")
    if [[ -n $reason ]]; then
      incompatible=$(jq -c --argjson entry "$entry" '. + [$entry | del(.compatible)]' <<< "$incompatible")
    fi
  done
  generation_observations=$observations
  generation_incompatible=$incompatible
}

if [[ $operation == status && ! -e $key_dir ]]; then
  printf '%s\n' '{"state":"idle","currentRecipient":null,"lastReceipt":null}'
  exit 0
fi

ensure_key_dir
umask 077
exec 9> "$lock_file"
chmod 0600 "$lock_file"
if (( allow_test_hooks != 1 )); then
  chown 0:0 -- "$lock_file"
fi
flock -x 9

case $operation in
  validate-fresh)
    [[ ! -e $active_key && ! -L $active_key ]] || \
      die 'fresh-host validation requires no active key'
    if current_target=$(realpath -e -- "$current_system" 2>/dev/null); then
      [[ ! -e $current_target/etc/dotfiles/sops-generation.json ]] || \
        die 'managed SOPS generation exists but the active host key is missing'
    fi
    if profile_target=$(realpath -e -- "$system_profile" 2>/dev/null); then
      [[ ! -e $profile_target/etc/dotfiles/sops-generation.json ]] || \
        die 'managed SOPS generation exists but the active host key is missing'
    fi
    printf '%s\n' '{"fresh":true}'
    ;;

  validate-baseline)
    validate_file "$active_key" 400 'key.txt'
    observe_converged_generation "$baseline_hash_argument" || \
      die "current system and system profile must converge before enrollment: $generation_pending_reason"
    verify_ciphertext "$active_key" < "$generation_ciphertext" || \
      die 'current key cannot decrypt the active generation ciphertext'
    jq -n \
      --arg system "$generation_current_target" \
      --arg ciphertext "$generation_ciphertext" \
      --arg ciphertextSha256 "$generation_ciphertext_hash" \
      '{ready: true, system: $system,
        ciphertext: {path: $ciphertext, sha256: $ciphertextSha256}}'
    ;;

  stage)
    [[ ! -e $journal ]] || die 'an enrollment transaction is already active'
    [[ ! -e $next_key ]] || die 'key.next exists without an active transaction'

    shopt -s nullglob
    stale_internal_files=("$key_dir"/.key.next.* "$key_dir"/.write.*)
    for stale_file in "${stale_internal_files[@]}"; do
      [[ ! -L $stale_file && -f $stale_file ]] || die 'stale enrollment temporary path is invalid'
      stale_metadata=$(stat -c '%u|%a|%h' -- "$stale_file")
      [[ $stale_metadata == "$expected_uid|600|1" || $stale_metadata == "$expected_uid|400|1" ]] || \
        die 'stale enrollment temporary file has invalid metadata'
      rm -f -- "$stale_file"
    done
    shopt -u nullglob
    if (( ${#stale_internal_files[@]} > 0 )); then
      sync -f "$key_dir"
    fi

    previous_recipient=
    if [[ -e $active_key ]]; then
      validate_file "$active_key" 400 'key.txt'
      previous_recipient=$(recipient_of "$active_key")
    fi

    temporary=$(mktemp "$key_dir/.key.next.XXXXXX")
    trap 'rm -f -- "$temporary"' EXIT
    rm -f -- "$temporary"
    age-keygen -o "$temporary" >/dev/null 2>&1
    chmod 0400 "$temporary"
    if (( allow_test_hooks != 1 )); then
      chown 0:0 -- "$temporary"
    fi
    sync -d "$temporary"
    mv -fT -- "$temporary" "$next_key"
    sync -f "$key_dir"
    trap - EXIT

    if (( allow_test_hooks == 1 )) && [[ ${SOPS_ENROLL_TEST_FAIL_AFTER_KEY_STAGE:-0} == 1 ]]; then
      exit 69
    fi

    next_recipient=$(recipient_of "$next_key")
    [[ $next_recipient != "$previous_recipient" ]] || die 'generated host identity duplicated the current identity'
    transaction_id=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    jq -n \
      --arg transactionId "$transaction_id" \
      --arg previousRecipient "$previous_recipient" \
      --arg nextRecipient "$next_recipient" \
      --arg startedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        version: 1,
        transactionId: $transactionId,
        state: "staged",
        hostId: null,
        previousRecipient: (if $previousRecipient == "" then null else $previousRecipient end),
        nextRecipient: $nextRecipient,
        oldConfigHash: null,
        oldSecretsHash: null,
        newConfigHash: null,
        newSecretsHash: null,
        historyToClose: null,
        closedGenerations: [],
        candidateSystem: null,
        startedAt: $startedAt
      }' | write_json_file "$journal" 0600
    print_status
    ;;

  status)
    print_status
    ;;

  verify-next)
    read_journal
    state=$(journal_state)
    [[ $state == staged || $state == prepared || $state == swap-intent || $state == repo-swapped ||
      $state == generation-pending || $state == generation-ready || $state == history-close-intent ||
      $state == history-closed ]] || \
      die 'verify-next is only valid before key promotion'
    validate_file "$next_key" 400 'key.next'
    if (( allow_test_hooks == 1 )) && [[ ${SOPS_ENROLL_TEST_FAIL_VERIFY_NEXT:-0} == 1 ]]; then
      exit 70
    fi
    verify_ciphertext "$next_key"
    ;;

  verify-previous)
    read_journal
    require_state staged
    [[ $(jq -r '.previousRecipient // ""' "$journal") != "" ]] || \
      die 'transaction has no previous host identity'
    validate_file "$active_key" 400 'key.txt'
    [[ $(recipient_of "$active_key") == "$(jq -r '.previousRecipient' "$journal")" ]] || \
      die 'current key does not match the previous recipient'
    if (( allow_test_hooks == 1 )) && [[ ${SOPS_ENROLL_TEST_FAIL_VERIFY_PREVIOUS:-0} == 1 ]]; then
      exit 68
    fi
    verify_ciphertext "$active_key"
    ;;

  prepare)
    read_journal
    require_state staged
    payload=$(dd bs=4097 count=1 status=none)
    (( ${#payload} < 4097 )) || die 'candidate metadata is too large'
    jq -e '
      (keys | sort) == ["hostId", "newConfigHash", "newSecretsHash", "oldConfigHash", "oldSecretsHash"] and
      (.hostId | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
      all(.oldConfigHash, .oldSecretsHash, .newConfigHash, .newSecretsHash;
        type == "string" and test("^[0-9a-f]{64}$"))
    ' <<< "$payload" >/dev/null || die 'candidate metadata is invalid'
    # shellcheck disable=SC2016 # jq variables are supplied with --arg below.
    write_updated_journal \
      '.state = "prepared" |
       .hostId = $hostId |
       .oldConfigHash = $oldConfigHash |
       .oldSecretsHash = $oldSecretsHash |
       .newConfigHash = $newConfigHash |
       .newSecretsHash = $newSecretsHash' \
      --arg hostId "$(jq -r '.hostId' <<< "$payload")" \
      --arg oldConfigHash "$(jq -r '.oldConfigHash' <<< "$payload")" \
      --arg oldSecretsHash "$(jq -r '.oldSecretsHash' <<< "$payload")" \
      --arg newConfigHash "$(jq -r '.newConfigHash' <<< "$payload")" \
      --arg newSecretsHash "$(jq -r '.newSecretsHash' <<< "$payload")"
    ;;

  arm-swap)
    read_journal
    require_state prepared
    write_updated_journal '.state = "swap-intent"'
    ;;

  mark-repo-swapped)
    read_journal
    require_state swap-intent
    write_updated_journal '.state = "repo-swapped"'
    ;;

  mark-generation-pending)
    read_journal
    require_state repo-swapped
    [[ $(jq -r '.previousRecipient // ""' "$journal") != "" ]] || \
      die 'fresh enrollment does not use a generation barrier'
    write_updated_journal '.state = "generation-pending"'
    ;;

  advance-generation)
    read_journal
    require_state generation-pending
    expected_hash=$(jq -r '.newSecretsHash' "$journal")
    if ! observe_converged_generation "$expected_hash"; then
      jq -n --arg reason "$generation_pending_reason" \
        '{ready: false, reason: $reason}'
      exit 0
    fi
    verify_generation_with_both_keys "$expected_hash"
    # shellcheck disable=SC2016 # candidateSystem is a jq variable.
    write_updated_journal \
      '.state = "generation-ready" | .candidateSystem = $candidateSystem' \
      --arg candidateSystem "$generation_current_target"
    jq -n \
      --arg system "$generation_current_target" \
      --arg ciphertext "$generation_ciphertext" \
      --arg ciphertextSha256 "$generation_ciphertext_hash" \
      '{ready: true, system: $system,
        ciphertext: {path: $ciphertext, sha256: $ciphertextSha256}}'
    ;;

  arm-history-close)
    read_journal
    state=$(journal_state)
    [[ $state == generation-ready || $state == history-close-intent ]] || \
      die 'history closure requires a verified generation'
    expected_hash=$(jq -r '.newSecretsHash' "$journal")
    verify_generation_with_both_keys "$expected_hash"
    collect_incompatible_generations "$expected_hash"
    previous_plan=$(jq -c '.historyToClose // []' "$journal")
    for generation in $(jq -r '.[].generation' <<< "$previous_plan"); do
      old_target=$(jq -r --argjson generation "$generation" \
        '.[] | select(.generation == $generation) | .system' <<< "$previous_plan")
      current_target=$(jq -r --argjson generation "$generation" \
        '.[] | select(.generation == $generation) | .system // ""' <<< "$generation_incompatible")
      [[ -z $current_target || $current_target == "$old_target" ]] || \
        die 'a recorded system generation number now points to a different closure'
    done
    combined_plan=$(jq -cn \
      --argjson previous "$previous_plan" \
      --argjson current "$generation_incompatible" \
      '$previous + $current | unique_by(.generation) | sort_by(.generation)')
    # shellcheck disable=SC2016 # historyToClose is a jq variable.
    write_updated_journal \
      '.state = "history-close-intent" | .historyToClose = $historyToClose' \
      --argjson historyToClose "$combined_plan"
    jq -n \
      --argjson incompatible "$combined_plan" \
      --argjson observed "$generation_observations" \
      '{incompatible: $incompatible, observed: $observed}'
    ;;

  close-history)
    read_journal
    require_state history-close-intent
    expected_hash=$(jq -r '.newSecretsHash' "$journal")
    verify_generation_with_both_keys "$expected_hash"
    history_to_close=$(jq -c '.historyToClose' "$journal")
    mapfile -t generations_to_close < <(jq -r '.[].generation' <<< "$history_to_close")
    profile_dir=$(dirname -- "$system_profile")
    profile_name=$(basename -- "$system_profile")
    for generation in "${generations_to_close[@]}"; do
      link=$profile_dir/$profile_name-$generation-link
      [[ -e $link || -L $link ]] || continue
      [[ -L $link ]] || die 'recorded system generation is not a symbolic link'
      observed_target=$(realpath -e -- "$link") || die 'recorded system generation target does not exist'
      expected_target=$(jq -r --argjson generation "$generation" \
        '.[] | select(.generation == $generation) | .system' <<< "$history_to_close")
      [[ $observed_target == "$expected_target" ]] || \
        die 'recorded system generation target changed before deletion'
    done
    if (( ${#generations_to_close[@]} > 0 )); then
      "$nix_env" --profile "$system_profile" --delete-generations "${generations_to_close[@]}"
    fi
    verify_generation_with_both_keys "$expected_hash"
    collect_incompatible_generations "$expected_hash"
    [[ $(jq 'length' <<< "$generation_incompatible") -eq 0 ]] || \
      die 'incompatible system generations remain after history closure'
    write_updated_journal \
      '.state = "history-closed" | .closedGenerations = .historyToClose | .historyToClose = null'
    ;;

  promote)
    read_journal
    expected_previous=$(jq -r '.previousRecipient // ""' "$journal")
    if [[ -n $expected_previous ]]; then
      require_state history-closed
    else
      require_state repo-swapped
    fi
    expected_next=$(jq -r '.nextRecipient' "$journal")
    current_recipient=$(observed_recipient "$active_key")
    staged_recipient=$(observed_recipient "$next_key")

    if [[ -n $expected_previous ]]; then
      expected_hash=$(jq -r '.newSecretsHash' "$journal")
      if [[ $current_recipient == "$expected_previous" ]]; then
        verify_generation_with_both_keys "$expected_hash"
        collect_incompatible_generations "$expected_hash" "$next_key"
      else
        observe_converged_generation "$expected_hash" || \
          die "current generation changed before key promotion recovery: $generation_pending_reason"
        collect_incompatible_generations "$expected_hash" "$active_key"
      fi
      [[ $(jq 'length' <<< "$generation_incompatible") -eq 0 ]] || \
        die 'an incompatible system generation appeared after history closure'
    fi

    if [[ $current_recipient == "$expected_next" ]]; then
      if [[ -n $expected_previous ]]; then
        [[ $staged_recipient == "$expected_previous" ]] || die 'promoted key state is inconsistent'
      else
        [[ -z $staged_recipient ]] || die 'unexpected key.next after first-host promotion'
      fi
    else
      [[ $current_recipient == "$expected_previous" ]] || die 'current key does not match the transaction journal'
      [[ $staged_recipient == "$expected_next" ]] || die 'staged key does not match the transaction journal'
      if [[ -e $active_key ]]; then
        mv -T --exchange --no-copy -- "$active_key" "$next_key"
      else
        mv -T -- "$next_key" "$active_key"
      fi
      sync -f "$key_dir"
      if (( allow_test_hooks == 1 )) && [[ ${SOPS_ENROLL_TEST_FAIL_AFTER_KEY_SWAP:-0} == 1 ]]; then
        exit 71
      fi
      validate_file "$active_key" 400 'key.txt'
      [[ $(recipient_of "$active_key") == "$expected_next" ]] || die 'key promotion did not converge'
    fi
    write_updated_journal '.state = "key-promoted"'
    ;;

  verify-current)
    read_journal
    state=$(journal_state)
    [[ $state == key-promoted || $state == verified ]] || \
      die 'verify-current is only valid after key promotion'
    validate_file "$active_key" 400 'key.txt'
    [[ $(recipient_of "$active_key") == "$(jq -r '.nextRecipient' "$journal")" ]] || \
      die 'current key does not match the enrolled recipient'
    verify_ciphertext "$active_key"
    ;;

  reinstall-current)
    read_journal
    state=$(journal_state)
    [[ $state == key-promoted || $state == verified ]] || \
      die 'current generation reinstall is only valid after key promotion'
    expected_hash=$(jq -r '.newSecretsHash' "$journal")
    observe_converged_generation "$expected_hash" || \
      die "current generation changed after key promotion: $generation_pending_reason"
    expected_system=$(jq -r '.candidateSystem // ""' "$journal")
    if [[ $(jq -r '.previousRecipient // ""' "$journal") != "" ]]; then
      [[ -n $expected_system && $generation_current_target == "$expected_system" ]] || \
        die 'current generation no longer matches the enrollment candidate'
    fi
    validate_file "$active_key" 400 'key.txt'
    [[ $(recipient_of "$active_key") == "$(jq -r '.nextRecipient' "$journal")" ]] || \
      die 'current key does not match the enrolled recipient'
    verify_ciphertext "$active_key" < "$generation_ciphertext"
    "$generation_installer"
    ;;

  verify-installed)
    [[ ! -e $journal ]] || die 'verify-installed is only valid without an active transaction'
    read_receipt
    validate_file "$active_key" 400 'key.txt'
    [[ $(recipient_of "$active_key") == "$(jq -r '.nextRecipient' "$receipt")" ]] || \
      die 'current key does not match the last enrollment receipt'
    verify_ciphertext "$active_key"
    ;;

  mark-verified)
    read_journal
    require_state key-promoted
    write_updated_journal '.state = "verified"'
    ;;

  finalize)
    read_journal
    require_state verified
    validate_file "$active_key" 400 'key.txt'
    [[ $(recipient_of "$active_key") == "$(jq -r '.nextRecipient' "$journal")" ]] || \
      die 'current key does not match the verified transaction'
    if [[ $(jq -r '.previousRecipient // ""' "$journal") != "" ]]; then
      expected_hash=$(jq -r '.newSecretsHash' "$journal")
      observe_converged_generation "$expected_hash" || \
        die "current generation changed before finalization: $generation_pending_reason"
      [[ $generation_current_target == "$(jq -r '.candidateSystem' "$journal")" ]] || \
        die 'current generation no longer matches the enrollment candidate'
      verify_ciphertext "$active_key" < "$generation_ciphertext"
      collect_incompatible_generations "$expected_hash" "$active_key"
      [[ $(jq 'length' <<< "$generation_incompatible") -eq 0 ]] || \
        die 'an incompatible system generation blocks old-key deletion'
      "$generation_installer"
    fi
    if [[ -e $next_key ]]; then
      validate_file "$next_key" 400 'key.next'
      expected_previous=$(jq -r '.previousRecipient // ""' "$journal")
      [[ -n $expected_previous && $(recipient_of "$next_key") == "$expected_previous" ]] || \
        die 'key.next is not the expected previous identity'
      rm -f -- "$next_key"
      sync -f "$key_dir"
      if (( allow_test_hooks == 1 )) && [[ ${SOPS_ENROLL_TEST_FAIL_AFTER_OLD_KEY_DELETE:-0} == 1 ]]; then
        exit 77
      fi
    fi
    if [[ $(jq -r '.previousRecipient // ""' "$journal") != "" ]]; then
      [[ $(jq -r '.candidateSystem // ""' "$journal") != "" ]] || \
        die 'migration receipt is missing its candidate system'
      [[ $(jq -r '.closedGenerations | type' "$journal") == array ]] || \
        die 'migration receipt is missing its closed generations'
    fi
    jq \
      --arg completedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
      '.state = "complete" |
       .freshEnrollment = (.previousRecipient == null) |
       .completedAt = $completedAt' \
      "$journal" | write_json_file "$receipt" 0600
    rm -f -- "$journal"
    sync -f "$key_dir"
    ;;

  abort-orphan)
    [[ ! -e $journal ]] || die 'a journaled transaction cannot be aborted as an orphan'
    validate_file "$next_key" 400 'orphaned key.next'
    rm -f -- "$next_key"
    sync -f "$key_dir"
    ;;

  abort)
    read_journal
    state=$(journal_state)
    [[ $state == staged || $state == prepared ]] || die 'only an uncommitted transaction can be aborted'
    if [[ -e $next_key ]]; then
      validate_file "$next_key" 400 'key.next'
      [[ $(recipient_of "$next_key") == "$(jq -r '.nextRecipient' "$journal")" ]] || \
        die 'key.next does not match the transaction journal'
      rm -f -- "$next_key"
    fi
    rm -f -- "$journal"
    sync -f "$key_dir"
    ;;
esac
