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
  local receipt=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local expected_mode=${6:-600} metadata

  [[ -f $receipt && ! -L $receipt ]] || {
    echo "dotfiles-rebuild-receipt: receipt must be a regular file: $receipt" >&2
    return 1
  }
  metadata=$(stat -c '%u|%a|%h' -- "$receipt")
  [[ $metadata == "$expected_uid|$expected_mode|1" ]] || {
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
      (.schemaVersion | IN(2, 3, 4)) and
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
      (.lineage == null or (
        .lineage as $lineage |
        .schemaVersion == 4 and
        $lineage.kind == "verification-successor" and
        $lineage.protocolVersion == 2 and
        ($lineage.parentTransactionId | type == "string" and test("^[0-9a-f]{32}$")) and
        $lineage.parentTransactionId != $receipt.transactionId and
        ($lineage.parentReceipt |
          artifact("lineage/" + $lineage.parentTransactionId + "/verification-failed.json")) and
        ($lineage.execution | keys) == ["helpers", "manifest"] and
        ($lineage.execution.helpers | keys) == ["doctor", "rebuild", "syncImages"] and
        all($lineage.execution.helpers | to_entries[];
          (.value | keys) == ["bytes", "canonicalPath", "logicalPath", "sha256"] and
          (.value.logicalPath ==
            ($receipt.candidate + "/sw/bin/dotfiles-" +
              (if .key == "syncImages" then "sync-images" else .key end))) and
          (.value.canonicalPath | type == "string" and startswith($store)) and
          (.value.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.value.bytes | type == "number" and . >= 0 and floor == .)) and
        ($lineage.execution.manifest | keys) ==
          ["bytes", "canonicalPath", "logicalPath", "sha256"] and
        $lineage.execution.manifest.logicalPath ==
          ($receipt.candidate + "/etc/dotfiles/oci-images.json") and
        ($lineage.execution.manifest.canonicalPath |
          type == "string" and startswith($store)) and
        ($lineage.execution.manifest.sha256 |
          type == "string" and test("^[0-9a-f]{64}$")) and
        ($lineage.execution.manifest.bytes |
          type == "number" and . >= 0 and floor == .) and
        ($lineage.createdAt | type == "string" and length > 0) and
        $receipt.candidate != $receipt.recoveryTarget
      )) and
      (.supersession == null or (
        .schemaVersion == 4 and
        .supersession.kind == "verification-successor" and
        .supersession.fromState == "verification-failed" and
        (.supersession.successorTransactionId |
          type == "string" and test("^[0-9a-f]{32}$")) and
        .supersession.successorTransactionId != $receipt.transactionId and
        ([.supersession.successorSource, .supersession.successorCandidate] |
          all(type == "string" and startswith($store))) and
        .supersession.successorCandidate != $receipt.candidate and
        (.supersession.originalReceipt |
          artifact("lineage/" + $receipt.transactionId + "/verification-failed.json")) and
        (.supersession.createdAt | type == "string" and length > 0)
      )) and
      ((.state == "superseded") == (.supersession != null)) and
      (.schemaVersion != 4 or
        (if .state == "superseded" then
          .supersession != null
        else
          .lineage != null and .supersession == null
        end)) and
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
        "rollback-verification-failed", "complete", "rolled-back", "aborted", "cancelled",
        "superseded"
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
      elif .state == "superseded" then
        .rollback == null and .abort == null and .cancellation == null
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
      (if (.schemaVersion | IN(3, 4)) then
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
        (.schemaVersion | IN(3, 4)) and
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
      elif .state == "superseded" then
        .schemaVersion == 4 and
        (.activation | succeeded_result) and
        (.verification | failed_result) and
        .failureStage == "doctor" and
        .rollback == null and .abort == null and .cancellation == null and
        .supersession != null
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
      elif .state == "superseded" then
        .failureStage == "doctor" and
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

dotfiles_rebuild_read_active_publication_id() {
  local state_root=$1 expected_uid=$2 expected_gid=$3
  local active_receipt=$state_root/active.json metadata transaction_id

  [[ -f $active_receipt && ! -L $active_receipt ]] || return 1
  metadata=$(stat -c '%u|%g|%a|%h' -- "$active_receipt") || return 1
  [[ $metadata == "$expected_uid|$expected_gid|600|1" ||
    $metadata == "$expected_uid|$expected_gid|600|2" ]] || return 1
  transaction_id=$(jq -er '.transactionId' "$active_receipt") || return 1
  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$transaction_id"
}

dotfiles_rebuild_validate_active_publish_temp() {
  local temporary=$1 state_root=$2 active_id=$3 expected_uid=$4 expected_gid=$5
  local active_receipt=$state_root/active.json name kind bound_id metadata content_id
  local temporary_identity active_identity

  [[ $temporary == "$state_root/"* ]] || return 1
  name=${temporary##*/}
  if [[ $name =~ ^\.active-(create|update)-([0-9a-f]{32})\.([A-Za-z0-9]{6})$ ]]; then
    kind=${BASH_REMATCH[1]}
    bound_id=${BASH_REMATCH[2]}
  elif [[ $name =~ ^\.active\.([A-Za-z0-9]{6})$ ]]; then
    kind=legacy
    bound_id=$active_id
  else
    return 1
  fi
  [[ -f $temporary && ! -L $temporary ]] || return 1
  metadata=$(stat -c '%u|%g|%a|%h' -- "$temporary") || return 1
  [[ $metadata == "$expected_uid|$expected_gid|600|1" ||
    ( $kind == legacy && -n $active_id &&
      $metadata == "$expected_uid|$expected_gid|600|2" ) ]] || return 1

  case $kind in
    create)
      [[ -z $active_id && $(stat -c '%h' -- "$temporary") == 1 ]] || return 1
      ;;
    update)
      [[ -n $active_id && $bound_id == "$active_id" &&
        $(stat -c '%h' -- "$temporary") == 1 ]] || return 1
      ;;
    legacy)
      if [[ -z $active_id ]]; then
        [[ $(stat -c '%h' -- "$temporary") == 1 ]] || return 1
      elif [[ $(stat -c '%h' -- "$temporary") == 2 ]]; then
        [[ -f $active_receipt && ! -L $active_receipt ]] || return 1
        temporary_identity=$(stat -c '%d|%i' -- "$temporary") || return 1
        active_identity=$(stat -c '%d|%i' -- "$active_receipt") || return 1
        [[ $temporary_identity == "$active_identity" ]] || return 1
      else
        temporary_identity=$(stat -c '%d|%i' -- "$temporary") || return 1
        active_identity=$(stat -c '%d|%i' -- "$active_receipt") || return 1
        [[ $temporary_identity != "$active_identity" ]] || return 1
      fi
      ;;
  esac

  content_id=$(jq -er '.transactionId // empty' "$temporary" 2>/dev/null || true)
  if [[ -n $content_id ]]; then
    [[ $content_id =~ ^[0-9a-f]{32}$ ]] || return 1
    if [[ $kind != legacy || -n $active_id ]]; then
      [[ $content_id == "$bound_id" ]] || return 1
    fi
  fi
}

# Returns 0 for no residue, 3 for authenticated incomplete publication, and 2
# for a name, identity, or active-transaction relationship outside the contract.
dotfiles_rebuild_inspect_active_publish_temps() {
  local state_root=$1 active_id=$2 expected_uid=$3 expected_gid=$4 temporary found=0

  [[ -z $active_id || $active_id =~ ^[0-9a-f]{32}$ ]] || return 2
  for temporary in "$state_root"/.active*; do
    [[ -e $temporary || -L $temporary ]] || continue
    (( found += 1 ))
    [[ $found -eq 1 ]] || return 2
    dotfiles_rebuild_validate_active_publish_temp \
      "$temporary" "$state_root" "$active_id" "$expected_uid" "$expected_gid" || return 2
  done
  [[ $found -eq 0 ]] || return 3
}

dotfiles_rebuild_cleanup_active_publish_temps() {
  local state_root=$1 active_id=$2 expected_uid=$3 expected_gid=$4 temporary inspection_status

  if dotfiles_rebuild_inspect_active_publish_temps \
    "$state_root" "$active_id" "$expected_uid" "$expected_gid"; then
    return 0
  else
    inspection_status=$?
    [[ $inspection_status -eq 3 ]] || return 1
  fi
  for temporary in "$state_root"/.active*; do
    [[ -e $temporary || -L $temporary ]] || continue
    dotfiles_rebuild_validate_active_publish_temp \
      "$temporary" "$state_root" "$active_id" "$expected_uid" "$expected_gid" || return 1
    rm -- "$temporary" || return 1
  done
  sync "$state_root" || return 1
}

dotfiles_rebuild_create_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local active_receipt=$state_root/active.json temporary receipt_data transaction_id

  [[ ! -e $active_receipt && ! -L $active_receipt ]] || {
    echo 'dotfiles-rebuild-receipt: an active receipt already exists' >&2
    return 1
  }
  receipt_data=$(cat) || return 1
  transaction_id=$(jq -er '.transactionId' <<< "$receipt_data") || return 1
  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  temporary=$(mktemp "$state_root/.active-create-$transaction_id.XXXXXX") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  printf '%s\n' "$receipt_data" > "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_receipt_file \
    "$temporary" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || {
    rm -f -- "$temporary"
    return 1
  }
  if ! dotfiles_atomic_publish_no_replace "$temporary" "$active_receipt" "$state_root"; then
    echo 'dotfiles-rebuild-receipt: failed to publish the active receipt' >&2
    return 1
  fi
}

dotfiles_rebuild_update_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  shift 5
  local active_receipt=$state_root/active.json temporary transaction_id

  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  transaction_id=$(jq -er '.transactionId' "$active_receipt") || return 1
  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  temporary=$(mktemp "$state_root/.active-update-$transaction_id.XXXXXX") || return 1
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
  dotfiles_atomic_publish_replace "$temporary" "$active_receipt" "$state_root"
}

dotfiles_rebuild_validate_gc_auto_roots_directory() {
  local nix_gc_auto_roots_dir=$1

  [[ -d $nix_gc_auto_roots_dir && ! -L $nix_gc_auto_roots_dir ]]
}

