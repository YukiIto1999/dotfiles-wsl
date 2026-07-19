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
      def check_ids:
        if has("failedCheckIds") then
          (.failedCheckIds as $ids |
            ($ids | type) == "array" and
            all($ids[]; type == "string" and length > 0) and
            ($ids | length) == ($ids | unique | length))
        else
          true
        end;
      def no_check_ids:
        (has("failedCheckIds") | not) or (.failedCheckIds | length == 0);
      def pending_result:
        .status == "pending" and .exitCode == null and
        check_ids and no_check_ids;
      def succeeded_result:
        .status == "succeeded" and .exitCode == 0 and
        check_ids and no_check_ids;
      def failed_result:
        .status == "failed" and
        (.exitCode | type == "number" and . >= 1 and . <= 255 and floor == .) and
        check_ids;
      def indeterminate_result:
        .status == "indeterminate" and .exitCode == null and
        check_ids and no_check_ids;
      def terminal_attempt:
        .status | IN("succeeded", "failed", "indeterminate");
      def attempt_sequence:
        type == "array" and
        all(.[:-1][]; terminal_attempt);
      def result_matches_attempts($allow_empty_failed):
        (.attempts | attempt_sequence) and
        if .status == "pending" then
          .exitCode == null and
          ((.attempts | length) == 0 or
            (.attempts[-1].status | IN("intent", "running")))
        elif .status == "succeeded" then
          .exitCode == 0 and (.attempts | length) > 0 and
          .attempts[-1].status == "succeeded" and .attempts[-1].exitCode == 0
        elif .status == "failed" then
          (.exitCode | type == "number" and . >= 1 and . <= 255 and floor == .) and
          (($allow_empty_failed and (.attempts | length) == 0) or
            ((.attempts | length) > 0 and .attempts[-1].status == "failed" and
              .attempts[-1].exitCode == .exitCode))
        else
          .status == "indeterminate" and .exitCode == null and
          (.attempts | length) > 0 and .attempts[-1].status == "indeterminate" and
          .attempts[-1].exitCode == null
        end;
      def runtime_snapshot:
        type == "object" and
        ([.current, .booted, .profile] |
          all(type == "string" and startswith($store)));
      def boot_instance:
        type == "object" and
        (.kernelBootId | type == "string" and
          test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$"));
      def artifact($path):
        type == "object" and
        .path == $path and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.bytes | type == "number" and . >= 0 and floor == .);
      def attempt($transaction_id; $direction; $target; $action):
        . as $attempt |
        ($attempt.number | type == "number" and . >= 1 and floor == .) and
        ($attempt.attemptId | type == "string" and test("^[0-9a-f]{32}$")) and
        $attempt.direction == $direction and
        $attempt.target == $target and
        $attempt.action == $action and
        ($attempt.activationBaseline | runtime_snapshot) and
        ($attempt.bootBaseline | boot_instance) and
        ($attempt.status | IN("intent", "running", "succeeded", "failed", "indeterminate")) and
        ($attempt.boundary == null or
          ($attempt.boundary | IN("before-profile-commit", "after-profile-commit", "unknown"))) and
        ($attempt.createdAt | type == "string" and length > 0) and
        ($attempt.startedAt == null or
          ($attempt.startedAt | type == "string" and length > 0)) and
        ($attempt.finishedAt == null or
          ($attempt.finishedAt | type == "string" and length > 0)) and
        ($attempt.exitCode == null or
          ($attempt.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .)) and
        (("attempts/" + $transaction_id + "/" + ($attempt.number | tostring) + "-" +
          $attempt.attemptId) as $prefix |
          ($attempt.intent | artifact($prefix + "/intent.json")) and
          $attempt.partialLogPath == ($prefix + "/activation.log.partial") and
          ($attempt.started == null or
            ($attempt.started | artifact($prefix + "/started.json"))) and
          ($attempt.log == null or
            (($attempt.log | artifact($prefix + "/activation.log")) and
              ($attempt.log.truncated | type == "boolean") and
              ($attempt.log.captureExitCode | type == "number" and
                . >= 0 and . <= 255 and floor == .))) and
          ($attempt.outcome == null or
            ($attempt.outcome | artifact($prefix + "/outcome.json")))) and
        (if $attempt.status == "intent" then
          $attempt.started == null and $attempt.log == null and $attempt.outcome == null and
          $attempt.startedAt == null and $attempt.finishedAt == null and
          $attempt.exitCode == null and $attempt.boundary == null
        elif $attempt.status == "running" then
          $attempt.started != null and $attempt.log == null and $attempt.outcome == null and
          $attempt.startedAt != null and $attempt.finishedAt == null and
          $attempt.exitCode == null and $attempt.boundary == null
        elif $attempt.status == "indeterminate" then
          $attempt.started != null and $attempt.log != null and $attempt.outcome != null and
          $attempt.startedAt != null and $attempt.log.captureExitCode == 255 and
          $attempt.finishedAt != null and $attempt.exitCode == null and
          ($attempt.boundary | IN("before-profile-commit", "after-profile-commit", "unknown"))
        elif $attempt.status == "succeeded" then
          $attempt.started != null and $attempt.log != null and $attempt.outcome != null and
          $attempt.startedAt != null and $attempt.finishedAt != null and $attempt.exitCode == 0 and
          $attempt.boundary == "after-profile-commit"
        else
          $attempt.started != null and $attempt.log != null and $attempt.outcome != null and
          $attempt.startedAt != null and $attempt.finishedAt != null and
          ($attempt.exitCode | type == "number" and . >= 1 and . <= 255 and floor == .) and
          ($attempt.boundary | IN("before-profile-commit", "after-profile-commit", "unknown"))
        end);

      . as $receipt |
      (.schemaVersion | IN(2, 3)) and
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
      ((.state == "cancelled") == (.cancellation != null)) and
      (.abort == null or (
        (.abort.direction | IN("forward", "rollback")) and
        (.abort.point | IN("receipt-publication", "intent-publication", "activation-handoff")) and
        (.abort.expected | runtime_snapshot) and
        (.abort.observed | runtime_snapshot)
      )) and
      (.state | IN(
        "prepared", "apply-intent", "activating", "activation-indeterminate",
        "activation-failed", "restart-pending",
        "first-boot-observed", "verifying", "verification-failed", "rollback-intent",
        "rollback-activating", "rollback-activation-indeterminate",
        "rollback-activation-failed", "rollback-restart-pending",
        "rollback-first-boot-observed", "rollback-verifying",
        "rollback-verification-failed", "complete", "rolled-back", "aborted", "cancelled"
      )) and
      (if (.state | IN(
        "prepared", "apply-intent", "activating", "activation-indeterminate",
        "activation-failed", "restart-pending",
        "first-boot-observed", "verifying", "verification-failed", "complete"
      )) then
        .rollback == null
      elif (.state | IN(
          "rollback-intent", "rollback-activating", "rollback-activation-indeterminate",
          "rollback-activation-failed", "rollback-restart-pending",
        "rollback-first-boot-observed", "rollback-verifying",
        "rollback-verification-failed", "rolled-back"
      )) then
        .rollback != null
      elif .state == "aborted" then
        ((.abort.direction == "forward" and .rollback == null) or
          (.abort.direction == "rollback" and .rollback != null))
      elif .state == "cancelled" then
        .rollback == null and .abort == null
      else
        false
      end) and
      (if (.state | IN(
        "prepared", "apply-intent", "activating", "activation-indeterminate",
        "activation-failed", "restart-pending"
      )) then
        .bootInstances.firstBoot == null
      elif .state == "first-boot-observed" then
        .effect == "boot-two-stage" and .bootInstances.firstBoot != null
      elif ((.state | IN("verifying", "verification-failed", "complete")) and
        .effect == "boot-two-stage") then
        .bootInstances.firstBoot != null
      else
        true
      end) and
      (.activation.status | IN("pending", "succeeded", "failed", "indeterminate")) and
      (.activation.exitCode == null or
        (.activation.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .)) and
      (.verification.status | IN("pending", "succeeded", "failed")) and
      (.verification.exitCode == null or
        (.verification.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .)) and
      (.verification | check_ids) and
      (.failureStage == null or (.failureStage | type == "string" and length > 0)) and
      (if .schemaVersion == 3 then
        (.activationDriver.protocol == "nixos-rebuild-ng-profile-before-activation-v1") and
        (.activationDriver.executable | type == "string" and length > 0 and
          (contains("\n") | not)) and
        (.activation.attempts | type == "array") and
        (.activation | result_matches_attempts(
          $receipt.migration != null and $receipt.migration.fromSchema == 2)) and
        all(.activation.attempts[];
          attempt($receipt.transactionId; "forward"; $receipt.candidate; $receipt.action)) and
        (.cancellation == null or (
          .cancellation.kind == "manual-zero-effect" and
          (.cancellation.fromState | IN(
            "prepared", "activation-failed", "activation-indeterminate"
          )) and
          .cancellation.boundary == "before-profile-commit" and
          .cancellation.driverContract ==
            "nixos-rebuild-ng-profile-before-activation-v1" and
          (.cancellation.expectedRuntime | runtime_snapshot) and
          (.cancellation.observedRuntime | runtime_snapshot) and
          .cancellation.expectedRuntime == .cancellation.observedRuntime and
          .cancellation.expectedRuntime == .activationBaseline and
          (.cancellation.expectedBootInstance | type == "object" and
            (.kernelBootId | type == "string" and
              test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
            (.userspaceTimestampMonotonic | type == "string" and test("^[1-9][0-9]*$"))) and
          .cancellation.observedBootInstance == .cancellation.expectedBootInstance and
          .cancellation.expectedBootInstance == .bootInstances.beforeApply and
          (.cancellation.requestedAt | type == "string" and length > 0)
        )) and
        (.migration == null or (
          .migration.fromSchema == 2 and
          .migration.classification == "before-profile-commit" and
          (.migration.receipt |
            artifact("migrations/" + $receipt.transactionId + "/schema-2.json")) and
          (.migration.sourceTemplateSha256 | type == "string" and
            test("^[0-9a-f]{64}$")) and
          (.migration.candidateHelperSha256 | type == "string" and
            test("^[0-9a-f]{64}$")) and
          (.migration.nixpkgsRev | type == "string" and test("^[0-9a-f]{40}$")) and
          .migration.driverContract ==
            "nixos-rebuild-ng-profile-before-activation-v1" and
          (.migration.driverExecutable | type == "string" and length > 0 and
            (contains("\n") | not)) and
          (.migration.migratedAt | type == "string" and length > 0)
        )) and
        (if .rollback == null then true else
          (.rollback.activation.attempts | type == "array") and
          (.rollback.activation | result_matches_attempts(false)) and
          all(.rollback.activation.attempts[];
            attempt($receipt.transactionId; "rollback";
              $receipt.rollback.target; $receipt.rollback.action))
        end) and
        ((.activation.attempts +
          (if .rollback == null then [] else .rollback.activation.attempts end)) as $attempts |
          ([$attempts[].number] == [range(1; ($attempts | length) + 1)]) and
          ([$attempts[].attemptId] | length == (unique | length)))
      else
        true
      end) and
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
          "rollback-intent", "rollback-activating", "rollback-activation-indeterminate",
          "rollback-activation-failed", "rollback-restart-pending"
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
        (.rollback.activation.status | IN("pending", "succeeded", "failed", "indeterminate")) and
        (.rollback.activation.exitCode == null or
          (.rollback.activation.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .))
      )) and
      (if .state == "prepared" then
        (.activation | pending_result) and
        (.schemaVersion == 2 or (.activation.attempts | length) == 0) and
        (.verification | pending_result) and .failureStage == null
      elif .state == "apply-intent" then
        (.activation | pending_result) and
        (.schemaVersion == 2 or (
          (.activation.attempts | length) > 0 and
          .activation.attempts[-1].status == "intent")) and
        (.verification | pending_result) and .failureStage == null
      elif .state == "activating" then
        (.activation | pending_result) and (.activation.attempts | length) > 0 and
        .activation.attempts[-1].status == "running" and
        (.activation | pending_result) and
        (.verification | pending_result) and
        .failureStage == null
      elif .state == "activation-indeterminate" then
        (.activation | indeterminate_result) and
        (.verification | pending_result) and
        .activation.attempts[-1].status == "indeterminate" and
        .failureStage == "activation-indeterminate"
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
        ((.rollback.activation.attempts | length) == 0 or
          .rollback.activation.attempts[-1].status == "intent") and
        (.verification | pending_result) and .failureStage == null
      elif .state == "rollback-activating" then
        (.rollback.activation | pending_result) and
        (.rollback.activation.attempts | length) > 0 and
        .rollback.activation.attempts[-1].status == "running" and
        (.rollback.activation | pending_result) and
        (.verification | pending_result) and
        .failureStage == null
      elif .state == "rollback-activation-indeterminate" then
        (.rollback.activation | indeterminate_result) and
        (.verification | pending_result) and
        .rollback.activation.attempts[-1].status == "indeterminate" and
        .failureStage == "rollback-activation-indeterminate"
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
          ((.activation | pending_result) or (.activation | failed_result) or
            (.activation | indeterminate_result))
        else
          ((.rollback.activation | pending_result) or
            (.rollback.activation | failed_result) or
            (.rollback.activation | indeterminate_result))
          end)
      elif .state == "cancelled" then
        .schemaVersion == 3 and
        .cancellation != null and
        .rollback == null and .abort == null and
        .failureStage == null and
        (.verification | pending_result) and
        (if .cancellation.fromState == "prepared" then
          (.activation | pending_result) and (.activation.attempts | length) == 0
        elif .cancellation.fromState == "activation-failed" then
          (.activation | failed_result) and
          (((.activation.attempts | length) > 0 and
              .activation.attempts[-1].status == "failed" and
              .activation.attempts[-1].boundary == "before-profile-commit") or
            ((.activation.attempts | length) == 0 and
              .migration.classification == "before-profile-commit"))
        else
          (.activation | indeterminate_result) and
          .activation.attempts[-1].status == "indeterminate" and
          .activation.attempts[-1].boundary == "before-profile-commit"
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
      elif .state == "cancelled" then
        .failureStage == null and
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
      [[ $state == complete || $state == rolled-back || $state == aborted || $state == cancelled ]] || return 1
    fi
    rm -r -- "$transaction_roots" || return 1
    sync "$state_root/roots" || return 1
  done
}
