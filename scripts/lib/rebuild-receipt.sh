dotfiles_rebuild_validate_state_root() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 directory metadata

  for directory in "$state_root" "$state_root/receipts" "$state_root/roots"; do
    [[ -d $directory && ! -L $directory ]] || {
      echo "dotfiles-rebuild-receipt: state path must be a real directory: $directory" >&2
      return 1
    }
    metadata=$(stat -c '%u|%g|%a' -- "$directory")
    [[ $metadata == "$expected_uid|$expected_gid|700" ]] || {
      echo "dotfiles-rebuild-receipt: state path has invalid owner or mode: $directory" >&2
      return 1
    }
  done
}

dotfiles_rebuild_prepare_state_root() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 directory parent

  for directory in "$state_root" "$state_root/receipts" "$state_root/roots"; do
    if [[ ! -e $directory && ! -L $directory ]]; then
      parent=${directory%/*}
      mkdir -m 0700 -- "$directory" || return 1
      sync "$parent" || return 1
    fi
  done
  dotfiles_rebuild_validate_state_root "$state_root" "$expected_uid" "$expected_gid"
}

dotfiles_rebuild_validate_receipt_file() {
  local receipt=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5 metadata

  [[ -f $receipt && ! -L $receipt ]] || {
    echo "dotfiles-rebuild-receipt: receipt must be a regular file: $receipt" >&2
    return 1
  }
  metadata=$(stat -c '%u|%a|%h' -- "$receipt")
  [[ $metadata == "$expected_uid|600|1" ]] || {
    echo "dotfiles-rebuild-receipt: receipt has invalid owner, mode, or link count: $receipt" >&2
    return 1
  }

  jq -e \
    --arg worktree "$expected_worktree" \
    --argjson uid "$expected_uid" \
    --arg user "$expected_user" \
    --arg store "$nix_store_dir/" '
      def pending_result: .status == "pending" and .exitCode == null;
      def succeeded_result: .status == "succeeded" and .exitCode == 0;
      def failed_result:
        .status == "failed" and
        (.exitCode | type == "number" and . >= 1 and . <= 255 and floor == .);
      def runtime_snapshot:
        type == "object" and
        ([.current, .booted, .profile] |
          all(type == "string" and startswith($store)));

      .schemaVersion == 2 and
      (.transactionId | type == "string" and test("^[0-9a-f]{32}$")) and
      .worktree == $worktree and
      ([.source, .candidate, .recoveryTarget, .previous.running, .previous.booted,
        .previous.displacedProfile] |
        all(type == "string" and startswith($store))) and
      .recoveryTarget == .previous.running and
      (.helperPath == (.candidate + "/sw/bin/dotfiles-rebuild")) and
      (((.effect | IN("switch", "switch-restart")) and .action == "switch") or
        ((.effect | IN("boot-restart", "boot-two-stage")) and .action == "boot")) and
      (.distro | type == "string" and length > 0 and (contains("\n") | not)) and
      .transactionUid == $uid and
      .transactionUser == $user and
      .candidateDefaultUser == $user and
      .previousDefaultUser == $user and
      (.sopsEnrollmentTransactionId == null or
        (.sopsEnrollmentTransactionId | type == "string" and test("^[0-9a-f]{32}$"))) and
      (.bootInstances.beforeApply | type == "object" and
        (.kernelBootId | type == "string" and
          test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$"))) and
      (.bootInstances.firstBoot == null or
        (.bootInstances.firstBoot | type == "object" and
          (.kernelBootId | type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
          (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$")))) and
      (.bootInstances.firstBoot == null or .effect == "boot-two-stage") and
      (.bootInstances.firstBoot == null or
        .bootInstances.firstBoot.kernelBootId != .bootInstances.beforeApply.kernelBootId or
        .bootInstances.firstBoot.userspaceTimestampMonotonic !=
          .bootInstances.beforeApply.userspaceTimestampMonotonic) and
      (.activationBaseline | runtime_snapshot) and
      ((.state == "aborted") == (.abort != null)) and
      (.abort == null or (
        (.abort.direction | IN("forward", "rollback")) and
        (.abort.point | IN("receipt-publication", "intent-publication", "activation-handoff")) and
        (.abort.expected | runtime_snapshot) and
        (.abort.observed | runtime_snapshot)
      )) and
      (.state | IN(
        "prepared", "apply-intent", "activation-failed", "restart-pending",
        "first-boot-observed", "verifying", "verification-failed", "rollback-intent",
        "rollback-activation-failed", "rollback-restart-pending",
        "rollback-first-boot-observed", "rollback-verifying",
        "rollback-verification-failed", "complete", "rolled-back", "aborted"
      )) and
      (if (.state | IN(
        "prepared", "apply-intent", "activation-failed", "restart-pending",
        "first-boot-observed", "verifying", "verification-failed", "complete"
      )) then
        .rollback == null
      elif (.state | IN(
        "rollback-intent", "rollback-activation-failed", "rollback-restart-pending",
        "rollback-first-boot-observed", "rollback-verifying",
        "rollback-verification-failed", "rolled-back"
      )) then
        .rollback != null
      elif .state == "aborted" then
        ((.abort.direction == "forward" and .rollback == null) or
          (.abort.direction == "rollback" and .rollback != null))
      else
        false
      end) and
      (if (.state | IN("prepared", "apply-intent", "activation-failed", "restart-pending")) then
        .bootInstances.firstBoot == null
      elif .state == "first-boot-observed" then
        .effect == "boot-two-stage" and .bootInstances.firstBoot != null
      elif ((.state | IN("verifying", "verification-failed", "complete")) and
        .effect == "boot-two-stage") then
        .bootInstances.firstBoot != null
      else
        true
      end) and
      (.activation.status | IN("pending", "succeeded", "failed")) and
      (.activation.exitCode == null or
        (.activation.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .)) and
      (.verification.status | IN("pending", "succeeded", "failed")) and
      (.verification.exitCode == null or
        (.verification.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .)) and
      (.failureStage == null or (.failureStage | type == "string" and length > 0)) and
      (.rollback == null or (
        (.rollback.target == .recoveryTarget) and
        (.rollback.activationBaseline | runtime_snapshot) and
        (((.rollback.effect | IN("switch", "switch-restart")) and .rollback.action == "switch") or
          ((.rollback.effect | IN("boot-restart", "boot-two-stage")) and .rollback.action == "boot")) and
        (.rollback.bootInstances.beforeApply | type == "object" and
          (.kernelBootId | type == "string" and
            test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
          (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$"))) and
        (.rollback.bootInstances.firstBoot == null or
          (.rollback.bootInstances.firstBoot | type == "object" and
            (.kernelBootId | type == "string" and
              test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
            (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$")))) and
        (.rollback.bootInstances.firstBoot == null or .rollback.effect == "boot-two-stage") and
        (.rollback.bootInstances.firstBoot == null or
          .rollback.bootInstances.firstBoot.kernelBootId !=
            .rollback.bootInstances.beforeApply.kernelBootId or
          .rollback.bootInstances.firstBoot.userspaceTimestampMonotonic !=
            .rollback.bootInstances.beforeApply.userspaceTimestampMonotonic) and
        (if (.state | IN(
          "rollback-intent", "rollback-activation-failed", "rollback-restart-pending"
        )) then
          .rollback.bootInstances.firstBoot == null
        elif .state == "rollback-first-boot-observed" then
          .rollback.effect == "boot-two-stage" and .rollback.bootInstances.firstBoot != null
        elif ((.state | IN(
          "rollback-verifying", "rollback-verification-failed", "rolled-back"
        )) and .rollback.effect == "boot-two-stage") then
          .rollback.bootInstances.firstBoot != null
        else
          true
        end) and
        (.rollback.activation.status | IN("pending", "succeeded", "failed")) and
        (.rollback.activation.exitCode == null or
          (.rollback.activation.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .))
      )) and
      (if (.state | IN("prepared", "apply-intent")) then
        (.activation | pending_result) and
        (.verification | pending_result) and
        .failureStage == null
      elif .state == "activation-failed" then
        (.activation | failed_result) and
        (.verification | pending_result) and
        .failureStage == "activation"
      elif (.state | IN("restart-pending", "first-boot-observed", "verifying")) then
        (.activation | succeeded_result) and
        (.verification | pending_result) and
        .failureStage == null and
        (.state != "restart-pending" or .effect != "switch")
      elif .state == "verification-failed" then
        (.activation | succeeded_result) and
        (.verification | failed_result) and
        .failureStage != null
      elif .state == "rollback-intent" then
        (.rollback.activation | pending_result) and
        (.verification | pending_result) and
        .failureStage == null
      elif .state == "rollback-activation-failed" then
        (.rollback.activation | failed_result) and
        (.verification | pending_result) and
        .failureStage == "rollback-activation"
      elif (.state | IN(
        "rollback-restart-pending", "rollback-first-boot-observed", "rollback-verifying"
      )) then
        (.rollback.activation | succeeded_result) and
        (.verification | pending_result) and
        .failureStage == null and
        (.state != "rollback-restart-pending" or .rollback.effect != "switch")
      elif .state == "rollback-verification-failed" then
        (.rollback.activation | succeeded_result) and
        (.verification | failed_result) and
        .failureStage != null
      elif .state == "aborted" then
        .abort != null and
        .abort.expected != .abort.observed and
        (if .abort.direction == "forward" then
          .abort.expected == .activationBaseline
        else
          .abort.expected == .rollback.activationBaseline
        end) and
        .failureStage == "runtime-drift" and
        (.verification | pending_result) and
        (if .abort.direction == "forward" then
          ((.activation | pending_result) or (.activation | failed_result))
        else
          ((.rollback.activation | pending_result) or
            (.rollback.activation | failed_result))
        end)
      else
        true
      end) and
      (.startedAt | type == "string" and length > 0) and
      (.updatedAt | type == "string" and length > 0) and
      (if .state == "complete" then
        .rollback == null and
        .activation.status == "succeeded" and .activation.exitCode == 0 and
        .verification.status == "succeeded" and .verification.exitCode == 0 and
        .failureStage == null and
        (.finishedAt | type == "string" and length > 0)
      elif .state == "rolled-back" then
        .rollback != null and
        .rollback.activation.status == "succeeded" and .rollback.activation.exitCode == 0 and
        .verification.status == "succeeded" and .verification.exitCode == 0 and
        .failureStage == null and
        (.finishedAt | type == "string" and length > 0)
      elif .state == "aborted" then
        .failureStage == "runtime-drift" and
        (.finishedAt | type == "string" and length > 0)
      else
        .finishedAt == null
      end)
    ' "$receipt" >/dev/null
}

dotfiles_rebuild_read_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local active_receipt=$state_root/active.json

  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  cat -- "$active_receipt"
}

dotfiles_rebuild_create_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local active_receipt=$state_root/active.json temporary

  [[ ! -e $active_receipt && ! -L $active_receipt ]] || {
    echo 'dotfiles-rebuild-receipt: an active receipt already exists' >&2
    return 1
  }
  temporary=$(mktemp "$state_root/.active.XXXXXX") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  cat > "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_receipt_file \
    "$temporary" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  if ! ln -- "$temporary" "$active_receipt" 2>/dev/null; then
    rm -f -- "$temporary" || return 1
    echo 'dotfiles-rebuild-receipt: failed to publish the active receipt' >&2
    return 1
  fi
  local publication_status=0
  sync --data "$active_receipt" || publication_status=1
  sync "$state_root" || publication_status=1
  rm -f -- "$temporary" || publication_status=1
  sync "$state_root" || publication_status=1
  [[ $publication_status -eq 0 ]]
}

dotfiles_rebuild_update_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  shift 5
  local active_receipt=$state_root/active.json temporary

  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  temporary=$(mktemp "$state_root/.active.XXXXXX") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  if ! jq "$@" "$active_receipt" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  dotfiles_rebuild_validate_receipt_file \
    "$temporary" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T -- "$temporary" "$active_receipt" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$active_receipt" || return 1
  sync "$state_root" || return 1
}

dotfiles_rebuild_ensure_gc_roots() {
  local state_root=$1 transaction_id=$2 nix_store_dir=$3 nix_gc_auto_roots_dir=$4
  shift 4
  local transaction_roots=$state_root/roots/$transaction_id label target root metadata
  local auto_root auto_match_count

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ -d $nix_gc_auto_roots_dir && ! -L $nix_gc_auto_roots_dir ]] || return 1
  if [[ ! -e $transaction_roots && ! -L $transaction_roots ]]; then
    mkdir -m 0700 -- "$transaction_roots" || return 1
    sync "$state_root/roots" || return 1
  fi
  [[ -d $transaction_roots && ! -L $transaction_roots ]] || return 1
  metadata=$(stat -c '%u|%a' -- "$transaction_roots")
  [[ $metadata == "$EUID|700" ]] || return 1

  while (( $# > 0 )); do
    [[ $# -ge 2 ]] || return 1
    label=$1
    target=$2
    shift 2
    [[ $label =~ ^[a-z][a-z-]*$ && $target == "$nix_store_dir/"* && -e $target ]] || return 1
    root=$transaction_roots/$label
    nix-store --add-root "$root" --realise "$target" >/dev/null || return 1
    [[ -L $root && $(readlink -f -- "$root") == "$target" ]] || return 1
    auto_match_count=0
    for auto_root in "$nix_gc_auto_roots_dir"/*; do
      [[ -L $auto_root ]] || continue
      [[ $(readlink -- "$auto_root") == "$root" ]] || continue
      (( auto_match_count += 1 ))
    done
    [[ $auto_match_count -eq 1 ]] || return 1
  done
  sync "$transaction_roots" || return 1
  sync "$nix_gc_auto_roots_dir" || return 1
}

dotfiles_rebuild_archive_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5 transaction_id=$6
  local active_receipt=$state_root/active.json archived_receipt=$state_root/receipts/$transaction_id.json

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  [[ $(jq -r '.transactionId' "$active_receipt") == "$transaction_id" ]] || return 1
  [[ ! -e $archived_receipt && ! -L $archived_receipt ]] || return 1
  mv -T -- "$active_receipt" "$archived_receipt" || return 1
  local publication_status=0
  sync --data "$archived_receipt" || publication_status=1
  sync "$state_root/receipts" || publication_status=1
  sync "$state_root" || publication_status=1
  [[ $publication_status -eq 0 ]]
}

dotfiles_rebuild_remove_gc_roots() {
  local state_root=$1 transaction_id=$2 transaction_roots

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  transaction_roots=$state_root/roots/$transaction_id
  if [[ ! -e $transaction_roots && ! -L $transaction_roots ]]; then
    return 0
  fi
  [[ -d $transaction_roots && ! -L $transaction_roots ]] || return 1
  rm -r -- "$transaction_roots" || return 1
  sync "$state_root/roots" || return 1
}

dotfiles_rebuild_cleanup_orphan_gc_roots() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local transaction_roots transaction_id archived_receipt metadata state

  [[ -d $state_root/roots && ! -L $state_root/roots ]] || return 0
  for transaction_roots in "$state_root"/roots/*; do
    [[ -e $transaction_roots || -L $transaction_roots ]] || continue
    [[ -d $transaction_roots && ! -L $transaction_roots ]] || return 1
    transaction_id=${transaction_roots##*/}
    [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
    metadata=$(stat -c '%u|%a' -- "$transaction_roots")
    [[ $metadata == "$expected_uid|700" ]] || return 1
    archived_receipt=$state_root/receipts/$transaction_id.json
    if [[ -e $archived_receipt || -L $archived_receipt ]]; then
      dotfiles_rebuild_validate_receipt_file \
        "$archived_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
      state=$(jq -r '.state' "$archived_receipt")
      [[ $state == complete || $state == rolled-back || $state == aborted ]] || return 1
    fi
    rm -r -- "$transaction_roots" || return 1
    sync "$state_root/roots" || return 1
  done
}