dotfiles_rebuild_ensure_gc_roots() {
  local state_root=$1 transaction_id=$2 nix_store_dir=$3 nix_gc_auto_roots_dir=$4
  shift 4
  local transaction_roots=$state_root/roots/$transaction_id label target root metadata
  local auto_root auto_name literal entry name
  local -A target_by_label=() label_by_root=() auto_count_by_label=()

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  dotfiles_rebuild_validate_gc_auto_roots_directory \
    "$nix_gc_auto_roots_dir" || return 1
  if [[ ! -e $transaction_roots && ! -L $transaction_roots ]]; then
    mkdir -m 0700 -- "$transaction_roots" || return 1
    sync "$state_root/roots" || return 1
  fi
  [[ -d $transaction_roots && ! -L $transaction_roots ]] || return 1
  metadata=$(stat -c '%u|%g|%a' -- "$transaction_roots")
  [[ $metadata == "$EUID|$(id -g)|700" ]] || return 1

  while (( $# > 0 )); do
    [[ $# -ge 2 ]] || return 1
    label=$1
    target=$2
    shift 2
    case $label in
      source | candidate | recovery-target | previous-booted | displaced-profile) ;;
      *) return 1 ;;
    esac
    [[ -z ${target_by_label[$label]+x} && $target == "$nix_store_dir/"* && -e $target ]] || return 1
    root=$transaction_roots/$label
    nix-store --add-root "$root" --realise "$target" >/dev/null || return 1
    [[ -L $root && $(readlink -- "$root") == "$target" ]] || return 1
    metadata=$(stat -c '%u|%g|%a|%h' -- "$root") || return 1
    [[ $metadata == "$EUID|$(id -g)|777|1" ]] || return 1
    target_by_label[$label]=$target
    label_by_root[$root]=$label
  done
  [[ ${#target_by_label[@]} -eq 5 ]] || return 1
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    case $name in
      source | candidate | recovery-target | previous-booted | displaced-profile) ;;
      *) return 1 ;;
    esac
    [[ -n ${target_by_label[$name]+x} && -L $entry &&
      $(readlink -- "$entry") == "${target_by_label[$name]}" ]] || return 1
    metadata=$(stat -c '%u|%g|%a|%h' -- "$entry") || return 1
    [[ $metadata == "$EUID|$(id -g)|777|1" ]] || return 1
  done < <(find "$transaction_roots" -mindepth 1 -maxdepth 1 -print0)
  [[ $(find "$transaction_roots" -mindepth 1 -maxdepth 1 -printf . | wc -c) -eq 5 ]] || return 1
  for auto_root in "$nix_gc_auto_roots_dir"/*; do
    [[ -e $auto_root || -L $auto_root ]] || continue
    [[ -L $auto_root ]] || return 1
    literal=$(readlink -- "$auto_root") || return 1
    [[ $literal == "$transaction_roots/"* ]] || continue
    [[ -n ${label_by_root[$literal]+x} ]] || return 1
    label=${label_by_root[$literal]}
    auto_name=${auto_root##*/}
    [[ $auto_name =~ ^[0-9abcdfghijklmnpqrsvwxyz]{32}$ ]] || return 1
    metadata=$(stat -c '%u|%g|%a|%h' -- "$auto_root") || return 1
    [[ $metadata =~ ^[0-9]+\|[0-9]+\|777\|1$ ]] || return 1
    (( auto_count_by_label[$label] += 1 ))
  done
  for label in "${!target_by_label[@]}"; do
    [[ ${auto_count_by_label[$label]:-0} -eq 1 ]] || return 1
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

dotfiles_rebuild_validate_lineage_directory() {
  local directory=$1 expected_uid=$2 expected_gid=$3 metadata

  [[ -d $directory && ! -L $directory ]] || return 1
  metadata=$(stat -c '%u|%g|%a' -- "$directory") || return 1
  [[ $metadata == "$expected_uid|$expected_gid|700" ]]
}

dotfiles_rebuild_preserve_verification_parent() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 transaction_id=$4 source_receipt=$5
  local nix_store_dir=$6 child_id=$7 lineage_root transaction_root target temporary parent
  local expected_worktree expected_user

  [[ $transaction_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $transaction_id != "$child_id" ]] || return 1
  expected_worktree=$(jq -r '.worktree' "$source_receipt") || return 1
  expected_user=$(jq -r '.transactionUser' "$source_receipt") || return 1
  dotfiles_rebuild_validate_receipt_file \
    "$source_receipt" "$expected_uid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" || return 1
  [[ $(jq -r '.schemaVersion' "$source_receipt") =~ ^(3|4)$ &&
    $(jq -r '.transactionId' "$source_receipt") == "$transaction_id" &&
    $(jq -r '.state' "$source_receipt") == verification-failed ]] || return 1

  lineage_root=$state_root/lineage
  transaction_root=$lineage_root/$transaction_id
  for directory in "$lineage_root" "$transaction_root"; do
    if [[ ! -e $directory && ! -L $directory ]]; then
      parent=${directory%/*}
      mkdir -m 0700 -- "$directory" || return 1
      sync "$parent" || return 1
    fi
    dotfiles_rebuild_validate_lineage_directory \
      "$directory" "$expected_uid" "$expected_gid" || return 1
  done

  target=$transaction_root/verification-failed.json
  if [[ -e $target || -L $target ]]; then
    dotfiles_rebuild_validate_lineage_artifact_file \
      "$target" "$expected_uid" "$expected_gid" || return 1
    dotfiles_rebuild_validate_receipt_file \
      "$target" "$expected_uid" "$expected_worktree" \
      "$nix_store_dir" "$expected_user" 400 || return 1
    cmp -s -- "$source_receipt" "$target" || return 1
    sync --data "$target" || return 1
    sync "$transaction_root" || return 1
    sync "$lineage_root" || return 1
    printf '%s\n' "$target"
    return 0
  fi

  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" lineage "$transaction_id" "$child_id")") || return 1
  chmod 0600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  cp -- "$source_receipt" "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 0400 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_receipt_file \
    "$temporary" "$expected_uid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" 400 || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_lineage_artifact_file \
    "$temporary" "$expected_uid" "$expected_gid" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$transaction_root" || return 1
  sync "$lineage_root" || return 1
  sync "$state_root" || return 1
  printf '%s\n' "$target"
}

dotfiles_rebuild_verify_successor_binding() {
  local state_root=$1 parent_receipt=$2 expected_uid=$3 expected_worktree=$4
  local nix_store_dir=$5 expected_user=$6 parent_id expected_id expected_source
  local expected_candidate expected_parent_metadata expected_created_at candidate_file candidate_parent child
  local match_count=0

  parent_id=$(jq -er '.transactionId' <<< "$parent_receipt") || return 1
  expected_id=$(jq -er '.supersession.successorTransactionId' <<< "$parent_receipt") || return 1
  expected_source=$(jq -er '.supersession.successorSource' <<< "$parent_receipt") || return 1
  expected_candidate=$(jq -er '.supersession.successorCandidate' <<< "$parent_receipt") || return 1
  expected_parent_metadata=$(jq -c '.supersession.originalReceipt' <<< "$parent_receipt") || return 1
  expected_created_at=$(jq -er '.supersession.createdAt' <<< "$parent_receipt") || return 1

  for candidate_file in "$state_root/active.json" "$state_root"/receipts/*.json; do
    [[ -e $candidate_file || -L $candidate_file ]] || continue
    dotfiles_rebuild_validate_receipt_file \
      "$candidate_file" "$expected_uid" "$expected_worktree" \
      "$nix_store_dir" "$expected_user" || return 1
    candidate_parent=$(jq -r '.lineage.parentTransactionId // empty' \
      "$candidate_file" 2>/dev/null) || return 1
    [[ $candidate_parent == "$parent_id" ]] || continue
    child=$(cat -- "$candidate_file") || return 1
    if [[ $candidate_file != "$state_root/active.json" ]]; then
      [[ $candidate_file == "$state_root/receipts/$expected_id.json" ]] || return 1
    fi
    (( match_count += 1 ))
    [[ $match_count -eq 1 ]] || return 1
    jq -e \
      --arg childId "$expected_id" \
      --arg childSource "$expected_source" \
      --arg childCandidate "$expected_candidate" \
      --arg parentId "$parent_id" \
      --arg createdAt "$expected_created_at" \
      --argjson parentReceipt "$expected_parent_metadata" '
        .transactionId == $childId and
        .source == $childSource and
        .candidate == $childCandidate and
        .lineage.parentTransactionId == $parentId and
        .lineage.parentReceipt == $parentReceipt and
        .lineage.createdAt == $createdAt
      ' <<< "$child" >/dev/null || return 1
  done
  [[ $match_count -eq 1 ]]
}

dotfiles_rebuild_read_lineage_artifact() {
  local state_root=$1 parent_id=$2 metadata=$3 expected_uid=$4 expected_gid=$5
  local expected_worktree=$6 nix_store_dir=$7 expected_user=$8 path file expected_sha
  local expected_bytes actual_sha actual_bytes

  path=$(jq -er '.path' <<< "$metadata") || return 1
  [[ $path == "lineage/$parent_id/verification-failed.json" ]] || return 1
  dotfiles_rebuild_validate_lineage_directory \
    "$state_root/lineage" "$expected_uid" "$expected_gid" || return 1
  dotfiles_rebuild_validate_lineage_directory \
    "$state_root/lineage/$parent_id" "$expected_uid" "$expected_gid" || return 1
  file=$state_root/$path
  dotfiles_rebuild_validate_lineage_artifact_file \
    "$file" "$expected_uid" "$expected_gid" || return 1
  dotfiles_rebuild_validate_receipt_file \
    "$file" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" 400 || return 1
  expected_sha=$(jq -er '.sha256' <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes' <<< "$metadata") || return 1
  actual_sha=$(sha256sum "$file" | cut -d ' ' -f 1) || return 1
  actual_bytes=$(stat -c '%s' -- "$file") || return 1
  [[ $actual_sha == "$expected_sha" && $actual_bytes == "$expected_bytes" ]] || return 1
  cat -- "$file"
}

dotfiles_rebuild_verify_receipt_attempt_evidence() {
  local state_root=$1 receipt=$2 expected_uid=$3 expected_gid=$4
  local attempt_projection=$receipt schema

  schema=$(jq -er '.schemaVersion' <<< "$receipt") || return 1
  if [[ $schema -eq 4 ]]; then
    attempt_projection=$(jq -c '.schemaVersion = 3' <<< "$receipt") || return 1
  fi
  dotfiles_rebuild_verify_receipt_artifacts \
    "$state_root" "$attempt_projection" "$expected_uid" "$expected_gid"
}

dotfiles_rebuild_verify_receipt_lineage_impl() {
  local state_root=$1 receipt=$2 expected_uid=$3 expected_gid=$4 expected_worktree=$5
  local nix_store_dir=$6 expected_user=$7 visited=$8 skip_identity=$9 receipt_id
  local parent_id metadata parent expected schema has_lineage has_supersession

  receipt_id=$(jq -er '.transactionId' <<< "$receipt") || return 1
  [[ $receipt_id =~ ^[0-9a-f]{32}$ ]] || return 1
  if [[ $skip_identity -eq 0 ]]; then
    [[ $visited != *"|$receipt_id|"* ]] || return 1
    visited+="|$receipt_id|"
  fi
  schema=$(jq -er '.schemaVersion' <<< "$receipt") || return 1
  has_lineage=$(jq -r '.lineage != null' <<< "$receipt") || return 1
  has_supersession=$(jq -r '.supersession != null' <<< "$receipt") || return 1
  if [[ $schema -eq 4 && $has_lineage != true && $has_supersession != true ]]; then
    return 1
  fi

  if [[ $has_lineage == true ]]; then
    parent_id=$(jq -er '.lineage.parentTransactionId' <<< "$receipt") || return 1
    metadata=$(jq -c '.lineage.parentReceipt' <<< "$receipt") || return 1
    parent=$(dotfiles_rebuild_read_lineage_artifact \
      "$state_root" "$parent_id" "$metadata" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$expected_user") || return 1
    jq -e --arg parentId "$parent_id" '
        (.schemaVersion | IN(3, 4)) and
        .transactionId == $parentId and
        .state == "verification-failed" and
        .activation.status == "succeeded" and
        .activation.attempts[-1].status == "succeeded" and
        .activation.attempts[-1].boundary == "after-profile-commit" and
        .verification.status == "failed" and
        .failureStage == "doctor" and
        .rollback == null and .abort == null and .cancellation == null and
        .sopsEnrollmentTransactionId == null
      ' <<< "$parent" >/dev/null || return 1
    dotfiles_rebuild_verify_receipt_attempt_evidence \
      "$state_root" "$parent" "$expected_uid" "$expected_gid" || return 1
    [[ $(jq -r '.candidate' <<< "$parent") == \
      $(jq -r '.recoveryTarget' <<< "$receipt") ]] || return 1
    dotfiles_rebuild_verify_receipt_lineage_impl \
      "$state_root" "$parent" "$expected_uid" "$expected_gid" "$expected_worktree" \
      "$nix_store_dir" "$expected_user" "$visited" 0 || return 1
  fi

  if [[ $has_supersession != true ]]; then
    return 0
  fi

  parent_id=$receipt_id
  metadata=$(jq -c '.supersession.originalReceipt' <<< "$receipt") || return 1
  parent=$(dotfiles_rebuild_read_lineage_artifact \
    "$state_root" "$parent_id" "$metadata" "$expected_uid" "$expected_gid" \
    "$expected_worktree" "$nix_store_dir" "$expected_user") || return 1
  jq -e --arg parentId "$parent_id" '
      (.schemaVersion | IN(3, 4)) and
      .transactionId == $parentId and
      .state == "verification-failed" and
      .activation.status == "succeeded" and
      .activation.attempts[-1].status == "succeeded" and
      .activation.attempts[-1].boundary == "after-profile-commit" and
      .verification.status == "failed" and
      .failureStage == "doctor" and
      .rollback == null and .abort == null and .cancellation == null and
      .sopsEnrollmentTransactionId == null
    ' <<< "$parent" >/dev/null || return 1
  expected=$(jq -c \
    --arg successorTransactionId "$(jq -r '.supersession.successorTransactionId' <<< "$receipt")" \
    --arg successorSource "$(jq -r '.supersession.successorSource' <<< "$receipt")" \
    --arg successorCandidate "$(jq -r '.supersession.successorCandidate' <<< "$receipt")" \
    --argjson originalReceipt "$metadata" \
    --arg timestamp "$(jq -r '.supersession.createdAt' <<< "$receipt")" '
      .schemaVersion = 4 |
      .state = "superseded" |
      .supersession = {
        kind: "verification-successor",
        fromState: "verification-failed",
        successorTransactionId: $successorTransactionId,
        successorSource: $successorSource,
        successorCandidate: $successorCandidate,
        originalReceipt: $originalReceipt,
        createdAt: $timestamp
      } |
      .updatedAt = $timestamp |
      .finishedAt = $timestamp
    ' <<< "$parent") || return 1
  [[ $(jq -cS . <<< "$receipt") == "$(jq -cS . <<< "$expected")" ]] || return 1
  dotfiles_rebuild_verify_receipt_lineage_impl \
    "$state_root" "$parent" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" "$visited" 1 || return 1
  dotfiles_rebuild_verify_successor_binding \
    "$state_root" "$receipt" "$expected_uid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user"
}

dotfiles_rebuild_verify_receipt_lineage() {
  local state_root=$1 receipt=$2 expected_uid=$3 expected_gid=$4 expected_worktree=$5
  local nix_store_dir=$6 expected_user=$7
  dotfiles_rebuild_verify_receipt_lineage_impl \
    "$state_root" "$receipt" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" '|' 0
}

dotfiles_rebuild_verify_receipt_evidence() {
  local state_root=$1 receipt=$2 expected_uid=$3 expected_gid=$4 expected_worktree=$5
  local nix_store_dir=$6 expected_user=$7

  dotfiles_rebuild_verify_receipt_attempt_evidence \
    "$state_root" "$receipt" "$expected_uid" "$expected_gid" || return 1
  dotfiles_rebuild_verify_receipt_lineage \
    "$state_root" "$receipt" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user"
}

dotfiles_rebuild_handoff_active_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local parent_id=$6 parent_sha=$7 expected_child_sha=${8:-} expected_child_bytes=${9:-}
  local child_id=${10} active_receipt=$state_root/active.json temporary child expected_gid

  [[ $parent_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $parent_id != "$child_id" && $parent_sha =~ ^[0-9a-f]{64}$ ]] || return 1
  if [[ -n $expected_child_sha || -n $expected_child_bytes ]]; then
    [[ $expected_child_sha =~ ^[0-9a-f]{64}$ &&
      $expected_child_bytes =~ ^[0-9]+$ ]] || return 1
  fi
  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  [[ $(jq -r '.transactionId' "$active_receipt") == "$parent_id" &&
    $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$parent_sha" ]] || return 1

  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" handoff "$parent_id" "$child_id")") || return 1
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
  if [[ -n $expected_child_sha ]] &&
    [[ $(sha256sum "$temporary" | cut -d ' ' -f 1) != "$expected_child_sha" ||
      $(stat -c '%s' -- "$temporary") != "$expected_child_bytes" ]]; then
    rm -f -- "$temporary"
    return 2
  fi
  child=$(cat -- "$temporary") || {
    rm -f -- "$temporary"
    return 1
  }
  [[ $(jq -r '.transactionId' <<< "$child") == "$child_id" ]] || {
    rm -f -- "$temporary"
    return 2
  }
  expected_gid=$(stat -c '%g' -- "$state_root") || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_verify_receipt_lineage \
    "$state_root" "$child" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  dotfiles_rebuild_validate_receipt_file \
    "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || {
    rm -f -- "$temporary"
    return 1
  }
  [[ $(jq -r '.transactionId' "$active_receipt") == "$parent_id" &&
    $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$parent_sha" ]] || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T --no-copy -- "$temporary" "$active_receipt" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$active_receipt" || return 1
  sync "$state_root" || return 1
}

dotfiles_rebuild_publish_archived_receipt() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local transaction_id=$6 child_id=$7 target temporary

  [[ $transaction_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $transaction_id != "$child_id" ]] || return 1
  target=$state_root/receipts/$transaction_id.json
  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" archive "$transaction_id" "$child_id")") || return 1
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
  [[ $(jq -r '.transactionId' "$temporary") == "$transaction_id" &&
    $(jq -r '.supersession.successorTransactionId // empty' "$temporary") == "$child_id" ]] || {
    rm -f -- "$temporary"
    return 1
  }
  if [[ -e $target || -L $target ]]; then
    dotfiles_rebuild_validate_receipt_file \
      "$target" "$expected_uid" "$expected_worktree" "$nix_store_dir" "$expected_user" || {
      rm -f -- "$temporary"
      return 1
    }
    cmp -s -- "$temporary" "$target" || {
      rm -f -- "$temporary"
      return 1
    }
    rm -f -- "$temporary" || return 1
    sync --data "$target" || return 1
    sync "$state_root/receipts" || return 1
    sync "$state_root" || return 1
    return 0
  fi
  sync --data "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$state_root/receipts" || return 1
  sync "$state_root" || return 1
}

dotfiles_rebuild_remove_gc_roots() {
  local state_root=$1 transaction_id=$2 expected_uid=${3:-} expected_gid=${4:-} transaction_roots

  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || return 1
  transaction_roots=$state_root/roots/$transaction_id
  if [[ ! -e $transaction_roots && ! -L $transaction_roots ]]; then
    return 0
  fi
  [[ -d $transaction_roots && ! -L $transaction_roots ]] || return 1
  if [[ -n $expected_uid || -n $expected_gid ]]; then
    [[ -n $expected_uid && -n $expected_gid ]] || return 1
    dotfiles_rebuild_validate_lineage_directory \
      "$state_root/roots" "$expected_uid" "$expected_gid" || return 1
    dotfiles_rebuild_validate_lineage_directory \
      "$transaction_roots" "$expected_uid" "$expected_gid" || return 1
  fi
  rm -r -- "$transaction_roots" || return 1
  sync "$state_root/roots" || return 1
}

dotfiles_rebuild_cleanup_orphan_gc_roots() {
  local state_root=$1 expected_uid=$2 expected_worktree=$3 nix_store_dir=$4 expected_user=$5
  local transaction_roots transaction_id archived_receipt metadata state receipt expected_gid

  [[ -d $state_root/roots && ! -L $state_root/roots ]] || return 0
  expected_gid=$(stat -c '%g' -- "$state_root") || return 1
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
      [[ $state == complete || $state == rolled-back || $state == aborted || $state == cancelled ||
        $state == superseded ]] || return 1
      if [[ $state == superseded ]]; then
        receipt=$(cat -- "$archived_receipt") || return 1
        dotfiles_rebuild_verify_receipt_lineage \
          "$state_root" "$receipt" "$expected_uid" "$expected_gid" "$expected_worktree" \
          "$nix_store_dir" "$expected_user" || return 1
      fi
    fi
    rm -r -- "$transaction_roots" || return 1
    sync "$state_root/roots" || return 1
  done
}

# Successor protocol v2 uses one regular file for each durable capability.  The
# preparation names the edge before any cleanup target exists, the live
# authorization is published last, and an erasure record irrevocably revokes it.
dotfiles_rebuild_validate_protocol_file() {
  local file=$1 expected_uid=$2 expected_gid=$3 expected_mode=${4:-400} metadata
  [[ -f $file && ! -L $file ]] || return 1
  metadata=$(stat -c '%u|%g|%a|%h' -- "$file") || return 1
  [[ $metadata == "$expected_uid|$expected_gid|$expected_mode|1" ]]
}

dotfiles_rebuild_validate_lineage_artifact_file() {
  local file=$1 expected_uid=$2 expected_gid=$3
  dotfiles_rebuild_validate_protocol_file \
    "$file" "$expected_uid" "$expected_gid" 400
}

dotfiles_rebuild_successor_publish_temp_template() {
  local state_root=$1 kind=$2 parent_id=$3 child_id=$4
  case $kind in
    lineage | preparation | authorization | handoff | erasure | archive) ;;
    *) return 1 ;;
  esac
  [[ $parent_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $parent_id != "$child_id" ]] || return 1
  printf '%s/.successor-%s-%s-%s.XXXXXX\n' \
    "$state_root" "$kind" "$parent_id" "$child_id"
}

dotfiles_rebuild_validate_successor_publish_temp() {
  local file=$1 active_id=$2 active_schema=$3 direct_parent=$4 expected_uid=$5 expected_gid=$6
  local name metadata kind parent_id child_id

  name=${file##*/}
  [[ $name =~ ^\.successor-(lineage|preparation|authorization|handoff|erasure|archive)-([0-9a-f]{32})-([0-9a-f]{32})\.([A-Za-z0-9]{6})$ ]] || return 1
  kind=${BASH_REMATCH[1]}
  parent_id=${BASH_REMATCH[2]}
  child_id=${BASH_REMATCH[3]}
  [[ $active_id =~ ^[0-9a-f]{32}$ && $active_schema =~ ^[234]$ &&
    ( -z $direct_parent || $direct_parent =~ ^[0-9a-f]{32}$ ) ]] || return 1
  [[ $child_id != "$parent_id" && -f $file && ! -L $file ]] || return 1
  case $kind in
    lineage | preparation | authorization | handoff)
      [[ $parent_id == "$active_id" ]] || return 1
      ;;
    erasure)
      [[ $parent_id == "$active_id" ||
        ( $active_schema -eq 4 && $parent_id == "$direct_parent" &&
          $child_id == "$active_id" ) ]] || return 1
      ;;
    archive)
      [[ $active_schema -eq 4 && $parent_id == "$direct_parent" &&
        $child_id == "$active_id" ]] || return 1
      ;;
  esac
  metadata=$(stat -c '%u|%g|%a|%h' -- "$file") || return 1
  case $kind in
    handoff | archive)
      [[ $metadata == "$expected_uid|$expected_gid|600|1" ]]
      ;;
    *)
      # mktemp creates mode 0600.  Immutable protocol publishers change to
      # 0400 only after the payload is complete, so either mode is a valid
      # pre-rename crash point.
      [[ $metadata == "$expected_uid|$expected_gid|400|1" ||
        $metadata == "$expected_uid|$expected_gid|600|1" ]]
      ;;
  esac
}

# Returns 0 for no residue, 3 for an authenticated incomplete publication, and
# 2 for a name, owner, or filesystem identity that is not authorized by active.
dotfiles_rebuild_inspect_successor_publish_temps() {
  local state_root=$1 active_id=$2 active_schema=$3 direct_parent=$4 expected_uid=$5 expected_gid=$6
  local entry found=0

  dotfiles_rebuild_validate_lineage_directory \
    "$state_root" "$expected_uid" "$expected_gid" || return 2
  for entry in "$state_root"/.successor-*; do
    [[ -e $entry || -L $entry ]] || continue
    dotfiles_rebuild_validate_successor_publish_temp \
      "$entry" "$active_id" "$active_schema" "$direct_parent" \
      "$expected_uid" "$expected_gid" || return 2
    found=1
  done
  [[ $found -eq 0 ]] || return 3
}

dotfiles_rebuild_cleanup_successor_publish_temps() {
  local state_root=$1 active_id=$2 active_schema=$3 direct_parent=$4 expected_uid=$5 expected_gid=$6
  local -a temporaries=()
  local entry inspection_status

  if dotfiles_rebuild_inspect_successor_publish_temps \
    "$state_root" "$active_id" "$active_schema" "$direct_parent" \
    "$expected_uid" "$expected_gid"; then
    return 0
  else
    inspection_status=$?
    [[ $inspection_status -eq 3 ]] || return 1
  fi
  for entry in "$state_root"/.successor-*; do
    [[ -e $entry || -L $entry ]] || continue
    dotfiles_rebuild_validate_successor_publish_temp \
      "$entry" "$active_id" "$active_schema" "$direct_parent" \
      "$expected_uid" "$expected_gid" || return 1
    temporaries+=("$entry")
  done
  for entry in "${temporaries[@]}"; do
    dotfiles_rebuild_validate_successor_publish_temp \
      "$entry" "$active_id" "$active_schema" "$direct_parent" \
      "$expected_uid" "$expected_gid" || return 1
    rm -- "$entry" || return 1
    sync "$state_root" || return 1
  done
}

dotfiles_rebuild_prepare_protocol_directory() {
  local directory=$1 expected_uid=$2 expected_gid=$3 parent
  if [[ ! -e $directory && ! -L $directory ]]; then
    parent=${directory%/*}
    mkdir -m 0700 -- "$directory" || return 1
    sync "$parent" || return 1
  fi
  dotfiles_rebuild_validate_lineage_directory \
    "$directory" "$expected_uid" "$expected_gid"
}

dotfiles_rebuild_prepare_successor_protocol() {
  local state_root=$1 expected_uid=$2 expected_gid=$3 directory
  for directory in successor-preparations successors successor-erasures successor-garbage; do
    dotfiles_rebuild_prepare_protocol_directory \
      "$state_root/$directory" "$expected_uid" "$expected_gid" || return 1
  done
}

dotfiles_rebuild_protocol_artifact_metadata() {
  local state_root=$1 file=$2 expected_uid=$3 expected_gid=$4 expected_mode=${5:-400}
  local relative sha bytes
  dotfiles_rebuild_validate_protocol_file \
    "$file" "$expected_uid" "$expected_gid" "$expected_mode" || return 1
  [[ $file == "$state_root/"* ]] || return 1
  relative=${file#"$state_root/"}
  [[ -n $relative && $relative != /* && $relative != *'/../'* && $relative != ../* ]] || return 1
  sha=$(sha256sum "$file" | cut -d ' ' -f 1) || return 1
  bytes=$(stat -c '%s' -- "$file") || return 1
  jq -cn --arg path "$relative" --arg sha256 "$sha" --argjson bytes "$bytes" \
    '{path: $path, sha256: $sha256, bytes: $bytes}'
}

dotfiles_rebuild_expected_artifact_metadata() {
  local path=$1 source=$2 sha bytes
  [[ -f $source && ! -L $source ]] || return 1
  sha=$(sha256sum "$source" | cut -d ' ' -f 1) || return 1
  bytes=$(stat -c '%s' -- "$source") || return 1
  jq -cn --arg path "$path" --arg sha256 "$sha" --argjson bytes "$bytes" \
    '{path: $path, sha256: $sha256, bytes: $bytes}'
}

dotfiles_rebuild_metadata_matches_file() {
  local state_root=$1 metadata=$2 file=$3 expected_uid=$4 expected_gid=$5
  local expected_mode=${6:-400} expected_path expected_sha expected_bytes
  expected_path=$(jq -er '.path' <<< "$metadata") || return 1
  [[ $file == "$state_root/$expected_path" ]] || return 1
  dotfiles_rebuild_validate_protocol_file \
    "$file" "$expected_uid" "$expected_gid" "$expected_mode" || return 1
  expected_sha=$(jq -er '.sha256' <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes' <<< "$metadata") || return 1
  [[ $expected_sha =~ ^[0-9a-f]{64}$ && $expected_bytes =~ ^[0-9]+$ ]] || return 1
  [[ $(sha256sum "$file" | cut -d ' ' -f 1) == "$expected_sha" &&
    $(stat -c '%s' -- "$file") == "$expected_bytes" ]]
}

dotfiles_rebuild_validate_preparation_parent_evidence_file() {
  local file=$1 metadata=$2 parent_id=$3 expected_uid=$4 expected_gid=$5
  local expected_worktree=$6 nix_store_dir=$7 expected_user=$8 expected_mode=$9
  local expected_sha expected_bytes

  dotfiles_rebuild_validate_protocol_file \
    "$file" "$expected_uid" "$expected_gid" "$expected_mode" || return 1
  dotfiles_rebuild_validate_receipt_file \
    "$file" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
    "$expected_user" "$expected_mode" || return 1
  jq -e --arg parentId "$parent_id" '
      (.schemaVersion | IN(3, 4)) and
      .transactionId == $parentId and
      .state == "verification-failed"
    ' "$file" >/dev/null || return 1
  expected_sha=$(jq -er '.sha256' <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes' <<< "$metadata") || return 1
  [[ $(sha256sum "$file" | cut -d ' ' -f 1) == "$expected_sha" &&
    $(stat -c '%s' -- "$file") == "$expected_bytes" ]]
}

dotfiles_rebuild_validate_preparation_parent_evidence() {
  local state_root=$1 parent_id=$2 child_id=$3 metadata=$4 expected_uid=$5 expected_gid=$6
  local expected_worktree=$7 nix_store_dir=$8 expected_user=$9
  local expected_path source_file garbage_file active_file active_candidate_id evidence_count=0

  [[ $(jq -cS 'keys' <<< "$metadata") == '["bytes","path","sha256"]' ]] || return 1
  expected_path=$(jq -er '.path' <<< "$metadata") || return 1
  [[ $expected_path == "lineage/$parent_id/verification-failed.json" ]] || return 1
  source_file=$state_root/$expected_path
  garbage_file=$state_root/successor-garbage/$parent_id-$child_id/lineage/verification-failed.json
  active_file=$state_root/active.json

  if [[ -e $source_file || -L $source_file ]]; then
    dotfiles_rebuild_validate_preparation_parent_evidence_file \
      "$source_file" "$metadata" "$parent_id" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$expected_user" 400 || return 1
    (( evidence_count += 1 ))
  fi
  if [[ -e $garbage_file || -L $garbage_file ]]; then
    dotfiles_rebuild_validate_preparation_parent_evidence_file \
      "$garbage_file" "$metadata" "$parent_id" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$expected_user" 400 || return 1
    (( evidence_count += 1 ))
  fi
  if [[ -e $active_file || -L $active_file ]]; then
    active_candidate_id=$(jq -er '.transactionId' "$active_file" 2>/dev/null || true)
    if [[ $active_candidate_id == "$parent_id" ]]; then
      dotfiles_rebuild_validate_preparation_parent_evidence_file \
        "$active_file" "$metadata" "$parent_id" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$expected_user" 600 || return 1
      (( evidence_count += 1 ))
    fi
  fi
  [[ $evidence_count -gt 0 ]]
}

dotfiles_rebuild_validate_successor_preparation() {
  local state_root=$1 preparation=$2 expected_uid=$3 expected_gid=$4
  local expected_worktree=$5 nix_store_dir=$6 expected_user=$7
  local expected_parent_id=${8:-} expected_child_id=${9:-}
  local name parent_id child_id child
  if [[ -n $expected_parent_id || -n $expected_child_id ]]; then
    [[ $expected_parent_id =~ ^[0-9a-f]{32}$ &&
      $expected_child_id =~ ^[0-9a-f]{32}$ ]] || return 1
    parent_id=$expected_parent_id
    child_id=$expected_child_id
  else
    name=${preparation##*/}
    [[ $name =~ ^([0-9a-f]{32})-([0-9a-f]{32})\.json$ ]] || return 1
    parent_id=${BASH_REMATCH[1]}
    child_id=${BASH_REMATCH[2]}
  fi
  [[ $parent_id != "$child_id" ]] || return 1
  dotfiles_rebuild_validate_protocol_file \
    "$preparation" "$expected_uid" "$expected_gid" 400 || return 1
  dotfiles_rebuild_validate_receipt_file \
    "$preparation" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
    "$expected_user" 400 || return 1
  child=$(cat -- "$preparation") || return 1
  jq -e --arg parentId "$parent_id" --arg childId "$child_id" '
      .schemaVersion == 4 and .transactionId == $childId and .state == "prepared" and
      .lineage == {
        kind: "verification-successor",
        protocolVersion: 2,
        parentTransactionId: $parentId,
        parentReceipt: .lineage.parentReceipt,
        execution: .lineage.execution,
        createdAt: .lineage.createdAt
      } and
      .lineage.parentReceipt.path ==
        ("lineage/" + $parentId + "/verification-failed.json") and
      .candidate != .recoveryTarget and .previous.running == .recoveryTarget and
      .activation.status == "pending" and (.activation.attempts | length) == 0 and
      .verification.status == "pending" and .failureStage == null and
      .rollback == null and .abort == null and .cancellation == null and
      .supersession == null
    ' <<< "$child" >/dev/null || return 1
  dotfiles_rebuild_validate_preparation_parent_evidence \
    "$state_root" "$parent_id" "$child_id" "$(jq -c '.lineage.parentReceipt' <<< "$child")" \
    "$expected_uid" "$expected_gid" "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
  printf '%s\n' "$child"
}

dotfiles_rebuild_publish_successor_preparation() {
  local state_root=$1 parent_id=$2 child_id=$3 expected_uid=$4 expected_gid=$5
  local expected_worktree=$6 nix_store_dir=$7 expected_user=$8 directory target temporary
  [[ $parent_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $parent_id != "$child_id" ]] || return 1
  dotfiles_rebuild_prepare_successor_protocol \
    "$state_root" "$expected_uid" "$expected_gid" || return 1
  directory=$state_root/successor-preparations
  target=$directory/$parent_id-$child_id.json
  if [[ -e $target || -L $target ]]; then
    dotfiles_rebuild_validate_successor_preparation \
      "$state_root" "$target" "$expected_uid" "$expected_gid" "$expected_worktree" \
      "$nix_store_dir" "$expected_user" >/dev/null || return 1
    cmp -s -- /dev/stdin "$target" && printf '%s\n' "$target"
    return $?
  fi
  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" preparation "$parent_id" "$child_id")") || return 1
  cat > "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0400 "$temporary" || { rm -f -- "$temporary"; return 1; }
  dotfiles_rebuild_validate_successor_preparation \
    "$state_root" "$temporary" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" "$parent_id" "$child_id" >/dev/null || {
    rm -f -- "$temporary"
    return 1
  }
  [[ $(jq -r '.transactionId' "$temporary") == "$child_id" ]] || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$directory" || return 1
  sync "$state_root" || return 1
  printf '%s\n' "$target"
}

dotfiles_rebuild_validate_successor_helper() {
  local metadata=$1 candidate=$2 role=$3 nix_store_dir=$4 logical expected canonical actual
  local expected_sha expected_bytes
  case $role in
    rebuild) expected=$candidate/sw/bin/dotfiles-rebuild ;;
    syncImages) expected=$candidate/sw/bin/dotfiles-sync-images ;;
    doctor) expected=$candidate/sw/bin/dotfiles-doctor ;;
    *) return 1 ;;
  esac
  logical=$(jq -er '.logicalPath' <<< "$metadata") || return 1
  canonical=$(jq -er '.canonicalPath' <<< "$metadata") || return 1
  expected_sha=$(jq -er '.sha256' <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes' <<< "$metadata") || return 1
  [[ $logical == "$expected" && $canonical == "$nix_store_dir/"* &&
    $expected_sha =~ ^[0-9a-f]{64}$ && $expected_bytes =~ ^[0-9]+$ ]] || return 1
  actual=$(readlink -e -- "$logical" 2>/dev/null) || return 1
  [[ $actual == "$canonical" && -f $canonical && ! -L $canonical && -x $canonical ]] || return 1
  [[ $(sha256sum "$canonical" | cut -d ' ' -f 1) == "$expected_sha" &&
    $(stat -c '%s' -- "$canonical") == "$expected_bytes" ]]
}

dotfiles_rebuild_successor_helper_metadata() {
  local logical=$1 nix_store_dir=$2 canonical sha bytes
  canonical=$(readlink -e -- "$logical" 2>/dev/null) || return 1
  [[ $canonical == "$nix_store_dir/"* && -f $canonical && ! -L $canonical && -x $canonical ]] || return 1
  sha=$(sha256sum "$canonical" | cut -d ' ' -f 1) || return 1
  bytes=$(stat -c '%s' -- "$canonical") || return 1
  jq -cn --arg logicalPath "$logical" --arg canonicalPath "$canonical" \
    --arg sha256 "$sha" --argjson bytes "$bytes" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}'
}

dotfiles_rebuild_observe_successor_roots() {
  local state_root=$1 child=$2 expected_uid=$3 expected_gid=$4 nix_store_dir=$5
  local nix_gc_auto_roots_dir=$6 require_complete=${7:-0}
  local child_id transaction_roots entry name label expected_target metadata literal auto_base
  local root_count=0 auto_count=0 observed_roots='{}' observed_root_temps='[]'
  local observed_auto='[]' observed_auto_temps='[]'
  local -a labels=(source candidate recovery-target previous-booted displaced-profile)
  local -A target_by_label=() direct_seen=() direct_temp_seen=()
  local -A auto_seen=() auto_temp_seen=() auto_base_by_label=() label_by_auto_base=()

  child_id=$(jq -er '.transactionId' <<< "$child") || return 1
  [[ $child_id =~ ^[0-9a-f]{32}$ && $require_complete =~ ^[01]$ ]] || return 1
  transaction_roots=$state_root/roots/$child_id
  dotfiles_rebuild_validate_lineage_directory \
    "$state_root/roots" "$expected_uid" "$expected_gid" || return 1
  dotfiles_rebuild_validate_gc_auto_roots_directory \
    "$nix_gc_auto_roots_dir" || return 1
  target_by_label[source]=$(jq -er '.source' <<< "$child") || return 1
  target_by_label[candidate]=$(jq -er '.candidate' <<< "$child") || return 1
  target_by_label[recovery-target]=$(jq -er '.recoveryTarget' <<< "$child") || return 1
  target_by_label[previous-booted]=$(jq -er '.previous.booted' <<< "$child") || return 1
  target_by_label[displaced-profile]=$(jq -er '.previous.displacedProfile' <<< "$child") || return 1
  for label in "${labels[@]}"; do
    expected_target=${target_by_label[$label]}
    [[ $expected_target == "$nix_store_dir/"* ]] || return 1
    if [[ $require_complete -eq 1 ]]; then
      [[ -e $expected_target ]] || return 1
    fi
  done

  if [[ -e $transaction_roots || -L $transaction_roots ]]; then
    dotfiles_rebuild_validate_lineage_directory \
      "$transaction_roots" "$expected_uid" "$expected_gid" || return 1
    while IFS= read -r -d '' entry; do
      name=${entry##*/}
      if [[ $name =~ ^(source|candidate|recovery-target|previous-booted|displaced-profile)$ ]]; then
        label=${BASH_REMATCH[1]}
        [[ -z ${direct_seen[$label]+x} ]] || return 1
        direct_seen[$label]=1
        expected_target=${target_by_label[$label]}
        [[ -L $entry && $(readlink -- "$entry") == "$expected_target" ]] || return 1
        metadata=$(stat -c '%u|%g|%a|%h' -- "$entry") || return 1
        [[ $metadata == "$expected_uid|$expected_gid|777|1" ]] || return 1
        observed_roots=$(jq -c --arg label "$label" --arg path "$entry" \
          --arg target "$expected_target" --arg metadata "$metadata" \
          '. + {($label): {path: $path, target: $target, metadata: $metadata}}' \
          <<< "$observed_roots") || return 1
        (( root_count += 1 ))
      elif [[ $name =~ ^(source|candidate|recovery-target|previous-booted|displaced-profile)\.tmp-([0-9]+)-([0-9]+)$ ]]; then
        label=${BASH_REMATCH[1]}
        [[ -z ${direct_temp_seen[$label]+x} ]] || return 1
        direct_temp_seen[$label]=1
        expected_target=${target_by_label[$label]}
        [[ -L $entry && $(readlink -- "$entry") == "$expected_target" ]] || return 1
        metadata=$(stat -c '%u|%g|%a|%h' -- "$entry") || return 1
        [[ $metadata == "$expected_uid|$expected_gid|777|1" ]] || return 1
        observed_root_temps=$(jq -c --arg label "$label" --arg path "$entry" \
          --arg literalTarget "$expected_target" --arg metadata "$metadata" \
          '. + [{label: $label, path: $path, literalTarget: $literalTarget, metadata: $metadata}]' \
          <<< "$observed_root_temps") || return 1
      else
        return 1
      fi
    done < <(find "$transaction_roots" -mindepth 1 -maxdepth 1 -print0)
  fi

  for entry in "$nix_gc_auto_roots_dir"/*; do
    [[ -e $entry || -L $entry ]] || continue
    [[ -L $entry ]] || return 1
    literal=$(readlink -- "$entry") || return 1
    [[ $literal == "$transaction_roots/"* ]] || continue
    label=${literal#"$transaction_roots/"}
    case $label in
      source | candidate | recovery-target | previous-booted | displaced-profile) ;;
      *) return 1 ;;
    esac
    name=${entry##*/}
    metadata=$(stat -c '%u|%g|%a|%h' -- "$entry") || return 1
    [[ $metadata =~ ^[0-9]+\|[0-9]+\|777\|1$ ]] || return 1
    if [[ $name =~ ^([0-9abcdfghijklmnpqrsvwxyz]{32})$ ]]; then
      auto_base=${BASH_REMATCH[1]}
      [[ -z ${auto_seen[$label]+x} ]] || return 1
      auto_seen[$label]=1
      if [[ -n ${label_by_auto_base[$auto_base]+x} ]]; then
        [[ ${label_by_auto_base[$auto_base]} == "$label" ]] || return 1
      else
        label_by_auto_base[$auto_base]=$label
      fi
      if [[ -n ${auto_base_by_label[$label]+x} ]]; then
        [[ ${auto_base_by_label[$label]} == "$auto_base" ]] || return 1
      else
        auto_base_by_label[$label]=$auto_base
      fi
      observed_auto=$(jq -c --arg label "$label" --arg path "$entry" \
        --arg literalTarget "$literal" --arg metadata "$metadata" \
        '. + [{label: $label, path: $path, literalTarget: $literalTarget, metadata: $metadata}]' \
        <<< "$observed_auto") || return 1
      (( auto_count += 1 ))
    elif [[ $name =~ ^([0-9abcdfghijklmnpqrsvwxyz]{32})\.tmp-([0-9]+)-([0-9]+)$ ]]; then
      auto_base=${BASH_REMATCH[1]}
      [[ -z ${auto_temp_seen[$label]+x} ]] || return 1
      auto_temp_seen[$label]=1
      if [[ -n ${label_by_auto_base[$auto_base]+x} ]]; then
        [[ ${label_by_auto_base[$auto_base]} == "$label" ]] || return 1
      else
        label_by_auto_base[$auto_base]=$label
      fi
      if [[ -n ${auto_base_by_label[$label]+x} ]]; then
        [[ ${auto_base_by_label[$label]} == "$auto_base" ]] || return 1
      else
        auto_base_by_label[$label]=$auto_base
      fi
      observed_auto_temps=$(jq -c --arg label "$label" --arg path "$entry" \
        --arg literalTarget "$literal" --arg metadata "$metadata" \
        '. + [{label: $label, path: $path, literalTarget: $literalTarget, metadata: $metadata}]' \
        <<< "$observed_auto_temps") || return 1
    else
      return 1
    fi
  done
  if [[ $require_complete -eq 1 ]]; then
    [[ $root_count -eq 5 && $auto_count -eq 5 &&
      $(jq -r 'length' <<< "$observed_root_temps") -eq 0 &&
      $(jq -r 'length' <<< "$observed_auto_temps") -eq 0 ]] || return 1
  fi
  jq -cn --argjson observedRoots "$observed_roots" \
    --argjson observedRootTemps "$observed_root_temps" \
    --argjson observedAutoRoots "$observed_auto" \
    --argjson observedAutoRootTemps "$observed_auto_temps" '
      {
        observedRoots: $observedRoots,
        observedRootTemps: ($observedRootTemps | sort_by(.label)),
        observedAutoRoots: ($observedAutoRoots | sort_by(.label)),
        observedAutoRootTemps: ($observedAutoRootTemps | sort_by(.label))
      }
    '
}

dotfiles_rebuild_desired_successor_roots() {
  local child=$1
  jq -c '
    {
      source: .source,
      candidate: .candidate,
      "recovery-target": .recoveryTarget,
      "previous-booted": .previous.booted,
      "displaced-profile": .previous.displacedProfile
    }
  ' <<< "$child"
}

dotfiles_rebuild_validate_successor_manifest() {
  local metadata=$1 candidate=$2 nix_store_dir=$3 logical canonical actual expected_sha expected_bytes
  logical=$(jq -er '.logicalPath' <<< "$metadata") || return 1
  canonical=$(jq -er '.canonicalPath' <<< "$metadata") || return 1
  expected_sha=$(jq -er '.sha256' <<< "$metadata") || return 1
  expected_bytes=$(jq -er '.bytes' <<< "$metadata") || return 1
  [[ $logical == "$candidate/etc/dotfiles/oci-images.json" &&
    $canonical == "$nix_store_dir/"* && $expected_sha =~ ^[0-9a-f]{64}$ &&
    $expected_bytes =~ ^[0-9]+$ ]] || return 1
  actual=$(readlink -e -- "$logical" 2>/dev/null) || return 1
  [[ $actual == "$canonical" && -f $canonical && ! -L $canonical ]] || return 1
  [[ $(sha256sum "$canonical" | cut -d ' ' -f 1) == "$expected_sha" &&
    $(stat -c '%s' -- "$canonical") == "$expected_bytes" ]]
}

dotfiles_rebuild_successor_manifest_metadata() {
  local logical=$1 nix_store_dir=$2 canonical sha bytes
  canonical=$(readlink -e -- "$logical" 2>/dev/null) || return 1
  [[ $canonical == "$nix_store_dir/"* && -f $canonical && ! -L $canonical ]] || return 1
  sha=$(sha256sum "$canonical" | cut -d ' ' -f 1) || return 1
  bytes=$(stat -c '%s' -- "$canonical") || return 1
  jq -cn --arg logicalPath "$logical" --arg canonicalPath "$canonical" \
    --arg sha256 "$sha" --argjson bytes "$bytes" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}'
}

dotfiles_rebuild_validate_successor_authorization_content() {
  local state_root=$1 authorization_file=$2 parent_id=$3 active_receipt=$4 role=$5
  local expected_uid=$6 expected_gid=$7 expected_worktree=$8 nix_store_dir=$9
  local nix_gc_auto_roots_dir=${10} expected_user=${11} allow_erasure=${12:-0}
  local authorization child_id preparation child parent_file parent observed desired helper
  local manifest erasure active_id

  [[ $parent_id =~ ^[0-9a-f]{32}$ && $role =~ ^(pending|consumed)$ ]] || return 1
  dotfiles_rebuild_validate_protocol_file \
    "$authorization_file" "$expected_uid" "$expected_gid" 400 || return 1
  authorization=$(cat -- "$authorization_file") || return 1
  child_id=$(jq -er '.child.transactionId' <<< "$authorization") || return 1
  [[ $child_id =~ ^[0-9a-f]{32}$ && $child_id != "$parent_id" ]] || return 1
  erasure=$state_root/successor-erasures/$parent_id-$child_id.json
  if [[ $allow_erasure -ne 1 ]]; then
    [[ ! -e $erasure && ! -L $erasure ]] || return 1
  fi
  jq -e --arg parentId "$parent_id" --arg childId "$child_id" '
      keys == [
        "activationBaseline", "child", "createdAt", "kind", "lineage",
        "parent", "roots", "schemaVersion"
      ] and
      .schemaVersion == 2 and .kind == "verification-successor-authorization" and
      .parent.transactionId == $parentId and
      (.parent | keys) == ["candidate", "receipt", "transactionId"] and
      .child.transactionId == $childId and
      (.child | keys) == [
        "candidate", "helpers", "manifest", "preparation", "source", "transactionId"
      ] and
      (.child.helpers | keys) == ["doctor", "rebuild", "syncImages"] and
      (.roots | keys) == [
        "candidate", "displaced-profile", "previous-booted", "recovery-target", "source"
      ] and
      (.lineage | keys) == ["parentReceipt"] and
      (.activationBaseline | keys) == ["booted", "current", "profile"] and
      (.createdAt | type == "string" and length > 0)
    ' <<< "$authorization" >/dev/null || return 1

  preparation=$state_root/$(jq -er '.child.preparation.path' <<< "$authorization") || return 1
  [[ $preparation == "$state_root/successor-preparations/$parent_id-$child_id.json" ]] || return 1
  dotfiles_rebuild_metadata_matches_file \
    "$state_root" "$(jq -c '.child.preparation' <<< "$authorization")" "$preparation" \
    "$expected_uid" "$expected_gid" 400 || return 1
  child=$(dotfiles_rebuild_validate_successor_preparation \
    "$state_root" "$preparation" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user") || return 1
  [[ $(jq -r '.transactionId' <<< "$child") == "$child_id" &&
    $(jq -r '.child.source' <<< "$authorization") == $(jq -r '.source' <<< "$child") &&
    $(jq -r '.child.candidate' <<< "$authorization") == $(jq -r '.candidate' <<< "$child") &&
    $(jq -cS '.child.helpers' <<< "$authorization") == \
      $(jq -cS '.lineage.execution.helpers' <<< "$child") &&
    $(jq -cS '.child.manifest' <<< "$authorization") == \
      $(jq -cS '.lineage.execution.manifest' <<< "$child") &&
    $(jq -r '.createdAt' <<< "$authorization") == \
      $(jq -r '.lineage.createdAt' <<< "$child") ]] || return 1

  parent_file=$state_root/$(jq -er '.parent.receipt.path' <<< "$authorization") || return 1
  [[ $parent_file == "$state_root/lineage/$parent_id/verification-failed.json" ]] || return 1
  dotfiles_rebuild_metadata_matches_file \
    "$state_root" "$(jq -c '.parent.receipt' <<< "$authorization")" "$parent_file" \
    "$expected_uid" "$expected_gid" 400 || return 1
  [[ $(jq -cS '.parent.receipt' <<< "$authorization") == \
    $(jq -cS '.lineage.parentReceipt' <<< "$authorization") &&
    $(jq -cS '.parent.receipt' <<< "$authorization") == \
    $(jq -cS '.lineage.parentReceipt' <<< "$child") ]] || return 1
  parent=$(cat -- "$parent_file") || return 1
  jq -e --arg parentId "$parent_id" '
      (.schemaVersion | IN(3, 4)) and .transactionId == $parentId and
      .state == "verification-failed" and .failureStage == "doctor" and
      .activation.status == "succeeded" and .verification.status == "failed" and
      .rollback == null and .abort == null and .cancellation == null
    ' <<< "$parent" >/dev/null || return 1
  [[ $(jq -r '.parent.candidate' <<< "$authorization") == $(jq -r '.candidate' <<< "$parent") &&
    $(jq -r '.recoveryTarget' <<< "$child") == $(jq -r '.candidate' <<< "$parent") ]] || return 1

  if [[ $role == pending ]]; then
    dotfiles_rebuild_validate_receipt_file \
      "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
      "$expected_user" 600 || return 1
    cmp -s -- "$active_receipt" "$parent_file" || return 1
  else
    dotfiles_rebuild_validate_receipt_file \
      "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
      "$expected_user" 600 || return 1
    active_id=$(jq -er '.transactionId' "$active_receipt") || return 1
    [[ $active_id == "$child_id" &&
      $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == \
      $(jq -r '.child.preparation.sha256' <<< "$authorization") &&
      $(stat -c '%s' -- "$active_receipt") == \
      $(jq -r '.child.preparation.bytes' <<< "$authorization") ]] || return 1
  fi

  dotfiles_rebuild_verify_receipt_evidence \
    "$state_root" "$child" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user" || return 1
  for helper in rebuild syncImages doctor; do
    dotfiles_rebuild_validate_successor_helper \
      "$(jq -c --arg helper "$helper" '.child.helpers[$helper]' <<< "$authorization")" \
      "$(jq -r '.candidate' <<< "$child")" "$helper" "$nix_store_dir" || return 1
  done
  manifest=$(jq -c '.child.manifest' <<< "$authorization") || return 1
  dotfiles_rebuild_validate_successor_manifest \
    "$manifest" "$(jq -r '.candidate' <<< "$child")" "$nix_store_dir" || return 1
  desired=$(dotfiles_rebuild_desired_successor_roots "$child") || return 1
  [[ $(jq -cS '.roots' <<< "$authorization") == "$(jq -cS . <<< "$desired")" ]] || return 1
  observed=$(dotfiles_rebuild_observe_successor_roots \
    "$state_root" "$child" "$expected_uid" "$expected_gid" "$nix_store_dir" \
    "$nix_gc_auto_roots_dir" 1) || return 1
  [[ $(jq -r '.observedRoots | length' <<< "$observed") -eq 5 &&
    $(jq -r '.observedAutoRoots | length' <<< "$observed") -eq 5 ]] || return 1
  [[ $(jq -cS '.activationBaseline' <<< "$authorization") == \
    $(jq -cS '.activationBaseline' <<< "$child") ]] || return 1
  printf '%s\n' "$authorization"
}

dotfiles_rebuild_read_successor_authorization_v2() {
  local state_root=$1 parent_id=$2 active_receipt=$3 role=$4 expected_uid=$5 expected_gid=$6
  local expected_worktree=$7 nix_store_dir=$8 nix_gc_auto_roots_dir=$9 expected_user=${10}
  local file=$state_root/successors/$parent_id.json
  dotfiles_rebuild_validate_successor_authorization_content \
    "$state_root" "$file" "$parent_id" "$active_receipt" "$role" "$expected_uid" \
    "$expected_gid" "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
    "$expected_user"
}

dotfiles_rebuild_publish_successor_authorization_v2() {
  local state_root=$1 parent_id=$2 active_receipt=$3 expected_uid=$4 expected_gid=$5
  local expected_worktree=$6 nix_store_dir=$7 nix_gc_auto_roots_dir=$8 expected_user=$9
  local directory target temporary authorization child_id
  directory=$state_root/successors
  target=$directory/$parent_id.json
  dotfiles_rebuild_prepare_successor_protocol \
    "$state_root" "$expected_uid" "$expected_gid" || return 1
  [[ ! -e $target && ! -L $target ]] || return 1
  authorization=$(cat) || return 1
  child_id=$(jq -er '.child.transactionId' <<< "$authorization") || return 1
  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" authorization "$parent_id" "$child_id")") || return 1
  printf '%s\n' "$authorization" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0400 "$temporary" || { rm -f -- "$temporary"; return 1; }
  dotfiles_rebuild_validate_successor_authorization_content \
    "$state_root" "$temporary" "$parent_id" "$active_receipt" pending "$expected_uid" \
    "$expected_gid" "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
    "$expected_user" >/dev/null || {
    rm -f -- "$temporary"
    return 2
  }
  sync --data "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$directory" || return 1
  sync "$state_root" || return 1
}

dotfiles_rebuild_validate_erasure_root_subset() {
  local directory=$1 observed_roots=$2 observed_root_temps=$3 expected_uid=$4 expected_gid=$5
  local entry name label expected_target expected_metadata records record
  [[ -e $directory || -L $directory ]] || return 0
  dotfiles_rebuild_validate_lineage_directory \
    "$directory" "$expected_uid" "$expected_gid" || return 1
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    if [[ $name =~ ^(source|candidate|recovery-target|previous-booted|displaced-profile)$ ]]; then
      label=${BASH_REMATCH[1]}
      jq -e --arg label "$label" 'has($label)' <<< "$observed_roots" >/dev/null || return 1
      expected_target=$(jq -er --arg label "$label" '.[$label].target' <<< "$observed_roots") || return 1
      expected_metadata=$(jq -er --arg label "$label" '.[$label].metadata' <<< "$observed_roots") || return 1
    elif [[ $name =~ ^(source|candidate|recovery-target|previous-booted|displaced-profile)\.tmp-([0-9]+)-([0-9]+)$ ]]; then
      label=${BASH_REMATCH[1]}
      records=$(jq -c --arg name "$name" '[.[] | select((.path | split("/") | last) == $name)]' \
        <<< "$observed_root_temps") || return 1
      [[ $(jq -r 'length' <<< "$records") -eq 1 ]] || return 1
      record=$(jq -c '.[0]' <<< "$records") || return 1
      [[ $(jq -r '.label' <<< "$record") == "$label" ]] || return 1
      expected_target=$(jq -er '.literalTarget' <<< "$record") || return 1
      expected_metadata=$(jq -er '.metadata' <<< "$record") || return 1
    else
      return 1
    fi
    [[ -L $entry && $(readlink -- "$entry") == "$expected_target" ]] || return 1
    [[ $(stat -c '%u|%g|%a|%h' -- "$entry") == "$expected_metadata" ]] || return 1
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
}

dotfiles_rebuild_validate_erasure_root_record() {
  local state_root=$1 child_id=$2 label=$3 desired_roots=$4 record=$5
  local expected_uid=$6 expected_gid=$7 expected_path expected_target

  [[ $child_id =~ ^[0-9a-f]{32}$ ]] || return 1
  case $label in
    source | candidate | recovery-target | previous-booted | displaced-profile) ;;
    *) return 1 ;;
  esac
  jq -e 'keys == ["metadata", "path", "target"]' <<< "$record" >/dev/null || return 1
  expected_path=$state_root/roots/$child_id/$label
  expected_target=$(jq -er --arg label "$label" '.[$label]' <<< "$desired_roots") || return 1
  jq -e --arg path "$expected_path" --arg target "$expected_target" \
    --arg metadata "$expected_uid|$expected_gid|777|1" \
    '.path == $path and .target == $target and .metadata == $metadata' \
    <<< "$record" >/dev/null
}

dotfiles_rebuild_validate_erasure_root_temp_record() {
  local state_root=$1 child_id=$2 desired_roots=$3 record=$4 expected_uid=$5 expected_gid=$6
  local label path name literal

  jq -e 'keys == ["label", "literalTarget", "metadata", "path"]' \
    <<< "$record" >/dev/null || return 1
  label=$(jq -er '.label' <<< "$record") || return 1
  case $label in
    source | candidate | recovery-target | previous-booted | displaced-profile) ;;
    *) return 1 ;;
  esac
  path=$(jq -er '.path' <<< "$record") || return 1
  [[ $path == "$state_root/roots/$child_id/"* ]] || return 1
  name=${path#"$state_root/roots/$child_id/"}
  [[ $name =~ ^${label}\.tmp-[0-9]+-[0-9]+$ ]] || return 1
  literal=$(jq -er '.literalTarget' <<< "$record") || return 1
  [[ $literal == "$(jq -er --arg label "$label" '.[$label]' <<< "$desired_roots")" ]] || return 1
  [[ $(jq -r '.metadata' <<< "$record") == "$expected_uid|$expected_gid|777|1" ]]
}

dotfiles_rebuild_validate_erasure_auto_root_record() {
  local state_root=$1 child_id=$2 record=$3 nix_gc_auto_roots_dir=$4 kind=$5
  local auto_root auto_root_name label literal

  jq -e 'keys == ["label", "literalTarget", "metadata", "path"]' \
    <<< "$record" >/dev/null || return 1
  label=$(jq -er '.label' <<< "$record") || return 1
  case $label in
    source | candidate | recovery-target | previous-booted | displaced-profile) ;;
    *) return 1 ;;
  esac
  auto_root=$(jq -er '.path' <<< "$record") || return 1
  [[ $auto_root == "$nix_gc_auto_roots_dir/"* ]] || return 1
  auto_root_name=${auto_root#"$nix_gc_auto_roots_dir/"}
  case $kind in
    canonical)
      [[ $auto_root_name =~ ^[0-9abcdfghijklmnpqrsvwxyz]{32}$ ]] || return 1
      ;;
    temporary)
      [[ $auto_root_name =~ ^[0-9abcdfghijklmnpqrsvwxyz]{32}\.tmp-[0-9]+-[0-9]+$ ]] || return 1
      ;;
    *) return 1 ;;
  esac
  literal=$(jq -er '.literalTarget' <<< "$record") || return 1
  [[ $literal == "$state_root/roots/$child_id/$label" ]] || return 1
  [[ $(jq -r '.metadata' <<< "$record") =~ ^[0-9]+\|[0-9]+\|777\|1$ ]]
}

dotfiles_rebuild_validate_successor_erasure() {
  local state_root=$1 erasure_file=$2 active_receipt=$3 expected_uid=$4 expected_gid=$5
  local expected_worktree=$6 nix_store_dir=$7 nix_gc_auto_roots_dir=$8 expected_user=$9
  local erasure name parent_id child_id keep_roots preparation authorization parent_file child desired
  local child_desired
  local source_lineage garbage_root garbage_lineage source_roots garbage_roots entry entry_name
  local observed_roots observed_root_temps observed_auto observed_auto_temps
  local auto_root auto_name auto_base label literal metadata record records active_id role kind
  local -A recorded_auto_kind=() recorded_auto_literal=() recorded_auto_metadata=()
  local -A auto_base_by_label=() label_by_auto_base=()

  dotfiles_rebuild_validate_gc_auto_roots_directory \
    "$nix_gc_auto_roots_dir" || return 1
  name=${erasure_file##*/}
  [[ $name =~ ^([0-9a-f]{32})-([0-9a-f]{32})\.json$ ]] || return 1
  parent_id=${BASH_REMATCH[1]}
  child_id=${BASH_REMATCH[2]}
  dotfiles_rebuild_validate_protocol_file \
    "$erasure_file" "$expected_uid" "$expected_gid" 400 || return 1
  erasure=$(cat -- "$erasure_file") || return 1
  jq -e --arg parentId "$parent_id" --arg childId "$child_id" '
      keys == [
        "authorization", "childTransactionId", "createdAt", "desiredRoots", "keepRoots",
        "kind", "observedAutoRootTemps", "observedAutoRoots", "observedRootTemps",
        "observedRoots", "parentReceipt", "parentTransactionId", "preparation", "reason",
        "schemaVersion"
      ] and
      .schemaVersion == 2 and .kind == "successor-erasure" and
      .parentTransactionId == $parentId and .childTransactionId == $childId and
      ((.reason == "cancel-requested" and .keepRoots == false) or
       (.reason == "discard-partial" and .keepRoots == false) or
       (.reason == "consumed-handoff" and .keepRoots == true)) and
      (.desiredRoots | keys) == [
        "candidate", "displaced-profile", "previous-booted", "recovery-target", "source"
      ] and
      (.observedRoots | type) == "object" and
      ((.observedRoots | keys) - [
        "candidate", "displaced-profile", "previous-booted", "recovery-target", "source"
      ] | length) == 0 and
      all(.observedRoots[];
        keys == ["metadata", "path", "target"] and
        (.metadata | type == "string" and test("^[0-9]+\\|[0-9]+\\|777\\|1$"))) and
      (.observedRootTemps | type) == "array" and
      all(.observedRootTemps[];
        keys == ["label", "literalTarget", "metadata", "path"] and
        (.label | IN("source", "candidate", "recovery-target", "previous-booted", "displaced-profile")) and
        (.path | type == "string" and length > 0) and
        (.literalTarget | type == "string" and length > 0) and
        (.metadata | type == "string" and test("^[0-9]+\\|[0-9]+\\|777\\|1$"))) and
      ([.observedRootTemps[].label] | length) ==
        ([.observedRootTemps[].label] | unique | length) and
      (.observedAutoRoots | type) == "array" and
      all(.observedAutoRoots[];
        keys == ["label", "literalTarget", "metadata", "path"] and
        (.label | IN("source", "candidate", "recovery-target", "previous-booted", "displaced-profile")) and
        (.path | type == "string" and length > 0) and
        (.literalTarget | type == "string" and length > 0) and
        (.metadata | type == "string" and test("^[0-9]+\\|[0-9]+\\|[0-9]+\\|[0-9]+$"))) and
      ([.observedAutoRoots[].label] | length) ==
        ([.observedAutoRoots[].label] | unique | length) and
      (.observedAutoRootTemps | type) == "array" and
      all(.observedAutoRootTemps[];
        keys == ["label", "literalTarget", "metadata", "path"] and
        (.label | IN("source", "candidate", "recovery-target", "previous-booted", "displaced-profile")) and
        (.path | type == "string" and length > 0) and
        (.literalTarget | type == "string" and length > 0) and
        (.metadata | type == "string" and test("^[0-9]+\\|[0-9]+\\|777\\|1$"))) and
      ([.observedAutoRootTemps[].label] | length) ==
        ([.observedAutoRootTemps[].label] | unique | length) and
      (.createdAt | type == "string" and length > 0)
    ' <<< "$erasure" >/dev/null || return 1
  keep_roots=$(jq -r '.keepRoots' <<< "$erasure")
  desired=$(jq -c '.desiredRoots' <<< "$erasure") || return 1
  observed_roots=$(jq -c '.observedRoots' <<< "$erasure") || return 1
  observed_root_temps=$(jq -c '.observedRootTemps' <<< "$erasure") || return 1
  observed_auto=$(jq -c '.observedAutoRoots' <<< "$erasure") || return 1
  observed_auto_temps=$(jq -c '.observedAutoRootTemps' <<< "$erasure") || return 1
  if [[ -n $active_receipt ]]; then
    dotfiles_rebuild_validate_receipt_file \
      "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
      "$expected_user" 600 || return 1
    active_id=$(jq -er '.transactionId' "$active_receipt") || return 1
  fi

  preparation=$state_root/$(jq -er '.preparation.path' <<< "$erasure") || return 1
  [[ $preparation == "$state_root/successor-preparations/$parent_id-$child_id.json" ]] || return 1
  if [[ -e $preparation || -L $preparation ]]; then
    dotfiles_rebuild_metadata_matches_file \
      "$state_root" "$(jq -c '.preparation' <<< "$erasure")" "$preparation" \
      "$expected_uid" "$expected_gid" 400 || return 1
    child=$(dotfiles_rebuild_validate_successor_preparation \
      "$state_root" "$preparation" "$expected_uid" "$expected_gid" "$expected_worktree" \
      "$nix_store_dir" "$expected_user") || return 1
    child_desired=$(dotfiles_rebuild_desired_successor_roots "$child") || return 1
    [[ $(jq -cS . <<< "$desired") == "$(jq -cS . <<< "$child_desired")" &&
      $(jq -cS '.parentReceipt' <<< "$erasure") == \
      $(jq -cS '.lineage.parentReceipt' <<< "$child") ]] || return 1
  fi
  parent_file=$state_root/$(jq -er '.parentReceipt.path' <<< "$erasure") || return 1
  [[ $parent_file == "$state_root/lineage/$parent_id/verification-failed.json" ]] || return 1
  source_lineage=$state_root/lineage/$parent_id
  garbage_root=$state_root/successor-garbage/$parent_id-$child_id
  garbage_lineage=$garbage_root/lineage
  source_roots=$state_root/roots/$child_id
  garbage_roots=$garbage_root/roots
  [[ ! ( ( -e $source_lineage || -L $source_lineage ) &&
    ( -e $garbage_lineage || -L $garbage_lineage ) ) ]] || return 1
  [[ ! ( ( -e $source_roots || -L $source_roots ) &&
    ( -e $garbage_roots || -L $garbage_roots ) ) ]] || return 1

  if [[ -e $source_lineage || -L $source_lineage ]]; then
    dotfiles_rebuild_validate_lineage_directory \
      "$source_lineage" "$expected_uid" "$expected_gid" || return 1
    while IFS= read -r -d '' entry; do
      [[ ${entry##*/} == verification-failed.json ]] || return 1
      dotfiles_rebuild_metadata_matches_file \
        "$state_root" "$(jq -c '.parentReceipt' <<< "$erasure")" \
        "$entry" "$expected_uid" "$expected_gid" 400 || return 1
    done < <(find "$source_lineage" -mindepth 1 -maxdepth 1 -print0)
  fi
  if [[ -e $garbage_root || -L $garbage_root ]]; then
    dotfiles_rebuild_validate_lineage_directory \
      "$garbage_root" "$expected_uid" "$expected_gid" || return 1
    while IFS= read -r -d '' entry; do
      entry_name=${entry##*/}
      [[ $entry_name == lineage || $entry_name == roots ]] || return 1
    done < <(find "$garbage_root" -mindepth 1 -maxdepth 1 -print0)
  fi
  if [[ -e $garbage_lineage || -L $garbage_lineage ]]; then
    dotfiles_rebuild_validate_lineage_directory \
      "$garbage_lineage" "$expected_uid" "$expected_gid" || return 1
    while IFS= read -r -d '' entry; do
      [[ ${entry##*/} == verification-failed.json ]] || return 1
      dotfiles_rebuild_validate_protocol_file \
        "$entry" "$expected_uid" "$expected_gid" 400 || return 1
      [[ $(sha256sum "$entry" | cut -d ' ' -f 1) == \
        $(jq -r '.parentReceipt.sha256' <<< "$erasure") &&
        $(stat -c '%s' -- "$entry") == $(jq -r '.parentReceipt.bytes' <<< "$erasure") ]] || return 1
    done < <(find "$garbage_lineage" -mindepth 1 -maxdepth 1 -print0)
  fi
  dotfiles_rebuild_validate_erasure_root_subset \
    "$source_roots" "$observed_roots" "$observed_root_temps" \
    "$expected_uid" "$expected_gid" || return 1
  dotfiles_rebuild_validate_erasure_root_subset \
    "$garbage_roots" "$observed_roots" "$observed_root_temps" \
    "$expected_uid" "$expected_gid" || return 1
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    record=$(jq -c --arg label "$label" '.[$label]' <<< "$observed_roots") || return 1
    dotfiles_rebuild_validate_erasure_root_record \
      "$state_root" "$child_id" "$label" "$desired" "$record" \
      "$expected_uid" "$expected_gid" || return 1
  done < <(jq -r 'keys[]' <<< "$observed_roots")

  while IFS= read -r record; do
    [[ -n $record ]] || continue
    dotfiles_rebuild_validate_erasure_root_temp_record \
      "$state_root" "$child_id" "$desired" "$record" "$expected_uid" "$expected_gid" || return 1
  done < <(jq -c '.[]' <<< "$observed_root_temps")

  for kind in canonical temporary; do
    if [[ $kind == canonical ]]; then records=$observed_auto
    else records=$observed_auto_temps
    fi
    while IFS= read -r record; do
      [[ -n $record ]] || continue
      dotfiles_rebuild_validate_erasure_auto_root_record \
        "$state_root" "$child_id" "$record" "$nix_gc_auto_roots_dir" "$kind" || return 1
      auto_root=$(jq -er '.path' <<< "$record") || return 1
      [[ -z ${recorded_auto_kind[$auto_root]+x} ]] || return 1
      recorded_auto_kind[$auto_root]=$kind
      recorded_auto_literal[$auto_root]=$(jq -er '.literalTarget' <<< "$record") || return 1
      recorded_auto_metadata[$auto_root]=$(jq -er '.metadata' <<< "$record") || return 1
      label=$(jq -er '.label' <<< "$record") || return 1
      auto_name=${auto_root##*/}
      auto_base=${auto_name%%.tmp-*}
      if [[ -n ${label_by_auto_base[$auto_base]+x} ]]; then
        [[ ${label_by_auto_base[$auto_base]} == "$label" ]] || return 1
      else
        label_by_auto_base[$auto_base]=$label
      fi
      if [[ -n ${auto_base_by_label[$label]+x} ]]; then
        [[ ${auto_base_by_label[$label]} == "$auto_base" ]] || return 1
      else
        auto_base_by_label[$label]=$auto_base
      fi
    done < <(jq -c '.[]' <<< "$records")
  done
  for auto_root in "$nix_gc_auto_roots_dir"/*; do
    [[ -e $auto_root || -L $auto_root ]] || continue
    [[ -L $auto_root ]] || return 1
    literal=$(readlink -- "$auto_root") || return 1
    [[ $literal == "$source_roots/"* ]] || continue
    [[ -n ${recorded_auto_kind[$auto_root]+x} &&
      ${recorded_auto_literal[$auto_root]} == "$literal" ]] || return 1
  done
  for auto_root in "${!recorded_auto_kind[@]}"; do
    literal=${recorded_auto_literal[$auto_root]}
    metadata=${recorded_auto_metadata[$auto_root]}
    if [[ -e $auto_root || -L $auto_root ]]; then
      [[ -L $auto_root && $(readlink -- "$auto_root") == "$literal" ]] || return 1
      [[ $(stat -c '%u|%g|%a|%h' -- "$auto_root") == "$metadata" ]] || return 1
    fi
  done

  authorization=$state_root/successors/$parent_id.json
  if [[ $(jq -r '.authorization == null' <<< "$erasure") == true ]]; then
    [[ ! -e $authorization && ! -L $authorization ]] || return 1
  elif [[ -e $authorization || -L $authorization ]]; then
    dotfiles_rebuild_metadata_matches_file \
      "$state_root" "$(jq -c '.authorization' <<< "$erasure")" "$authorization" \
      "$expected_uid" "$expected_gid" 400 || return 1
    [[ -n $active_receipt && -f $active_receipt && ! -L $active_receipt ]] || return 1
    if [[ $active_id == "$parent_id" ]]; then role=pending
    elif [[ $active_id == "$child_id" ]]; then role=consumed
    else return 1
    fi
    dotfiles_rebuild_validate_successor_authorization_content \
      "$state_root" "$authorization" "$parent_id" "$active_receipt" "$role" \
      "$expected_uid" "$expected_gid" "$expected_worktree" "$nix_store_dir" \
      "$nix_gc_auto_roots_dir" "$expected_user" 1 >/dev/null || return 1
  fi

  if [[ $keep_roots == true ]]; then
    [[ $active_id == "$child_id" &&
      $(jq -r '.lineage.parentTransactionId // empty' "$active_receipt") == "$parent_id" &&
      $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == \
        $(jq -r '.preparation.sha256' <<< "$erasure") &&
      $(stat -c '%s' -- "$active_receipt") == \
        $(jq -r '.preparation.bytes' <<< "$erasure") &&
      $(jq -r '.observedRoots | length' <<< "$erasure") -eq 5 &&
      $(jq -r '.observedAutoRoots | length' <<< "$erasure") -eq 5 &&
      $(jq -r '.observedRootTemps | length' <<< "$erasure") -eq 0 &&
      $(jq -r '.observedAutoRootTemps | length' <<< "$erasure") -eq 0 &&
      -d $source_roots && ! -L $source_roots &&
      ! -e $garbage_root && ! -L $garbage_root ]] || return 1
    dotfiles_rebuild_validate_erasure_root_subset \
      "$source_roots" "$observed_roots" "$observed_root_temps" \
      "$expected_uid" "$expected_gid" || return 1
    [[ $(find "$source_roots" -mindepth 1 -maxdepth 1 -printf . | wc -c) -eq 5 ]] || return 1
    while IFS= read -r record; do
      auto_root=$(jq -r '.path' <<< "$record")
      [[ -L $auto_root ]] || return 1
    done < <(jq -c '.[]' <<< "$observed_auto")
  fi
  printf '%s\n' "$erasure"
}

dotfiles_rebuild_publish_successor_erasure() {
  local state_root=$1 parent_id=$2 child_id=$3 reason=$4 keep_roots=$5 active_receipt=$6
  local expected_uid=$7 expected_gid=$8 expected_worktree=$9 nix_store_dir=${10}
  local nix_gc_auto_roots_dir=${11} expected_user=${12}
  local directory target preparation child desired observed authorization authorization_metadata
  local preparation_metadata parent_receipt erasure temporary role active_id
  [[ $parent_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $reason =~ ^(cancel-requested|discard-partial|consumed-handoff)$ &&
    $keep_roots =~ ^[01]$ ]] || return 1
  [[ ( $reason == consumed-handoff && $keep_roots -eq 1 ) ||
    ( $reason != consumed-handoff && $keep_roots -eq 0 ) ]] || return 1
  dotfiles_rebuild_prepare_successor_protocol \
    "$state_root" "$expected_uid" "$expected_gid" || return 1
  directory=$state_root/successor-erasures
  target=$directory/$parent_id-$child_id.json
  if [[ -e $target || -L $target ]]; then
    dotfiles_rebuild_validate_successor_erasure \
      "$state_root" "$target" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" \
      >/dev/null || return 1
    printf '%s\n' "$target"
    return 0
  fi
  preparation=$state_root/successor-preparations/$parent_id-$child_id.json
  child=$(dotfiles_rebuild_validate_successor_preparation \
    "$state_root" "$preparation" "$expected_uid" "$expected_gid" "$expected_worktree" \
    "$nix_store_dir" "$expected_user") || return 1
  preparation_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
    "$state_root" "$preparation" "$expected_uid" "$expected_gid" 400) || return 1
  parent_receipt=$(jq -c '.lineage.parentReceipt' <<< "$child") || return 1
  desired=$(dotfiles_rebuild_desired_successor_roots "$child") || return 1
  observed=$(dotfiles_rebuild_observe_successor_roots \
    "$state_root" "$child" "$expected_uid" "$expected_gid" "$nix_store_dir" \
    "$nix_gc_auto_roots_dir" "$keep_roots") || return 1
  authorization=$state_root/successors/$parent_id.json
  authorization_metadata=null
  if [[ -e $authorization || -L $authorization ]]; then
    active_id=$(jq -er '.transactionId' "$active_receipt") || return 1
    if [[ $active_id == "$parent_id" ]]; then role=pending
    elif [[ $active_id == "$child_id" ]]; then role=consumed
    else return 1
    fi
    dotfiles_rebuild_validate_successor_authorization_content \
      "$state_root" "$authorization" "$parent_id" "$active_receipt" "$role" \
      "$expected_uid" "$expected_gid" "$expected_worktree" "$nix_store_dir" \
      "$nix_gc_auto_roots_dir" "$expected_user" >/dev/null || return 1
    authorization_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
      "$state_root" "$authorization" "$expected_uid" "$expected_gid" 400) || return 1
  elif [[ $keep_roots -eq 1 ]]; then
    return 1
  fi
  erasure=$(jq -cn --argjson schemaVersion 2 --arg kind successor-erasure \
    --arg parentTransactionId "$parent_id" --arg childTransactionId "$child_id" \
    --arg reason "$reason" \
    --argjson keepRoots "$([[ $keep_roots -eq 1 ]] && printf true || printf false)" \
    --argjson preparation "$preparation_metadata" \
    --argjson authorization "$authorization_metadata" \
    --argjson parentReceipt "$parent_receipt" --argjson desiredRoots "$desired" \
    --argjson observedRoots "$(jq -c '.observedRoots' <<< "$observed")" \
    --argjson observedRootTemps "$(jq -c '.observedRootTemps' <<< "$observed")" \
    --argjson observedAutoRoots "$(jq -c '.observedAutoRoots' <<< "$observed")" \
    --argjson observedAutoRootTemps "$(jq -c '.observedAutoRootTemps' <<< "$observed")" \
    --arg createdAt "$(jq -r '.lineage.createdAt' <<< "$child")" '
      {
        schemaVersion: $schemaVersion,
        kind: $kind,
        parentTransactionId: $parentTransactionId,
        childTransactionId: $childTransactionId,
        reason: $reason,
        keepRoots: $keepRoots,
        preparation: $preparation,
        authorization: $authorization,
        parentReceipt: $parentReceipt,
        desiredRoots: $desiredRoots,
        observedRoots: $observedRoots,
        observedRootTemps: $observedRootTemps,
        observedAutoRoots: $observedAutoRoots,
        observedAutoRootTemps: $observedAutoRootTemps,
        createdAt: $createdAt
      }
    ') || return 1
  temporary=$(mktemp "$(dotfiles_rebuild_successor_publish_temp_template \
    "$state_root" erasure "$parent_id" "$child_id")") || return 1
  printf '%s\n' "$erasure" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0400 "$temporary" || { rm -f -- "$temporary"; return 1; }
  # Validate the immutable inputs once more before the revocation becomes visible.
  [[ $(jq -cS . "$temporary") == "$(jq -cS . <<< "$erasure")" ]] || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -T --no-copy --update=none-fail -- "$temporary" "$target" || {
    rm -f -- "$temporary"
    return 1
  }
  sync --data "$target" || return 1
  sync "$directory" || return 1
  sync "$state_root" || return 1
  dotfiles_rebuild_validate_successor_erasure \
    "$state_root" "$target" "$active_receipt" "$expected_uid" "$expected_gid" \
    "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" \
    >/dev/null || return 1
  printf '%s\n' "$target"
}

dotfiles_rebuild_unlink_protocol_entry() {
  local entry=$1 directory=$2
  [[ $entry == "$directory/"* && ( -e $entry || -L $entry ) ]] || return 1
  rm -- "$entry" || return 1
  sync "$directory" || return 1
}

dotfiles_rebuild_validate_successor_erasure_again() {
  dotfiles_rebuild_validate_successor_erasure "$@" >/dev/null
}

dotfiles_rebuild_cleanup_successor_v2() {
  local state_root=$1 parent_id=$2 child_id=$3 reason=$4 keep_roots=$5 phase=$6 active_receipt=$7
  local expected_uid=$8 expected_gid=$9 expected_worktree=${10} nix_store_dir=${11}
  local nix_gc_auto_roots_dir=${12} expected_user=${13}
  local erasure_file erasure authorization preparation garbage_root source_lineage source_roots
  local garbage_lineage garbage_roots entry label parent_archive child record
  local -a root_labels=(source candidate recovery-target previous-booted displaced-profile)

  [[ $parent_id =~ ^[0-9a-f]{32}$ && $child_id =~ ^[0-9a-f]{32}$ &&
    $reason =~ ^(cancel-requested|discard-partial|consumed-handoff)$ &&
    $keep_roots =~ ^[01]$ && $phase =~ ^(run|begin|finish|retire)$ ]] || return 1
  erasure_file=$state_root/successor-erasures/$parent_id-$child_id.json
  if [[ ! -e $erasure_file && ! -L $erasure_file ]]; then
    [[ $phase != retire ]] || return 1
    dotfiles_rebuild_publish_successor_erasure \
      "$state_root" "$parent_id" "$child_id" "$reason" "$keep_roots" "$active_receipt" \
      "$expected_uid" "$expected_gid" "$expected_worktree" "$nix_store_dir" \
      "$nix_gc_auto_roots_dir" "$expected_user" >/dev/null || return 1
  fi
  erasure=$(dotfiles_rebuild_validate_successor_erasure \
    "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
    "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user") || return 1
  [[ $(jq -r '.keepRoots' <<< "$erasure") == \
    "$([[ $keep_roots -eq 1 ]] && printf true || printf false)" ]] || return 1
  [[ $(jq -r '.reason' <<< "$erasure") == "$reason" ]] || return 1
  authorization=$state_root/successors/$parent_id.json
  preparation=$state_root/successor-preparations/$parent_id-$child_id.json
  garbage_root=$state_root/successor-garbage/$parent_id-$child_id
  source_lineage=$state_root/lineage/$parent_id
  source_roots=$state_root/roots/$child_id
  garbage_lineage=$garbage_root/lineage
  garbage_roots=$garbage_root/roots

  if [[ $keep_roots -eq 1 ]]; then
    if [[ $phase == begin ]]; then
      return 0
    fi
    [[ $phase == finish ]] || return 1
    parent_archive=$state_root/receipts/$parent_id.json
    dotfiles_rebuild_validate_receipt_file \
      "$parent_archive" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
      "$expected_user" 600 || return 1
    dotfiles_rebuild_verify_receipt_evidence \
      "$state_root" "$(cat -- "$parent_archive")" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$expected_user" || return 1
    child=$(cat -- "$active_receipt") || return 1
    [[ $(jq -r '.transactionId' <<< "$child") == "$child_id" ]] || return 1
    dotfiles_rebuild_observe_successor_roots \
      "$state_root" "$child" "$expected_uid" "$expected_gid" "$nix_store_dir" \
      "$nix_gc_auto_roots_dir" 1 >/dev/null || return 1
    if [[ -e $authorization || -L $authorization ]]; then
      dotfiles_rebuild_validate_successor_erasure_again \
        "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
      dotfiles_rebuild_unlink_protocol_entry \
        "$authorization" "$state_root/successors" || return 1
    fi
    if [[ -e $preparation || -L $preparation ]]; then
      dotfiles_rebuild_validate_successor_erasure_again \
        "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
      dotfiles_rebuild_unlink_protocol_entry \
        "$preparation" "$state_root/successor-preparations" || return 1
    fi
    dotfiles_rebuild_observe_successor_roots \
      "$state_root" "$child" "$expected_uid" "$expected_gid" "$nix_store_dir" \
      "$nix_gc_auto_roots_dir" 1 >/dev/null || return 1
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    dotfiles_rebuild_unlink_protocol_entry \
      "$erasure_file" "$state_root/successor-erasures" || return 1
    return 0
  fi

  if [[ $phase == retire ]]; then
    [[ ! -e $authorization && ! -L $authorization &&
      ! -e $preparation && ! -L $preparation &&
      ! -e $source_lineage && ! -L $source_lineage &&
      ! -e $source_roots && ! -L $source_roots &&
      ! -e $garbage_root && ! -L $garbage_root ]] || return 1
    # Nix daemon owns indirect GC registrations.  The erasure validator has
    # already proved that each observed registration is either absent or the
    # exact recorded symlink; retiring user-owned roots must not unlink it.
    dotfiles_rebuild_unlink_protocol_entry \
      "$erasure_file" "$state_root/successor-erasures" || return 1
    return 0
  fi
  [[ $phase == run ]] || return 1

  # The erasure record is the authority from this point on.  Revalidation before
  # every mutation makes a killed cleanup resume from an authenticated subset.
  if [[ -e $authorization || -L $authorization ]]; then
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    dotfiles_rebuild_unlink_protocol_entry \
      "$authorization" "$state_root/successors" || return 1
  fi
  if [[ ( -e $source_lineage || -L $source_lineage || -e $source_roots || -L $source_roots ) &&
    ! -e $garbage_root && ! -L $garbage_root ]]; then
    mkdir -m 0700 -- "$garbage_root" || return 1
    sync "$state_root/successor-garbage" || return 1
  fi
  if [[ -e $source_lineage || -L $source_lineage ]]; then
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    [[ ! -e $garbage_lineage && ! -L $garbage_lineage ]] || return 1
    mv -T --no-copy -- "$source_lineage" "$garbage_lineage" || return 1
    sync "$state_root/lineage" || return 1
    sync "$garbage_root" || return 1
  fi
  if [[ -e $source_roots || -L $source_roots ]]; then
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    [[ ! -e $garbage_roots && ! -L $garbage_roots ]] || return 1
    mv -T --no-copy -- "$source_roots" "$garbage_roots" || return 1
    sync "$state_root/roots" || return 1
    sync "$garbage_root" || return 1
  fi
  if [[ -e $garbage_lineage || -L $garbage_lineage ]]; then
    entry=$garbage_lineage/verification-failed.json
    if [[ -e $entry || -L $entry ]]; then
      dotfiles_rebuild_validate_successor_erasure_again \
        "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
      rm -- "$entry" || return 1
      sync "$garbage_lineage" || return 1
    fi
    rmdir -- "$garbage_lineage" || return 1
    sync "$garbage_root" || return 1
  fi
  if [[ -e $garbage_roots || -L $garbage_roots ]]; then
    for label in "${root_labels[@]}"; do
      entry=$garbage_roots/$label
      [[ -e $entry || -L $entry ]] || continue
      jq -e --arg label "$label" '.observedRoots | has($label)' \
        <<< "$erasure" >/dev/null || return 1
      dotfiles_rebuild_validate_successor_erasure_again \
        "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
      rm -- "$entry" || return 1
      sync "$garbage_roots" || return 1
    done
    while IFS= read -r record; do
      [[ -n $record ]] || continue
      entry=$garbage_roots/$(jq -er '.path | split("/") | last' <<< "$record") || return 1
      [[ -e $entry || -L $entry ]] || continue
      dotfiles_rebuild_validate_successor_erasure_again \
        "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
        "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
      rm -- "$entry" || return 1
      sync "$garbage_roots" || return 1
    done < <(jq -c '.observedRootTemps[]' <<< "$erasure")
    rmdir -- "$garbage_roots" || return 1
    sync "$garbage_root" || return 1
  fi
  if [[ -e $garbage_root || -L $garbage_root ]]; then
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    rmdir -- "$garbage_root" || return 1
    sync "$state_root/successor-garbage" || return 1
  fi
  if [[ -e $preparation || -L $preparation ]]; then
    dotfiles_rebuild_validate_successor_erasure_again \
      "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
      "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" || return 1
    dotfiles_rebuild_unlink_protocol_entry \
      "$preparation" "$state_root/successor-preparations" || return 1
  fi
  dotfiles_rebuild_validate_successor_erasure_again \
    "$state_root" "$erasure_file" "$active_receipt" "$expected_uid" "$expected_gid" \
    "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user"
}

dotfiles_rebuild_validate_successor_erasure_owner() {
  local reason=$1 parent_id=$2 child_id=$3 active_schema=$4 active_id=$5 direct_parent=$6

  case $reason in
    cancel-requested | discard-partial)
      [[ $active_id == "$parent_id" ]]
      ;;
    consumed-handoff)
      [[ $active_schema == 4 && $active_id == "$child_id" &&
        $direct_parent == "$parent_id" ]]
      ;;
    *) return 1 ;;
  esac
}

dotfiles_rebuild_validate_successor_edge_graph() {
  local active_id=$1 direct_parent=$2 edge parent_id child_id start current
  shift 2
  local -A child_by_parent=() parent_by_child=() visited=()

  [[ $active_id =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ -z $direct_parent || $direct_parent =~ ^[0-9a-f]{32}$ ]] || return 1
  for edge in "$@"; do
    [[ $edge =~ ^([0-9a-f]{32}):([0-9a-f]{32})$ ]] || return 1
    parent_id=${BASH_REMATCH[1]}
    child_id=${BASH_REMATCH[2]}
    [[ $parent_id != "$child_id" &&
      ( $parent_id == "$active_id" || $parent_id == "$direct_parent" ) ]] || return 1
    [[ -z ${child_by_parent[$parent_id]+x} ||
      ${child_by_parent[$parent_id]} == "$child_id" ]] || return 1
    [[ -z ${parent_by_child[$child_id]+x} ||
      ${parent_by_child[$child_id]} == "$parent_id" ]] || return 1
    child_by_parent[$parent_id]=$child_id
    parent_by_child[$child_id]=$parent_id
  done

  for start in "${!child_by_parent[@]}"; do
    visited=()
    current=$start
    while [[ -n ${child_by_parent[$current]+x} ]]; do
      [[ -z ${visited[$current]+x} ]] || return 1
      visited[$current]=1
      current=${child_by_parent[$current]}
    done
  done
}

dotfiles_rebuild_validate_successor_protocol_state() {
  local state_root=$1 active_receipt=$2 expected_uid=$3 expected_gid=$4 expected_worktree=$5
  local nix_store_dir=$6 nix_gc_auto_roots_dir=$7 expected_user=$8
  local directory entry name parent_id child_id active_id='' active_schema='' direct_parent=''
  local authorization role erasure erasure_reason child
  local -A preparations=() authorizations=() erasures=() garbage=()
  local -a edges=()

  if [[ -n $active_receipt ]]; then
    dotfiles_rebuild_validate_receipt_file \
      "$active_receipt" "$expected_uid" "$expected_worktree" "$nix_store_dir" \
      "$expected_user" 600 || return 1
    active_id=$(jq -er '.transactionId' "$active_receipt") || return 1
    active_schema=$(jq -er '.schemaVersion' "$active_receipt") || return 1
    direct_parent=$(jq -r '.lineage.parentTransactionId // empty' "$active_receipt") || return 1
  fi
  for directory in successor-preparations successors successor-erasures successor-garbage; do
    [[ -e $state_root/$directory || -L $state_root/$directory ]] || continue
    dotfiles_rebuild_validate_lineage_directory \
      "$state_root/$directory" "$expected_uid" "$expected_gid" || return 1
    while IFS= read -r -d '' entry; do
      name=${entry##*/}
      case $directory in
        successor-preparations)
          [[ $name =~ ^([0-9a-f]{32})-([0-9a-f]{32})\.json$ ]] || return 1
          parent_id=${BASH_REMATCH[1]}
          child_id=${BASH_REMATCH[2]}
          [[ -z ${preparations[$parent_id]+x} ]] || return 1
          preparations[$parent_id]=$child_id
          edges+=("$parent_id:$child_id")
          child=$(dotfiles_rebuild_validate_successor_preparation \
            "$state_root" "$entry" "$expected_uid" "$expected_gid" "$expected_worktree" \
            "$nix_store_dir" "$expected_user") || return 1
          dotfiles_rebuild_observe_successor_roots \
            "$state_root" "$child" "$expected_uid" "$expected_gid" "$nix_store_dir" \
            "$nix_gc_auto_roots_dir" 0 >/dev/null || return 1
          ;;
        successors)
          [[ $name =~ ^([0-9a-f]{32})\.json$ ]] || return 1
          parent_id=${BASH_REMATCH[1]}
          [[ -z ${authorizations[$parent_id]+x} && -n $active_id ]] || return 1
          authorization=$(cat -- "$entry") || return 1
          child_id=$(jq -er '.child.transactionId' <<< "$authorization") || return 1
          authorizations[$parent_id]=$child_id
          edges+=("$parent_id:$child_id")
          if [[ $active_id == "$parent_id" ]]; then role=pending
          elif [[ $direct_parent == "$parent_id" && $active_id == "$child_id" ]]; then role=consumed
          else return 1
          fi
          dotfiles_rebuild_validate_successor_authorization_content \
            "$state_root" "$entry" "$parent_id" "$active_receipt" "$role" \
            "$expected_uid" "$expected_gid" "$expected_worktree" "$nix_store_dir" \
            "$nix_gc_auto_roots_dir" "$expected_user" \
            "$([[ -e $state_root/successor-erasures/$parent_id-$child_id.json ]] && printf 1 || printf 0)" \
            >/dev/null || return 1
          ;;
        successor-erasures)
          [[ $name =~ ^([0-9a-f]{32})-([0-9a-f]{32})\.json$ ]] || return 1
          parent_id=${BASH_REMATCH[1]}
          child_id=${BASH_REMATCH[2]}
          [[ -z ${erasures[$parent_id]+x} ]] || return 1
          erasures[$parent_id]=$child_id
          edges+=("$parent_id:$child_id")
          dotfiles_rebuild_validate_successor_erasure \
            "$state_root" "$entry" "$active_receipt" "$expected_uid" "$expected_gid" \
            "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" \
            >/dev/null || return 1
          erasure_reason=$(jq -er '.reason' "$entry") || return 1
          dotfiles_rebuild_validate_successor_erasure_owner \
            "$erasure_reason" "$parent_id" "$child_id" "$active_schema" \
            "$active_id" "$direct_parent" || return 1
          ;;
        successor-garbage)
          [[ $name =~ ^([0-9a-f]{32})-([0-9a-f]{32})$ ]] || return 1
          parent_id=${BASH_REMATCH[1]}
          child_id=${BASH_REMATCH[2]}
          [[ -z ${garbage[$parent_id]+x} ]] || return 1
          garbage[$parent_id]=$child_id
          edges+=("$parent_id:$child_id")
          erasure=$state_root/successor-erasures/$parent_id-$child_id.json
          [[ -f $erasure && ! -L $erasure ]] || return 1
          dotfiles_rebuild_validate_successor_erasure \
            "$state_root" "$erasure" "$active_receipt" "$expected_uid" "$expected_gid" \
            "$expected_worktree" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$expected_user" \
            >/dev/null || return 1
          ;;
      esac
    done < <(find "$state_root/$directory" -mindepth 1 -maxdepth 1 -print0)
  done

  for parent_id in "${!preparations[@]}"; do
    child_id=${preparations[$parent_id]}
    [[ -z ${authorizations[$parent_id]+x} || ${authorizations[$parent_id]} == "$child_id" ]] || return 1
    [[ -z ${erasures[$parent_id]+x} || ${erasures[$parent_id]} == "$child_id" ]] || return 1
    [[ -n $active_id && ( $parent_id == "$active_id" || $parent_id == "$direct_parent" ) ]] || return 1
  done
  for parent_id in "${!authorizations[@]}"; do
    child_id=${authorizations[$parent_id]}
    [[ ${preparations[$parent_id]:-} == "$child_id" ]] || return 1
    [[ -z ${erasures[$parent_id]+x} || ${erasures[$parent_id]} == "$child_id" ]] || return 1
  done
  for parent_id in "${!garbage[@]}"; do
    [[ ${erasures[$parent_id]:-} == "${garbage[$parent_id]}" ]] || return 1
    [[ -n $active_id && ( $parent_id == "$active_id" || $parent_id == "$direct_parent" ) ]] || return 1
  done
  if [[ ${#edges[@]} -gt 0 ]]; then
    dotfiles_rebuild_validate_successor_edge_graph \
      "$active_id" "$direct_parent" "${edges[@]}" || return 1
  fi
}
