set -euo pipefail

@atomicFileFunctions@

@operationLockFunctions@

@rebuildReceiptFunctions@

@rebuildAttemptFunctions@

sudo_command=@sudoCommand@

usage() {
  cat <<'USAGE'
usage:
  dotfiles-rebuild
  dotfiles-rebuild --plan
  dotfiles-rebuild --forward-recover TRANSACTION_ID
  dotfiles-rebuild --cancel-forward-recover TRANSACTION_ID
  dotfiles-rebuild --resume TRANSACTION_ID
  dotfiles-rebuild --first-boot TRANSACTION_ID
  dotfiles-rebuild --rollback TRANSACTION_ID
  dotfiles-rebuild --abort TRANSACTION_ID
  dotfiles-rebuild --status

Build and verify one immutable flake snapshot, then apply the pre-built candidate. A persistent
receipt records activation and verification separately. Restart-required transactions remain
active until --resume verifies the candidate. --rollback restores a compatible previous system.
--forward-recover creates a new transaction only for an applied candidate whose verifier failed.
--abort closes a transaction only when the profile commit and activation did not occur.
USAGE
}

die() {
  local status=$1
  shift
  echo "FATAL: $*" >&2
  exit "$status"
}

mode=apply
transaction_argument=
if (( $# == 1 )) && [[ $1 == --plan ]]; then
  mode=plan
elif (( $# == 1 )) && [[ $1 == --status ]]; then
  mode=status
elif (( $# == 2 )) && [[ $1 == --resume ]]; then
  mode=resume
  transaction_argument=$2
elif (( $# == 2 )) && [[ $1 == --forward-recover ]]; then
  mode=forward-recover
  transaction_argument=$2
elif (( $# == 2 )) && [[ $1 == --cancel-forward-recover ]]; then
  mode=cancel-forward-recover
  transaction_argument=$2
elif (( $# == 2 )) && [[ $1 == --first-boot ]]; then
  mode=first-boot
  transaction_argument=$2
elif (( $# == 2 )) && [[ $1 == --rollback ]]; then
  mode=rollback
  transaction_argument=$2
elif (( $# == 2 )) && [[ $1 == --abort ]]; then
  mode=abort
  transaction_argument=$2
elif (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
  usage
  exit 0
elif (( $# != 0 )); then
  usage >&2
  exit 2
fi

if [[ $EUID -eq 0 && ${DOTFILES_REBUILD_ALLOW_ROOT:-0} != 1 ]]; then
  die 2 "run dotfiles-rebuild as the regular user; only activation is elevated"
fi

dotfiles="@dotfilesDir@"
nix_store_dir="@nixStoreDir@"
nix_gc_auto_roots_dir="@nixGcAutoRootDir@"
system_profile_path="@systemProfilePath@"
doctor_schema_version="@doctorSchemaVersion@"
legacy_doctor_schema_version="@legacyDoctorSchemaVersion@"
legacy_schema2_rebuild_source_sha256="@legacySchema2RebuildSourceSha256@"
legacy_schema2_candidate_helper_sha256="@legacySchema2CandidateHelperSha256@"
legacy_schema2_nixpkgs_rev="@legacySchema2NixpkgsRev@"
legacy_schema2_nixos_rebuild_path="@legacySchema2NixosRebuildPath@"
configured_user="@username@"
boot_id_file="@bootIdFile@"
flake="git+file://$dotfiles"
transaction_user=$(id -un)
[[ $transaction_user == "$configured_user" ]] || \
  die 2 "run dotfiles-rebuild as configured user $configured_user"
common_git_dir=$(git -C "$dotfiles" rev-parse --path-format=absolute --git-common-dir) || \
  die 2 "failed to resolve the Git common directory"
operation_lock_bootstrap_mode=create
[[ $mode != status && $mode != plan ]] || operation_lock_bootstrap_mode=existing-only
dotfiles_acquire_operation_lock \
  "$common_git_dir" "$EUID" "$(id -g)" "$operation_lock_bootstrap_mode" || \
  die 1 "failed to acquire the dotfiles operation lock"

state_root=$common_git_dir/dotfiles-rebuild
active_receipt=$state_root/active.json
active_enrollment=$common_git_dir/dotfiles-sops-enroll/active.json
state_root_exists=0
if [[ -e $state_root || -L $state_root ]]; then
  dotfiles_rebuild_validate_state_root "$state_root" "$EUID" "$(id -g)" || \
    die 2 "rebuild receipt storage is invalid"
  state_root_exists=1
fi
active_exists=0
if [[ -e $active_receipt || -L $active_receipt ]]; then
  active_exists=1
fi
publication_active_id=
if [[ $active_exists -eq 1 ]]; then
  publication_active_id=$(dotfiles_rebuild_read_active_publication_id \
    "$state_root" "$EUID" "$(id -g)" 2>/dev/null || true)
fi

verify_receipt_artifacts() {
  local receipt=$1 helper
  dotfiles_rebuild_verify_receipt_evidence \
    "$state_root" "$receipt" "$EUID" "$(id -g)" "$dotfiles" \
    "$nix_store_dir" "$configured_user" || return 1
  if [[ $(jq -r '.schemaVersion == 4 and .lineage != null' <<< "$receipt") == true ]]; then
    for helper in rebuild syncImages doctor; do
      dotfiles_rebuild_validate_successor_helper \
        "$(jq -c --arg helper "$helper" '.lineage.execution.helpers[$helper]' \
          <<< "$receipt")" \
        "$(jq -r '.candidate' <<< "$receipt")" "$helper" "$nix_store_dir" || return 1
    done
    dotfiles_rebuild_validate_successor_manifest \
      "$(jq -c '.lineage.execution.manifest' <<< "$receipt")" \
      "$(jq -r '.candidate' <<< "$receipt")" "$nix_store_dir" || return 1
  fi
}

delegate_authorized_controller() {
  local helper=$1 current_controller
  current_controller=$(readlink -e -- "$0" 2>/dev/null) || \
    die 2 "failed to resolve the running rebuild controller"
  [[ $current_controller != "$helper" ]] || return 0
  dotfiles_release_operation_lock
  exec "$helper" "--$mode" "$transaction_argument"
  die 1 "failed to execute the authorized immutable rebuild controller: $helper"
}

maybe_delegate_authorized_controller() {
  local receipt=$1 schema lineage authorization_file authorization metadata candidate helper erasure_file
  schema=$(jq -er '.schemaVersion' <<< "$receipt") || \
    die 2 "active rebuild schema is invalid"
  lineage=$(jq -r '.lineage != null' <<< "$receipt") || \
    die 2 "active rebuild lineage is invalid"

  if [[ $mode == forward-recover || $mode == cancel-forward-recover ]]; then
    # Publishing erasure revokes the live authorization.  The write-once erasure
    # record becomes the cleanup authority and is validated by this reviewed
    # checkout before any mutation; it must not be exercised as live child auth.
    for erasure_file in "$state_root/successor-erasures/$transaction_argument-"*.json; do
      [[ -e $erasure_file || -L $erasure_file ]] || continue
      return 0
    done
    authorization_file=$state_root/successors/$transaction_argument.json
    [[ -e $authorization_file || -L $authorization_file ]] || return 0
    authorization=$(dotfiles_rebuild_read_successor_authorization_v2 \
      "$state_root" "$transaction_argument" "$active_receipt" pending "$EUID" "$(id -g)" \
      "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user") || \
      die 2 "pending forward recovery authorization is invalid"
    candidate=$(jq -er '.child.candidate' <<< "$authorization") || \
      die 2 "authorized successor candidate is invalid"
    metadata=$(jq -c '.child.helpers.rebuild' <<< "$authorization") || \
      die 2 "authorized successor rebuild controller metadata is invalid"
    dotfiles_rebuild_validate_successor_helper \
      "$metadata" "$candidate" rebuild "$nix_store_dir" || \
      die 2 "authorized successor rebuild controller differs from its execution contract"
    helper=$(jq -er '.canonicalPath' <<< "$metadata") || \
      die 2 "authorized successor rebuild controller path is invalid"
    delegate_authorized_controller "$helper"
    return 0
  fi

  if [[ $mode =~ ^(resume|first-boot|rollback|abort)$ &&
    $schema -eq 4 && $lineage == true ]]; then
    candidate=$(jq -er '.candidate' <<< "$receipt") || \
      die 2 "active successor candidate is invalid"
    metadata=$(jq -c '.lineage.execution.helpers.rebuild' <<< "$receipt") || \
      die 2 "active successor rebuild controller metadata is invalid"
    dotfiles_rebuild_validate_successor_helper \
      "$metadata" "$candidate" rebuild "$nix_store_dir" || \
      die 2 "active successor rebuild controller differs from its execution contract"
    helper=$(jq -er '.canonicalPath' <<< "$metadata") || \
      die 2 "active successor rebuild controller path is invalid"
    delegate_authorized_controller "$helper"
  fi
}

validate_successor_protocol_state() {
  local receipt_file=${1:-}
  dotfiles_rebuild_validate_successor_protocol_state \
    "$state_root" "$receipt_file" "$EUID" "$(id -g)" "$dotfiles" \
    "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user"
}

require_complete_successor_publication() {
  local receipt_data=${1:-} active_id='' active_schema='' active_direct_parent=''
  local inspection_status
  if [[ -n $receipt_data ]]; then
    active_id=$(jq -er '.transactionId' <<< "$receipt_data") || \
      die 2 "active rebuild transaction ID is invalid"
    active_schema=$(jq -er '.schemaVersion' <<< "$receipt_data") || \
      die 2 "active rebuild schema is invalid"
    active_direct_parent=$(jq -r '.lineage.parentTransactionId // empty' \
      <<< "$receipt_data") || die 2 "active rebuild direct parent is invalid"
  fi
  if dotfiles_rebuild_inspect_successor_publish_temps \
    "$state_root" "$active_id" "$active_schema" "$active_direct_parent" \
    "$EUID" "$(id -g)"; then
    return 0
  else
    inspection_status=$?
  fi
  if [[ $inspection_status -eq 3 ]]; then
    die 2 "forward recovery publication is incomplete; retry its active transaction recovery command"
  fi
  die 2 "forward recovery publication temp state is invalid"
}

require_complete_active_publication() {
  local active_id=${1:-} inspection_status
  if dotfiles_rebuild_inspect_active_publish_temps \
    "$state_root" "$active_id" "$EUID" "$(id -g)"; then
    return 0
  else
    inspection_status=$?
  fi
  if [[ $inspection_status -eq 3 ]]; then
    die 2 "active receipt publication is incomplete; retry its owning mutating command"
  fi
  die 2 "active receipt publication temp state is invalid"
}

cleanup_active_publication() {
  local active_id=${1:-}
  dotfiles_rebuild_cleanup_active_publish_temps \
    "$state_root" "$active_id" "$EUID" "$(id -g)" || \
    die 2 "active receipt publication temp state is invalid"
}

if [[ $mode == status ]]; then
  if [[ $active_exists -eq 0 ]]; then
    if [[ $state_root_exists -eq 1 ]]; then
      require_complete_active_publication
      require_complete_successor_publication
      validate_successor_protocol_state || \
        die 2 "forward recovery protocol state is invalid"
    fi
    echo '{"state":"idle"}'
    exit 0
  fi
  require_complete_active_publication "$publication_active_id"
  active=$(dotfiles_rebuild_read_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user") || \
    die 2 "the active rebuild receipt is invalid"
  verify_receipt_artifacts "$active" || \
    die 2 "the active rebuild activation journal is invalid"
  require_complete_successor_publication "$active"
  validate_successor_protocol_state "$active_receipt" || \
    die 2 "forward recovery protocol state is invalid"
  printf '%s\n' "$active"
  exit 0
fi

case $mode in
  apply | plan)
    if [[ $active_exists -eq 1 ]]; then
      require_complete_active_publication "$publication_active_id"
      active=$(dotfiles_rebuild_read_active_receipt \
        "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user") || \
        die 2 "the active rebuild receipt is invalid"
      verify_receipt_artifacts "$active" || \
        die 2 "the active rebuild activation journal is invalid"
      require_complete_successor_publication "$active"
      validate_successor_protocol_state "$active_receipt" || \
        die 2 "forward recovery protocol state is invalid"
      active_id=$(jq -r '.transactionId' <<< "$active")
      active_state=$(jq -r '.state' <<< "$active")
      die 1 "active rebuild transaction $active_id ($active_state) blocks a new build; use its recovery instructions"
    else
      if [[ $state_root_exists -eq 1 ]]; then
        if [[ $mode == plan ]]; then
          require_complete_active_publication
        else
          cleanup_active_publication
        fi
        require_complete_successor_publication
      fi
      validate_successor_protocol_state || \
        die 2 "forward recovery protocol state is invalid"
    fi
    ;;
  resume | first-boot | rollback | abort | forward-recover | cancel-forward-recover)
    [[ $transaction_argument =~ ^[0-9a-f]{32}$ ]] || die 2 "transaction ID must contain 32 lowercase hexadecimal characters"
    [[ $active_exists -eq 1 ]] || die 2 "there is no active rebuild transaction"
    [[ $publication_active_id == "$transaction_argument" ]] || \
      die 2 "the active rebuild transaction does not match $transaction_argument"
    cleanup_active_publication "$transaction_argument"
    active=$(dotfiles_rebuild_read_active_receipt \
      "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user") || \
      die 2 "the active rebuild receipt is invalid"
    verify_receipt_artifacts "$active" || \
      die 2 "the active rebuild activation journal is invalid"
    [[ $(jq -r '.transactionId' <<< "$active") == "$transaction_argument" ]] || \
      die 2 "the active rebuild transaction does not match $transaction_argument"
    validate_successor_protocol_state "$active_receipt" || \
      die 2 "forward recovery protocol state is invalid"
    maybe_delegate_authorized_controller "$active"
    if [[ $mode =~ ^(resume|first-boot|rollback|abort)$ &&
      ( -e $state_root/successors/$transaction_argument.json ||
        -L $state_root/successors/$transaction_argument.json ||
        -n $(find "$state_root/successor-preparations" -maxdepth 1 \
          -name "$transaction_argument-*.json" -print -quit 2>/dev/null) ||
        -n $(find "$state_root/successor-erasures" -maxdepth 1 \
          -name "$transaction_argument-*.json" -print -quit 2>/dev/null) ) ]]; then
      die 2 "pending forward recovery blocks parent recovery operations; use --cancel-forward-recover $transaction_argument"
    fi
    ;;
esac

if [[ $mode =~ ^(resume|first-boot|rollback|abort|forward-recover|cancel-forward-recover)$ ]]; then
  active_id=$(jq -er '.transactionId' <<< "$active") || \
    die 2 "active rebuild transaction ID is invalid"
  active_schema=$(jq -er '.schemaVersion' <<< "$active") || \
    die 2 "active rebuild schema is invalid"
  active_direct_parent=$(jq -r '.lineage.parentTransactionId // empty' <<< "$active") || \
    die 2 "active rebuild direct parent is invalid"
  dotfiles_rebuild_cleanup_successor_publish_temps \
    "$state_root" "$active_id" "$active_schema" "$active_direct_parent" \
    "$EUID" "$(id -g)" || \
    die 2 "forward recovery publication temp state is invalid"
fi

if [[ $mode == apply && $state_root_exists -eq 1 ]]; then
  dotfiles_rebuild_cleanup_orphan_gc_roots \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" || \
    die 1 "failed to clean terminal or orphan rebuild GC roots"
fi

now() {
  date --utc --iso-8601=seconds
}

boot_instance() {
  local kernel_boot_id userspace_timestamp
  kernel_boot_id=$(cat -- "$boot_id_file") || return 1
  userspace_timestamp=$(systemctl --system show --property=UserspaceTimestampMonotonic --value) || return 1
  [[ $kernel_boot_id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  [[ $userspace_timestamp =~ ^[1-9][0-9]*$ ]] || return 1
  jq -cn \
    --arg kernelBootId "$kernel_boot_id" \
    --arg userspaceTimestampMonotonic "$userspace_timestamp" \
    '{kernelBootId: $kernelBootId, userspaceTimestampMonotonic: $userspaceTimestampMonotonic}'
}

same_boot_instance() {
  local left=$1 right=$2
  [[ $(jq -r '.kernelBootId' <<< "$left") == $(jq -r '.kernelBootId' <<< "$right") &&
    $(jq -r '.userspaceTimestampMonotonic' <<< "$left") == \
      $(jq -r '.userspaceTimestampMonotonic' <<< "$right") ]]
}

powershell_quote() {
  local value=$1
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

receipt_read() {
  dotfiles_rebuild_read_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user"
}

receipt_update() {
  dotfiles_rebuild_update_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$@" || \
    die 1 "failed to update the active rebuild receipt"
}

temporary_gc_roots=
successor_pending_id=
successor_parent_id=
successor_preparation_published=0
cleanup_temporary_gc_roots() {
  local entry active_id=
  if [[ -n $temporary_gc_roots && -d $temporary_gc_roots && ! -L $temporary_gc_roots ]]; then
    for entry in "$temporary_gc_roots"/*; do
      [[ -e $entry || -L $entry ]] || continue
      case ${entry##*/} in source | candidate) rm -- "$entry" || true ;; *) return 1 ;; esac
    done
    rmdir -- "$temporary_gc_roots" || true
  fi
  if [[ -n $successor_pending_id && $successor_preparation_published -eq 1 ]]; then
    if [[ -f $active_receipt && ! -L $active_receipt ]]; then
      active_id=$(jq -r '.transactionId // empty' "$active_receipt" 2>/dev/null || true)
    fi
    if [[ $active_id != "$successor_pending_id" && -n $successor_parent_id ]]; then
      dotfiles_rebuild_cleanup_successor_v2 \
        "$state_root" "$successor_parent_id" "$successor_pending_id" discard-partial 0 run \
        "$active_receipt" "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" \
        "$nix_gc_auto_roots_dir" "$configured_user" || true
    fi
  fi
}

runtime_snapshot() {
  local current booted profile generation
  current=$(readlink -f -- /run/current-system) || return 1
  booted=$(readlink -f -- /run/booted-system) || return 1
  profile=$(readlink -f -- "$system_profile_path") || return 1
  for generation in "$current" "$booted" "$profile"; do
    [[ $generation == "$nix_store_dir/"* && -d $generation ]] || return 1
  done
  jq -cn \
    --arg current "$current" \
    --arg booted "$booted" \
    --arg profile "$profile" \
    '{current: $current, booted: $booted, profile: $profile}'
}

same_runtime_snapshot() {
  local expected=$1 observed=$2
  [[ $(jq -cS . <<< "$expected") == "$(jq -cS . <<< "$observed")" ]]
}

abort_runtime_drift() {
  local direction=$1 point=$2 expected=$3 observed=$4 timestamp transaction_id
  timestamp=$(now)
  receipt_update \
    --arg direction "$direction" \
    --arg point "$point" \
    --argjson expected "$expected" \
    --argjson observed "$observed" \
    --arg timestamp "$timestamp" '
      .state = "aborted" |
      .abort = {
        direction: $direction,
        point: $point,
        expected: $expected,
        observed: $observed
      } |
      .failureStage = "runtime-drift" |
      .updatedAt = $timestamp |
      .finishedAt = $timestamp
    '
  transaction_id=$(jq -r '.transactionId' "$active_receipt")
  dotfiles_rebuild_archive_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$transaction_id" || \
    die 1 "failed to archive the aborted rebuild receipt"
  dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
    die 1 "failed to remove aborted rebuild GC roots"
  case $point in
    receipt-publication)
      die 2 "runtime generation changed after publishing the rebuild receipt; no activation was attempted"
      ;;
    intent-publication)
      die 2 "runtime generation changed before publishing activation intent; no activation was attempted"
      ;;
    activation-handoff)
      die 2 "runtime generation changed at activation handoff; no activation was attempted"
      ;;
    *) die 2 "runtime generation changed at an unknown activation boundary" ;;
  esac
}

assert_activation_baseline() {
  local direction=$1 point=$2 expected=$3 observed
  observed=$(runtime_snapshot) || die 2 "failed to resolve runtime generation at activation handoff"
  same_runtime_snapshot "$expected" "$observed" || \
    abort_runtime_drift "$direction" "$point" "$expected" "$observed"
}

activation_snapshot_is_owned() {
  local action=$1 target=$2 persisted=$3 observed=$4
  local persisted_current persisted_booted persisted_profile
  local observed_current observed_booted observed_profile
  persisted_current=$(jq -r '.current' <<< "$persisted")
  persisted_booted=$(jq -r '.booted' <<< "$persisted")
  persisted_profile=$(jq -r '.profile' <<< "$persisted")
  observed_current=$(jq -r '.current' <<< "$observed")
  observed_booted=$(jq -r '.booted' <<< "$observed")
  observed_profile=$(jq -r '.profile' <<< "$observed")

  case $action in
    switch)
      [[ $observed_booted == "$persisted_booted" &&
        ( $observed_current == "$persisted_current" || $observed_current == "$target" ) &&
        ( $observed_profile == "$persisted_profile" || $observed_profile == "$target" ) ]]
      ;;
    boot)
      if [[ $observed_current == "$target" && $observed_booted == "$target" &&
        $observed_profile == "$target" ]]; then
        return 0
      fi
      [[ $observed_current == "$persisted_current" &&
        $observed_booted == "$persisted_booted" &&
        ( $observed_profile == "$persisted_profile" || $observed_profile == "$target" ) ]]
      ;;
    *) return 1 ;;
  esac
}

activation_outcome_snapshot_is_valid() {
  local action=$1 target=$2 baseline=$3 observed=$4 boundary=$5 exit_code=$6
  local baseline_current baseline_booted baseline_profile
  local observed_current observed_booted observed_profile expected_boundary

  activation_snapshot_is_owned "$action" "$target" "$baseline" "$observed" || return 1
  baseline_current=$(jq -r '.current' <<< "$baseline")
  baseline_booted=$(jq -r '.booted' <<< "$baseline")
  baseline_profile=$(jq -r '.profile' <<< "$baseline")
  observed_current=$(jq -r '.current' <<< "$observed")
  observed_booted=$(jq -r '.booted' <<< "$observed")
  observed_profile=$(jq -r '.profile' <<< "$observed")

  if [[ $exit_code -eq 0 ]]; then
    [[ $boundary == after-profile-commit ]] || return 1
    case $action in
      switch)
        [[ $observed_current == "$target" && $observed_profile == "$target" &&
          $observed_booted == "$baseline_booted" ]]
        ;;
      boot)
        [[ $observed_current == "$baseline_current" &&
          $observed_booted == "$baseline_booted" && $observed_profile == "$target" ]]
        ;;
      *) return 1 ;;
    esac
    return
  fi

  if same_runtime_snapshot "$baseline" "$observed" &&
    [[ $baseline_profile != "$target" ]]; then
    expected_boundary=before-profile-commit
  elif [[ $observed_profile == "$target" ]]; then
    expected_boundary=after-profile-commit
  else
    expected_boundary=unknown
  fi
  [[ $boundary == "$expected_boundary" ]]
}

read_enrollment_marker() {
  local marker
  [[ -e $active_enrollment || -L $active_enrollment ]] || return 3
  [[ ! -L $active_enrollment && -f $active_enrollment ]] || {
    echo "the SOPS enrollment marker must be a regular file" >&2
    return 1
  }
  [[ $(stat -c '%u|%a|%h' -- "$active_enrollment") == "$EUID|600|1" ]] || {
    echo "the SOPS enrollment marker has invalid owner, mode, or link count" >&2
    return 1
  }
  marker=$(cat -- "$active_enrollment") || return 1
  jq -e \
    --arg worktree "$dotfiles" '
      .version == 2 and
      (.transactionId | type == "string" and test("^[0-9a-f]{32}$")) and
      (.hostId | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
      .worktree == $worktree and
      (.phase | IN("staging", "prepared", "generation-pending", "generation-checking")) and
      all(.oldConfigHash, .oldSecretsHash, .newConfigHash, .newSecretsHash;
        . == null or (type == "string" and test("^[0-9a-f]{64}$")))
    ' <<< "$marker" >/dev/null || return 1
  printf '%s\n' "$marker"
}

validate_enrollment_binding() {
  local receipt expected marker_status marker actual phase
  receipt=$(receipt_read) || return 1
  expected=$(jq -r '.sopsEnrollmentTransactionId // ""' <<< "$receipt")
  set +e
  marker=$(read_enrollment_marker)
  marker_status=$?
  set -e
  if [[ -z $expected ]]; then
    [[ $marker_status -eq 3 ]] || {
      echo "an unbound SOPS enrollment marker blocks rebuild recovery" >&2
      return 1
    }
    return 0
  fi
  [[ $marker_status -eq 0 ]] || {
    echo "the rebuild receipt requires its active SOPS enrollment marker" >&2
    return 1
  }
  actual=$(jq -r '.transactionId' <<< "$marker")
  phase=$(jq -r '.phase' <<< "$marker")
  [[ $actual == "$expected" && $phase == generation-pending ]] || {
    echo "the active SOPS enrollment marker does not match the rebuild receipt" >&2
    return 1
  }
}

ensure_receipt_roots() {
  local receipt transaction_id
  receipt=$(receipt_read) || die 1 "failed to read the active rebuild receipt"
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")
  dotfiles_rebuild_ensure_gc_roots \
    "$state_root" "$transaction_id" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
    source "$(jq -r '.source' <<< "$receipt")" \
    candidate "$(jq -r '.candidate' <<< "$receipt")" \
    recovery-target "$(jq -r '.recoveryTarget' <<< "$receipt")" \
    previous-booted "$(jq -r '.previous.booted' <<< "$receipt")" \
    displaced-profile "$(jq -r '.previous.displacedProfile' <<< "$receipt")" || \
    die 1 "failed to protect rebuild transaction store paths from garbage collection"
}

print_recovery() {
  local receipt transaction_id helper previous state failure_stage
  receipt=$(receipt_read) || return 1
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")
  if [[ $(jq -r '.schemaVersion == 4 and .lineage != null' <<< "$receipt") == true ]]; then
    helper=$(resolve_receipt_execution_helper "$receipt" rebuild) || return 1
  else
    helper=$(jq -r '.helperPath' <<< "$receipt")
  fi
  previous=$(jq -r '.recoveryTarget' <<< "$receipt")
  state=$(jq -r '.state' <<< "$receipt")
  failure_stage=$(jq -r '.failureStage // empty' <<< "$receipt")
  cat >&2 <<MSG
Recovery target: $previous
Retry the immutable candidate:
  $helper --resume $transaction_id
MSG
  if recovery_target_supports_rollback_protocol "$previous"; then
    cat >&2 <<MSG
Restore the recorded previous system:
  $helper --rollback $transaction_id
MSG
  else
    echo "Rollback unavailable: recovery target lacks the required doctor or OCI protocol." >&2
  fi
  if [[ $state == verification-failed && $failure_stage == doctor &&
    $(jq -r '.sopsEnrollmentTransactionId == null' <<< "$receipt") == true ]]; then
    cat >&2 <<MSG
Build a new immutable successor after repairing the verifier:
  nix run $dotfiles#dotfiles-rebuild -- --forward-recover $transaction_id
MSG
  fi
  evaluate_cancellation "$receipt"
  if [[ -z $cancellation_blocker ]]; then
    cat >&2 <<MSG
Close this zero-effect transaction without changing the system:
  $helper --abort $transaction_id
MSG
  fi
}

print_restart_instructions() {
  local direction=$1 effect=$2 receipt transaction_id distro helper expected_user
  local quoted_distro quoted_helper quoted_transaction quoted_user
  receipt=$(receipt_read) || die 1 "failed to read restart transaction"
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")
  distro=$(jq -r '.distro' <<< "$receipt")
  if [[ $(jq -r '.schemaVersion == 4 and .lineage != null' <<< "$receipt") == true ]]; then
    helper=$(resolve_receipt_execution_helper "$receipt" rebuild) || \
      die 1 "failed to resolve the restart transaction rebuild controller"
  else
    helper=$(jq -r '.helperPath' <<< "$receipt")
  fi
  if [[ $direction == forward ]]; then
    expected_user=$(jq -r '.candidateDefaultUser' <<< "$receipt")
  else
    expected_user=$(jq -r '.previousDefaultUser' <<< "$receipt")
  fi
  quoted_distro=$(powershell_quote "$distro")
  quoted_helper=$(powershell_quote "$helper")
  quoted_transaction=$(powershell_quote "$transaction_id")
  quoted_user=$(powershell_quote "$expected_user")

  if [[ $direction == forward ]]; then
    echo "The candidate is installed and transaction $transaction_id is restart-pending."
  else
    echo "The previous system is installed and transaction $transaction_id is rollback-restart-pending."
  fi
  echo "Run the following from PowerShell; the final command resumes and verifies this exact receipt:"
  echo
  printf '  wsl.exe --terminate %s\n' "$quoted_distro"
  if [[ $effect == boot-two-stage ]]; then
    printf '  wsl.exe --distribution %s --user root --exec /bin/true\n' "$quoted_distro"
    printf '  wsl.exe --distribution %s --user %s --exec %s --first-boot %s\n' \
      "$quoted_distro" "$quoted_user" "$quoted_helper" "$quoted_transaction"
    printf '  wsl.exe --terminate %s\n' "$quoted_distro"
  fi
  printf '  wsl.exe --distribution %s --exec %s --resume %s\n' \
    "$quoted_distro" "$quoted_helper" "$quoted_transaction"
}

finish_transaction() {
  local direction=$1 transaction_id final_state timestamp
  transaction_id=$(jq -r '.transactionId' <<< "$(receipt_read)")
  timestamp=$(now)
  if [[ $direction == forward ]]; then
    final_state=complete
  else
    final_state=rolled-back
  fi
  receipt_update \
    --arg state "$final_state" \
    --arg timestamp "$timestamp" '
      .state = $state |
      .verification = {status: "succeeded", exitCode: 0, failedCheckIds: []} |
      .failureStage = null |
      .updatedAt = $timestamp |
      .finishedAt = $timestamp
    '
  dotfiles_rebuild_archive_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$transaction_id" || \
    die 1 "failed to archive completed rebuild receipt"
  dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
    die 1 "failed to remove completed rebuild GC roots"
  printf 'Rebuild transaction %s: %s\n' "$transaction_id" "$final_state"
}

target_has_profile_generation() {
  local target=$1 profile_directory generation
  profile_directory=${system_profile_path%/*}
  [[ -d $profile_directory && ! -L $profile_directory ]] || return 2
  for generation in "$profile_directory"/system-*-link; do
    [[ -L $generation ]] || continue
    [[ $(readlink -f -- "$generation" 2>/dev/null || true) == "$target" ]] && return 0
  done
  return 1
}

recovery_target_supports_rollback_protocol() {
  local target=$1
  [[ $(read_doctor_manifest_schema "$target" 2>/dev/null || true) == "$doctor_schema_version" &&
    $(read_oci_image_manifest_schema "$target" 2>/dev/null || true) == 2 &&
    -x $target/sw/bin/dotfiles-sync-images ]]
}

evaluate_cancellation() {
  local receipt=$1 audited_schema2=${2:-0} schema state target generation_status

  cancellation_blocker=
  cancellation_expected_runtime=
  cancellation_observed_runtime=
  cancellation_expected_boot=
  cancellation_observed_boot=
  schema=$(jq -r '.schemaVersion' <<< "$receipt")
  state=$(jq -r '.state' <<< "$receipt")
  if [[ $schema -eq 2 && $audited_schema2 -eq 1 ]]; then
    :
  elif [[ $schema -ne 3 && $schema -ne 4 ]]; then
    cancellation_blocker="receipt schema $schema cannot be cancelled"
    return 0
  fi
  if [[ $(jq -r '.sopsEnrollmentTransactionId // empty' <<< "$receipt") != "" ]]; then
    cancellation_blocker="a SOPS enrollment-bound rebuild cannot be cancelled independently"
    return 0
  fi
  if [[ $(jq -r '.rollback == null' <<< "$receipt") != true ]]; then
    cancellation_blocker="a rebuild with rollback intent cannot be cancelled"
    return 0
  fi
  if [[ $(jq -r '.verification.status' <<< "$receipt") != pending ]]; then
    cancellation_blocker="a rebuild that entered verification cannot be cancelled"
    return 0
  fi
  case $state in
    prepared)
      if [[ $(jq -r '.activation.status' <<< "$receipt") != pending ||
        $(jq -r '.activation.attempts | length' <<< "$receipt") -ne 0 ]]; then
        cancellation_blocker="prepared rebuild contains an activation attempt"
        return 0
      fi
      ;;
    activation-failed)
      if [[ $schema -eq 2 ]]; then
        if [[ $(jq -r '.activation.status' <<< "$receipt") != failed ]]; then
          cancellation_blocker="the audited schema 2 activation failure is invalid"
          return 0
        fi
      elif ! jq -e '
          .activation.status == "failed" and (
            (
              .activation.attempts[-1].status == "failed" and
              .activation.attempts[-1].boundary == "before-profile-commit"
            ) or (
              (.activation.attempts | length) == 0 and
              .migration.fromSchema == 2 and
              .migration.classification == "before-profile-commit"
            )
          )
        ' <<< "$receipt" > /dev/null; then
        cancellation_blocker="the activation failure is not proven to precede the profile commit"
        return 0
      fi
      ;;
    activation-indeterminate)
      if ! jq -e '
        .activation.status == "indeterminate" and
        .activation.attempts[-1].status == "indeterminate" and
        .activation.attempts[-1].boundary == "before-profile-commit"
      ' <<< "$receipt" > /dev/null; then
        cancellation_blocker="the interrupted activation is not proven to precede the profile commit"
        return 0
      fi
      ;;
    *)
      cancellation_blocker="rebuild state $state cannot be cancelled"
      return 0
      ;;
  esac

  target=$(jq -r '.candidate' <<< "$receipt")
  cancellation_expected_runtime=$(jq -c '.activationBaseline' <<< "$receipt")
  if [[ $(jq -r '.profile' <<< "$cancellation_expected_runtime") == "$target" ]]; then
    cancellation_blocker="the target was already the baseline profile; profile commit cannot prove zero activation"
    return 0
  fi
  if ! cancellation_observed_runtime=$(runtime_snapshot); then
    cancellation_blocker="failed to observe runtime before cancellation"
    return 0
  fi
  if ! same_runtime_snapshot "$cancellation_expected_runtime" "$cancellation_observed_runtime"; then
    cancellation_blocker="runtime differs from the activation baseline; cancellation is unsafe"
    return 0
  fi
  cancellation_expected_boot=$(jq -c '.bootInstances.beforeApply' <<< "$receipt")
  if ! cancellation_observed_boot=$(boot_instance); then
    cancellation_blocker="failed to observe boot instance before cancellation"
    return 0
  fi
  if ! same_boot_instance "$cancellation_expected_boot" "$cancellation_observed_boot"; then
    cancellation_blocker="boot instance differs from the activation baseline; cancellation is unsafe"
    return 0
  fi
  set +e
  target_has_profile_generation "$target"
  generation_status=$?
  set -e
  case $generation_status in
    0) cancellation_blocker="the target has a residual system profile generation; cancellation is unsafe" ;;
    1) ;;
    *) cancellation_blocker="the system profile generation directory is invalid; cancellation is unsafe" ;;
  esac
}

reconcile_interrupted_activation() {
  local direction=$1 receipt transaction_id target baseline attempt number attempt_id attempt_root
  local partial_log partial_mode truncation_marker observed_runtime observed_boot boundary generation_status
  local timestamp log_metadata outcome_json outcome_metadata state failure_stage
  local final_log outcome_file durable_outcome exit_code capture_exit_code truncated finished_at
  local attempt_status activation_status effect action current_runtime current_boot before_boot

  receipt=$(receipt_read) || die 1 "failed to read interrupted activation receipt"
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")
  if [[ $direction == forward ]]; then
    attempt=$(jq -c '.activation.attempts[-1]' <<< "$receipt")
    target=$(jq -r '.candidate' <<< "$receipt")
    baseline=$(jq -c '.activationBaseline' <<< "$receipt")
    state=activation-indeterminate
    failure_stage=activation-indeterminate
  else
    attempt=$(jq -c '.rollback.activation.attempts[-1]' <<< "$receipt")
    target=$(jq -r '.rollback.target' <<< "$receipt")
    baseline=$(jq -c '.rollback.activationBaseline' <<< "$receipt")
    state=rollback-activation-indeterminate
    failure_stage=rollback-activation-indeterminate
  fi
  [[ $(jq -r '.status' <<< "$attempt") == running ]] || \
    die 2 "interrupted activation does not contain a running attempt"
  number=$(jq -r '.number' <<< "$attempt")
  attempt_id=$(jq -r '.attemptId' <<< "$attempt")
  attempt_root=$state_root/attempts/$transaction_id/$number-$attempt_id
  partial_log=$attempt_root/activation.log.partial
  final_log=$attempt_root/activation.log
  outcome_file=$attempt_root/outcome.json
  if [[ ( -e $final_log || -L $final_log ) && ( -e $outcome_file || -L $outcome_file ) ]]; then
    [[ ! -e $partial_log && ! -L $partial_log ]] || \
      die 2 "interrupted activation contains both partial and final logs"
    dotfiles_rebuild_validate_attempt_file "$final_log" "$EUID" 400 || \
      die 2 "interrupted activation final log is invalid"
    dotfiles_rebuild_validate_attempt_file "$outcome_file" "$EUID" 600 || \
      die 2 "interrupted activation outcome is invalid"
    durable_outcome=$(cat -- "$outcome_file") || \
      die 2 "failed to read interrupted activation outcome"
    jq -e \
      --arg transactionId "$transaction_id" \
      --argjson number "$number" \
      --arg attemptId "$attempt_id" \
      --arg store "$nix_store_dir/" '
        .schemaVersion == 1 and
        .transactionId == $transactionId and
        .number == $number and
        .attemptId == $attemptId and
        (.exitCode | type == "number" and . >= 0 and . <= 255 and floor == .) and
        (.captureExitCode | type == "number" and . >= 0 and . <= 255 and floor == .) and
        (.truncated | type == "boolean") and
        (.boundary | IN("before-profile-commit", "after-profile-commit", "unknown")) and
        ([.observedRuntime.current, .observedRuntime.booted, .observedRuntime.profile] |
          all(type == "string" and startswith($store))) and
        (.observedBootInstance.kernelBootId | type == "string" and
          test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.observedBootInstance.userspaceTimestampMonotonic | type == "string" and
          test("^[1-9][0-9]*$")) and
        (.finishedAt | type == "string" and length > 0)
      ' <<< "$durable_outcome" > /dev/null || \
      die 2 "interrupted activation outcome does not match its receipt"
    exit_code=$(jq -r '.exitCode' <<< "$durable_outcome")
    capture_exit_code=$(jq -r '.captureExitCode' <<< "$durable_outcome")
    truncated=$(jq -r '.truncated' <<< "$durable_outcome")
    boundary=$(jq -r '.boundary' <<< "$durable_outcome")
    finished_at=$(jq -r '.finishedAt' <<< "$durable_outcome")
    observed_runtime=$(jq -c '.observedRuntime' <<< "$durable_outcome")
    observed_boot=$(jq -c '.observedBootInstance' <<< "$durable_outcome")
    current_runtime=$(runtime_snapshot) || \
      die 2 "failed to observe runtime while restoring activation outcome"
    current_boot=$(boot_instance) || \
      die 2 "failed to observe boot instance while restoring activation outcome"
    if ! same_runtime_snapshot "$observed_runtime" "$current_runtime" ||
      ! same_boot_instance "$observed_boot" "$current_boot"; then
      die 2 "durable activation outcome no longer matches current runtime"
    fi
    action=$(jq -r '.action' <<< "$attempt")
    before_boot=$(jq -c '.bootBaseline' <<< "$attempt")
    if ! activation_outcome_snapshot_is_valid \
      "$action" "$target" "$baseline" "$observed_runtime" "$boundary" "$exit_code" ||
      ! same_boot_instance "$before_boot" "$observed_boot"; then
      die 2 "durable activation outcome contradicts its activation boundary"
    fi
    log_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
      "$state_root" "$final_log" "$EUID" 400) || \
      die 1 "failed to bind interrupted activation final log"
    outcome_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
      "$state_root" "$outcome_file" "$EUID" 600) || \
      die 1 "failed to bind interrupted activation outcome"
    timestamp=$(now)
    if [[ $exit_code -eq 0 ]]; then
      attempt_status=succeeded
      activation_status=succeeded
      failure_stage=
      if [[ $direction == forward ]]; then
        effect=$(jq -r '.effect' <<< "$receipt")
        [[ $effect == switch ]] && state=verifying || state=restart-pending
      else
        effect=$(jq -r '.rollback.effect' <<< "$receipt")
        [[ $effect == switch ]] && state=rollback-verifying || state=rollback-restart-pending
      fi
    else
      attempt_status=failed
      activation_status=failed
      if [[ $direction == forward ]]; then
        state=activation-failed
        failure_stage=activation
      else
        state=rollback-activation-failed
        failure_stage=rollback-activation
      fi
    fi
    if [[ $direction == forward ]]; then
      receipt_update \
        --arg state "$state" \
        --arg activationStatus "$activation_status" \
        --arg attemptStatus "$attempt_status" \
        --arg failureStage "$failure_stage" \
        --arg timestamp "$timestamp" \
        --arg finishedAt "$finished_at" \
        --arg attemptId "$attempt_id" \
        --arg boundary "$boundary" \
        --argjson log "$log_metadata" \
        --argjson outcome "$outcome_metadata" \
        --argjson truncated "$truncated" \
        --argjson captureExitCode "$capture_exit_code" \
        --argjson exitCode "$exit_code" '
          .state = $state |
          .activation.status = $activationStatus |
          .activation.exitCode = $exitCode |
          (.activation.attempts[] | select(.attemptId == $attemptId)) |= (
            .status = $attemptStatus |
            .boundary = $boundary |
            .finishedAt = $finishedAt |
            .exitCode = $exitCode |
            .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
            .outcome = $outcome
          ) |
          .failureStage = (if $failureStage == "" then null else $failureStage end) |
          .updatedAt = $timestamp
        '
    else
      receipt_update \
        --arg state "$state" \
        --arg activationStatus "$activation_status" \
        --arg attemptStatus "$attempt_status" \
        --arg failureStage "$failure_stage" \
        --arg timestamp "$timestamp" \
        --arg finishedAt "$finished_at" \
        --arg attemptId "$attempt_id" \
        --arg boundary "$boundary" \
        --argjson log "$log_metadata" \
        --argjson outcome "$outcome_metadata" \
        --argjson truncated "$truncated" \
        --argjson captureExitCode "$capture_exit_code" \
        --argjson exitCode "$exit_code" '
          .state = $state |
          .rollback.activation.status = $activationStatus |
          .rollback.activation.exitCode = $exitCode |
          (.rollback.activation.attempts[] | select(.attemptId == $attemptId)) |= (
            .status = $attemptStatus |
            .boundary = $boundary |
            .finishedAt = $finishedAt |
            .exitCode = $exitCode |
            .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
            .outcome = $outcome
          ) |
          .failureStage = (if $failureStage == "" then null else $failureStage end) |
          .updatedAt = $timestamp
        '
    fi
    receipt=$(receipt_read) || die 1 "failed to read restored activation outcome"
    verify_receipt_artifacts "$receipt" || \
      die 1 "restored activation journal is invalid"
    echo "Restored durable $direction activation outcome for attempt $number." >&2
    return 0
  fi
  if [[ -e $final_log || -L $final_log ]]; then
    [[ ! -e $outcome_file && ! -L $outcome_file &&
      ! -e $partial_log && ! -L $partial_log ]] || \
      die 2 "interrupted activation has conflicting finalized artifacts"
    dotfiles_rebuild_validate_attempt_file "$final_log" "$EUID" 400 || \
      die 2 "interrupted activation final log is invalid"
    log_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
      "$state_root" "$final_log" "$EUID" 400) || \
      die 1 "failed to bind interrupted activation final log"
  else
    [[ ! -e $outcome_file && ! -L $outcome_file ]] || \
      die 2 "interrupted activation has an outcome without a final log"
    partial_mode=$(stat -c '%a' -- "$partial_log" 2>/dev/null) || \
      die 2 "interrupted activation partial log is missing"
    if [[ $partial_mode != 600 && $partial_mode != 400 ]] ||
      ! dotfiles_rebuild_validate_attempt_file "$partial_log" "$EUID" "$partial_mode"; then
      die 2 "interrupted activation partial log is invalid"
    fi
    truncation_marker=$attempt_root/truncated.partial
    if [[ -e $truncation_marker || -L $truncation_marker ]]; then
      dotfiles_rebuild_validate_attempt_file "$truncation_marker" "$EUID" 600 || \
        die 2 "interrupted activation truncation marker is invalid"
      rm -- "$truncation_marker" || die 1 "failed to remove interrupted truncation marker"
      sync "$attempt_root" || die 1 "failed to persist interrupted truncation marker removal"
    fi
    dotfiles_rebuild_finalize_attempt_log "$attempt_root" "$EUID" "$(id -g)" || \
      die 1 "failed to finalize interrupted activation log"
    log_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
      "$state_root" "$final_log" "$EUID" 400) || \
      die 1 "failed to bind interrupted activation log"
  fi

  observed_runtime=$(runtime_snapshot) || \
    die 2 "failed to observe runtime after interrupted activation"
  observed_boot=$(boot_instance) || \
    die 2 "failed to observe boot instance after interrupted activation"
  boundary=unknown
  if same_runtime_snapshot "$baseline" "$observed_runtime" &&
    [[ $(jq -r '.profile' <<< "$baseline") != "$target" ]]; then
    set +e
    target_has_profile_generation "$target"
    generation_status=$?
    set -e
    [[ $generation_status -ne 1 ]] || boundary=before-profile-commit
  elif [[ $(jq -r '.profile' <<< "$observed_runtime") == "$target" ]]; then
    boundary=after-profile-commit
  fi

  timestamp=$(now)
  outcome_json=$(jq -cn \
    --argjson schemaVersion 1 \
    --arg transactionId "$transaction_id" \
    --argjson number "$number" \
    --arg attemptId "$attempt_id" \
    --argjson captureExitCode 255 \
    --argjson truncated true \
    --arg boundary "$boundary" \
    --argjson observedRuntime "$observed_runtime" \
    --argjson observedBootInstance "$observed_boot" \
    --arg finishedAt "$timestamp" '
      {
        schemaVersion: $schemaVersion,
        transactionId: $transactionId,
        number: $number,
        attemptId: $attemptId,
        exitCode: null,
        captureExitCode: $captureExitCode,
        truncated: $truncated,
        boundary: $boundary,
        observedRuntime: $observedRuntime,
        observedBootInstance: $observedBootInstance,
        reconciled: true,
        finishedAt: $finishedAt
      }
    ') || die 1 "failed to encode interrupted activation outcome"
  printf '%s\n' "$outcome_json" | dotfiles_rebuild_create_attempt_json \
    "$attempt_root" "$EUID" "$(id -g)" outcome.json || \
    die 1 "failed to persist interrupted activation outcome"
  outcome_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$attempt_root/outcome.json" "$EUID" 600) || \
    die 1 "failed to bind interrupted activation outcome"

  if [[ $direction == forward ]]; then
    receipt_update \
      --arg state "$state" \
      --arg failureStage "$failure_stage" \
      --arg timestamp "$timestamp" \
      --arg attemptId "$attempt_id" \
      --arg boundary "$boundary" \
      --argjson log "$log_metadata" \
      --argjson outcome "$outcome_metadata" '
        .state = $state |
        .activation.status = "indeterminate" |
        .activation.exitCode = null |
        (.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "indeterminate" |
          .boundary = $boundary |
          .finishedAt = $timestamp |
          .exitCode = null |
          .log = ($log + {truncated: true, captureExitCode: 255}) |
          .outcome = $outcome
        ) |
        .failureStage = $failureStage |
        .updatedAt = $timestamp
      '
  else
    receipt_update \
      --arg state "$state" \
      --arg failureStage "$failure_stage" \
      --arg timestamp "$timestamp" \
      --arg attemptId "$attempt_id" \
      --arg boundary "$boundary" \
      --argjson log "$log_metadata" \
      --argjson outcome "$outcome_metadata" '
        .state = $state |
        .rollback.activation.status = "indeterminate" |
        .rollback.activation.exitCode = null |
        (.rollback.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "indeterminate" |
          .boundary = $boundary |
          .finishedAt = $timestamp |
          .exitCode = null |
          .log = ($log + {truncated: true, captureExitCode: 255}) |
          .outcome = $outcome
        ) |
        .failureStage = $failureStage |
        .updatedAt = $timestamp
      '
  fi
  receipt=$(receipt_read) || die 1 "failed to read reconciled activation receipt"
  verify_receipt_artifacts "$receipt" || \
    die 1 "reconciled activation journal is invalid"
  echo "Reconciled interrupted $direction activation attempt $number as $boundary." >&2
}

audit_schema2_for_cancellation() {
  local receipt=$1 source helper helper_resolved invocation
  [[ $(jq -r '.schemaVersion' <<< "$receipt") -eq 2 ]] || \
    die 2 "cancellation audit requires a schema 2 receipt"
  [[ $(jq -r '.state' <<< "$receipt") == activation-failed &&
    $(jq -r '.rollback == null' <<< "$receipt") == true &&
    $(jq -r '.sopsEnrollmentTransactionId // empty' <<< "$receipt") == "" ]] || \
    die 2 "schema 2 receipt is outside the audited cancellation migration"
  source=$(jq -r '.source' <<< "$receipt")
  helper=$(jq -r '.helperPath' <<< "$receipt")
  [[ -f $source/modules/commands/rebuild && ! -L $source/modules/commands/rebuild &&
    -f $source/flake.lock && ! -L $source/flake.lock && -L $helper ]] || \
    die 2 "schema 2 receipt lacks its audited source or helper"
  helper_resolved=$(readlink -f -- "$helper") || \
    die 2 "schema 2 helper cannot be resolved"
  [[ $helper_resolved == "$nix_store_dir/"* && -f $helper_resolved &&
    ! -L $helper_resolved ]] || \
    die 2 "schema 2 helper does not resolve to a Nix store file"
  schema2_source_hash=$(sha256sum "$source/modules/commands/rebuild" | cut -d ' ' -f 1)
  schema2_helper_hash=$(sha256sum "$helper_resolved" | cut -d ' ' -f 1)
  schema2_nixpkgs_rev=$(jq -er '.nodes.nixpkgs.locked.rev | select(type == "string")' "$source/flake.lock") || \
    die 2 "schema 2 source lacks its pinned nixpkgs revision"
  [[ $schema2_source_hash == "$legacy_schema2_rebuild_source_sha256" &&
    $schema2_helper_hash == "$legacy_schema2_candidate_helper_sha256" &&
    $schema2_nixpkgs_rev == "$legacy_schema2_nixpkgs_rev" ]] || \
    die 2 "schema 2 receipt does not match the audited historical driver"
  invocation="$legacy_schema2_nixos_rebuild_path \"\$action\" --sudo --no-reexec --store-path \"\$target\" -L"
  grep -Fqx -- "  $invocation" "$helper_resolved" || \
    die 2 "schema 2 helper does not use the audited activation invocation"
}

cancel_audited_schema2_transaction() {
  local receipt=$1 transaction_id=$2 state=$3 expected_runtime observed_runtime
  local expected_boot observed_boot receipt_sha migration_file migration_metadata timestamp

  receipt_sha=$(sha256sum "$active_receipt" | cut -d ' ' -f 1) || \
    die 1 "failed to fingerprint schema 2 receipt before cancellation"
  audit_schema2_for_cancellation "$receipt"
  evaluate_cancellation "$receipt" 1
  [[ -z $cancellation_blocker ]] || die 2 "$cancellation_blocker"
  expected_runtime=$cancellation_expected_runtime
  observed_runtime=$cancellation_observed_runtime
  expected_boot=$cancellation_expected_boot
  observed_boot=$cancellation_observed_boot

  migration_file=$(dotfiles_rebuild_preserve_schema2_receipt \
    "$state_root" "$EUID" "$(id -g)" "$transaction_id" "$active_receipt") || \
    die 1 "failed to preserve schema 2 receipt before migration"
  migration_metadata=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$migration_file" "$EUID" 400) || \
    die 1 "failed to bind preserved schema 2 receipt"
  [[ $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$receipt_sha" ]] || \
    die 2 "schema 2 receipt changed during cancellation audit"
  receipt=$(receipt_read) || die 1 "failed to re-read schema 2 receipt before cancellation"
  audit_schema2_for_cancellation "$receipt"
  evaluate_cancellation "$receipt" 1
  [[ -z $cancellation_blocker ]] || die 2 "$cancellation_blocker"
  expected_runtime=$cancellation_expected_runtime
  observed_runtime=$cancellation_observed_runtime
  expected_boot=$cancellation_expected_boot
  observed_boot=$cancellation_observed_boot

  timestamp=$(now)
  receipt_update \
    --arg driverExecutable "$legacy_schema2_nixos_rebuild_path" \
    --arg sourceTemplateSha256 "$schema2_source_hash" \
    --arg candidateHelperSha256 "$schema2_helper_hash" \
    --arg nixpkgsRev "$schema2_nixpkgs_rev" \
    --arg fromState "$state" \
    --argjson expectedRuntime "$expected_runtime" \
    --argjson observedRuntime "$observed_runtime" \
    --argjson expectedBootInstance "$expected_boot" \
    --argjson observedBootInstance "$observed_boot" \
    --arg timestamp "$timestamp" \
    --argjson migrationReceipt "$migration_metadata" '
      .schemaVersion = 3 |
      .activationDriver = {
        protocol: "nixos-rebuild-ng-profile-before-activation-v1",
        executable: $driverExecutable
      } |
      .activation.attempts = [] |
      .state = "cancelled" |
      .cancellation = {
        kind: "manual-zero-effect",
        fromState: $fromState,
        boundary: "before-profile-commit",
        driverContract: "nixos-rebuild-ng-profile-before-activation-v1",
        expectedRuntime: $expectedRuntime,
        observedRuntime: $observedRuntime,
        expectedBootInstance: $expectedBootInstance,
        observedBootInstance: $observedBootInstance,
        requestedAt: $timestamp
      } |
      .migration = {
        fromSchema: 2,
        classification: "before-profile-commit",
        receipt: $migrationReceipt,
        sourceTemplateSha256: $sourceTemplateSha256,
        candidateHelperSha256: $candidateHelperSha256,
        nixpkgsRev: $nixpkgsRev,
        driverContract: "nixos-rebuild-ng-profile-before-activation-v1",
        driverExecutable: $driverExecutable,
        migratedAt: $timestamp
      } |
      .failureStage = null |
      .updatedAt = $timestamp |
      .finishedAt = $timestamp
    '
}

cancel_transaction() {
  local receipt schema state transaction_id expected_runtime observed_runtime
  local expected_boot observed_boot timestamp
  receipt=$(receipt_read) || die 1 "failed to read rebuild transaction for cancellation"
  schema=$(jq -r '.schemaVersion' <<< "$receipt")
  state=$(jq -r '.state' <<< "$receipt")
  transaction_id=$(jq -r '.transactionId' <<< "$receipt")

  if [[ $state == cancelled ]]; then
    dotfiles_rebuild_archive_active_receipt \
      "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$transaction_id" || \
      die 1 "failed to archive cancelled rebuild receipt"
    dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
      die 1 "failed to remove cancelled rebuild GC roots"
    printf 'Rebuild transaction %s: cancelled\n' "$transaction_id"
    return 0
  fi

  if [[ $schema -eq 2 ]]; then
    cancel_audited_schema2_transaction "$receipt" "$transaction_id" "$state"
  else
    evaluate_cancellation "$receipt"
    [[ -z $cancellation_blocker ]] || die 2 "$cancellation_blocker"
    expected_runtime=$cancellation_expected_runtime
    observed_runtime=$cancellation_observed_runtime
    expected_boot=$cancellation_expected_boot
    observed_boot=$cancellation_observed_boot

    timestamp=$(now)
    receipt_update \
      --arg fromState "$state" \
      --argjson expectedRuntime "$expected_runtime" \
      --argjson observedRuntime "$observed_runtime" \
      --argjson expectedBootInstance "$expected_boot" \
      --argjson observedBootInstance "$observed_boot" \
      --arg timestamp "$timestamp" '
        .state = "cancelled" |
        .cancellation = {
          kind: "manual-zero-effect",
          fromState: $fromState,
          boundary: "before-profile-commit",
          driverContract: "nixos-rebuild-ng-profile-before-activation-v1",
          expectedRuntime: $expectedRuntime,
          observedRuntime: $observedRuntime,
          expectedBootInstance: $expectedBootInstance,
          observedBootInstance: $observedBootInstance,
          requestedAt: $timestamp
        } |
        .failureStage = null |
        .updatedAt = $timestamp |
        .finishedAt = $timestamp
      '
  fi
  dotfiles_rebuild_archive_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$transaction_id" || \
    die 1 "failed to archive cancelled rebuild receipt"
  dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
    die 1 "failed to remove cancelled rebuild GC roots"
  printf 'Rebuild transaction %s: cancelled\n' "$transaction_id"
}

verification_failed() {
  local direction=$1 stage=$2 exit_code=$3 message=$4
  local failed_check_ids=${5:-'[]'} state timestamp
  timestamp=$(now)
  if [[ $direction == forward ]]; then
    state=verification-failed
  else
    state=rollback-verification-failed
  fi
  receipt_update \
    --arg state "$state" \
    --arg stage "$stage" \
    --arg timestamp "$timestamp" \
    --argjson exitCode "$exit_code" \
    --argjson failedCheckIds "$failed_check_ids" '
      .state = $state |
      .verification = {
        status: "failed",
        exitCode: $exitCode,
        failedCheckIds: $failedCheckIds
      } |
      .failureStage = $stage |
      .updatedAt = $timestamp
    '
  echo "FATAL: $message" >&2
  if [[ $stage == generation || $stage == cold-start || $stage == user ]]; then
    receipt=$(receipt_read)
    if [[ $direction == forward ]]; then
      retry_effect=$(jq -r '.effect' <<< "$receipt")
    else
      retry_effect=$(jq -r '.rollback.effect' <<< "$receipt")
    fi
    print_restart_instructions "$direction" "$retry_effect" >&2
  fi
  print_recovery
  if [[ $stage == doctor ]]; then
    return 5
  fi
  return 2
}

read_doctor_manifest_schema() {
  local target=$1 manifest canonical
  manifest=$target/etc/dotfiles/doctor.json
  canonical=$(readlink -e -- "$manifest" 2>/dev/null) || return 1
  [[ $canonical == "$nix_store_dir/"* && -r $canonical ]] || return 1
  jq -ers '
    if length == 1 and (.[0] | type) == "object" and
      (.[0].schemaVersion | type) == "number" and
      .[0].schemaVersion > 0 and
      (.[0].schemaVersion | floor) == .[0].schemaVersion
    then .[0].schemaVersion
    else error("invalid doctor manifest schema")
    end
  ' "$canonical" 2>/dev/null
}

# forward は宣言中の schema だけを受ける。rollback は過去 generation の
# manifest を読むので、legacy の 2 と、json 化した 3 以降を受ける
doctor_manifest_route() {
  local direction=$1 target=$2 schema
  schema=$(read_doctor_manifest_schema "$target") || return 1
  if [[ $direction == forward ]]; then
    [[ $schema -eq $doctor_schema_version ]] || return 1
    printf '%s|json\n' "$schema"
    return 0
  fi
  if [[ $schema -eq $legacy_doctor_schema_version ]]; then
    printf '%s|legacy\n' "$schema"
    return 0
  fi
  if [[ $schema -gt $legacy_doctor_schema_version && $schema -le $doctor_schema_version ]]; then
    printf '%s|json\n' "$schema"
    return 0
  fi
  return 1
}

read_oci_image_manifest_schema() {
  local target=$1 manifest canonical
  manifest=$target/etc/dotfiles/oci-images.json
  canonical=$(readlink -e -- "$manifest" 2>/dev/null) || return 1
  [[ $canonical == "$nix_store_dir/"* && -r $canonical ]] || return 1
  jq -ers '
    if length == 1 and (.[0] | type) == "object" and
      (.[0].schemaVersion | type) == "number" and
      .[0].schemaVersion > 0 and
      (.[0].schemaVersion | floor) == .[0].schemaVersion
    then .[0].schemaVersion
    else error("invalid OCI image manifest schema")
    end
  ' "$canonical" 2>/dev/null
}

resolve_store_executable() {
  local executable=$1 canonical
  canonical=$(readlink -e -- "$executable" 2>/dev/null) || return 1
  [[ $canonical == "$nix_store_dir/"* && -f $canonical && ! -L $canonical &&
    -x $canonical ]] || return 1
  printf '%s\n' "$canonical"
}

resolve_receipt_execution_helper() {
  local receipt=$1 role=$2 metadata candidate canonical
  candidate=$(jq -er '.candidate' <<< "$receipt") || return 1
  metadata=$(jq -c --arg role "$role" '.lineage.execution.helpers[$role]' \
    <<< "$receipt") || return 1
  dotfiles_rebuild_validate_successor_helper \
    "$metadata" "$candidate" "$role" "$nix_store_dir" || return 1
  canonical=$(jq -er '.canonicalPath' <<< "$metadata") || return 1
  printf '%s\n' "$canonical"
}

require_target_oci_capability() {
  local target=$1 role=$2 helper
  [[ $(read_oci_image_manifest_schema "$target" 2>/dev/null || true) == 2 ]] || \
    die 2 "$role target requires OCI image manifest schema version 2"
  helper=$target/sw/bin/dotfiles-sync-images
  helper=$(resolve_store_executable "$helper") || \
    die 2 "$role target does not contain an executable OCI image sync helper: $helper"
}

require_target_oci_readiness() {
  local target=$1 role=$2 helper status
  require_target_oci_capability "$target" "$role"
  helper=$(resolve_store_executable "$target/sw/bin/dotfiles-sync-images") || \
    die 2 "$role target does not contain an executable OCI image sync helper"

  echo "==> OCI image readiness"
  set +e
  "$helper" --status
  status=$?
  set -e
  case $status in
    0)
      return 0
      ;;
    1)
      echo "FATAL: OCI images for target are not synchronized: $target" >&2
      echo "Run: $helper" >&2
      return 1
      ;;
    *)
      echo "FATAL: target OCI readiness check is invalid (status $status): $helper" >&2
      return 2
      ;;
  esac
}

validate_forward_recovery_parent() {
  local receipt=$1 observed_runtime observed_current observed_profile observed_booted
  local parent_candidate observed_effect expected_distro

  if [[ $(jq -r '.sopsEnrollmentTransactionId != null' <<< "$receipt") == true ]]; then
    die 2 "SOPS enrollment-bound transaction cannot be forward-recovered"
  fi
  [[ ! -e $active_enrollment && ! -L $active_enrollment ]] || \
    die 2 "an active SOPS enrollment transaction blocks forward recovery"
  jq -e '
    (.schemaVersion | IN(3, 4)) and
    .state == "verification-failed" and
    .activation.status == "succeeded" and
    .activation.exitCode == 0 and
    (.activation.attempts | length) > 0 and
    .activation.attempts[-1].status == "succeeded" and
    .activation.attempts[-1].boundary == "after-profile-commit" and
    .verification.status == "failed" and
    .failureStage == "doctor" and
    .rollback == null and .abort == null and .cancellation == null
  ' <<< "$receipt" >/dev/null || \
    die 2 "only an applied schema 3 or 4 doctor verification failure can be forward-recovered"

  expected_distro=$(jq -r '.distro' <<< "$receipt")
  [[ -n ${WSL_DISTRO_NAME:-} && $WSL_DISTRO_NAME == "$expected_distro" ]] || \
    die 2 "forward recovery must run in the parent transaction WSL distribution"
  observed_runtime=$(runtime_snapshot) || \
    die 2 "failed to resolve runtime generation for forward recovery"
  parent_candidate=$(jq -r '.candidate' <<< "$receipt")
  observed_current=$(jq -r '.current' <<< "$observed_runtime")
  observed_profile=$(jq -r '.profile' <<< "$observed_runtime")
  observed_booted=$(jq -r '.booted' <<< "$observed_runtime")
  [[ $observed_current == "$parent_candidate" && $observed_profile == "$parent_candidate" ]] || \
    die 2 "forward recovery requires the parent candidate as current and profile generation"
  observed_effect=$(dotfiles-wsl-restart-required \
    --plan --booted-system "$observed_booted" --current-system "$observed_current" \
    "$parent_candidate") || \
    die 2 "failed to verify parent candidate cold-start state"
  [[ $observed_effect == switch ]] || \
    die 2 "forward recovery requires a converged parent candidate cold-start state"
}

reconcile_lineage_handoff() {
  local child child_id parent_id parent_metadata parent_file parent superseded timestamp
  local authorization erasure_file parent_archive
  child=$(receipt_read) || die 1 "failed to read successor rebuild receipt"
  [[ $(jq -r '.lineage != null' <<< "$child") == true ]] || return 0
  verify_receipt_artifacts "$child" || die 2 "successor rebuild lineage is invalid"
  child_id=$(jq -r '.transactionId' <<< "$child")
  parent_id=$(jq -r '.lineage.parentTransactionId' <<< "$child")
  erasure_file=$state_root/successor-erasures/$parent_id-$child_id.json
  parent_archive=$state_root/receipts/$parent_id.json
  if [[ ! -e $parent_archive && ! -L $parent_archive ]]; then
    if [[ ! -e $erasure_file && ! -L $erasure_file ]]; then
      authorization=$(dotfiles_rebuild_read_successor_authorization_v2 \
        "$state_root" "$parent_id" "$active_receipt" consumed "$EUID" "$(id -g)" \
        "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user") || \
        die 2 "consumed forward recovery authorization is invalid"
      [[ $(jq -r '.child.transactionId' <<< "$authorization") == "$child_id" ]] || \
        die 2 "consumed forward recovery authorization does not match active successor"
    fi
    dotfiles_rebuild_cleanup_successor_v2 \
      "$state_root" "$parent_id" "$child_id" consumed-handoff 1 begin "$active_receipt" \
      "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
      "$configured_user" || die 2 "consumed forward recovery erasure is invalid"
  fi
  sync --data "$active_receipt" || die 1 "failed to persist successor active receipt"
  sync "$state_root" || die 1 "failed to persist successor receipt handoff"
  parent_metadata=$(jq -c '.lineage.parentReceipt' <<< "$child")
  parent_file=$state_root/$(jq -r '.path' <<< "$parent_metadata")
  parent=$(cat -- "$parent_file") || die 1 "failed to read preserved parent rebuild receipt"
  timestamp=$(jq -r '.lineage.createdAt' <<< "$child")
  superseded=$(jq -c \
    --arg successorTransactionId "$(jq -r '.transactionId' <<< "$child")" \
    --arg successorSource "$(jq -r '.source' <<< "$child")" \
    --arg successorCandidate "$(jq -r '.candidate' <<< "$child")" \
    --argjson originalReceipt "$parent_metadata" \
    --arg timestamp "$timestamp" '
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
    ' <<< "$parent") || die 1 "failed to encode superseded parent rebuild receipt"
  dotfiles_rebuild_verify_receipt_lineage \
    "$state_root" "$superseded" "$EUID" "$(id -g)" "$dotfiles" \
    "$nix_store_dir" "$configured_user" || \
    die 2 "superseded parent rebuild receipt does not bind its actual successor"
  printf '%s\n' "$superseded" | dotfiles_rebuild_publish_archived_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" \
    "$parent_id" "$child_id" || \
    die 1 "failed to publish superseded parent rebuild receipt"
  dotfiles_rebuild_verify_receipt_lineage \
    "$state_root" "$superseded" "$EUID" "$(id -g)" "$dotfiles" \
    "$nix_store_dir" "$configured_user" || \
    die 2 "superseded parent rebuild receipt does not match its preserved artifact"
  if [[ -e $erasure_file || -L $erasure_file ]]; then
    dotfiles_rebuild_cleanup_successor_v2 \
      "$state_root" "$parent_id" "$child_id" consumed-handoff 1 finish "$active_receipt" \
      "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
      "$configured_user" || die 1 "failed to finish consumed forward recovery erasure"
  fi
  dotfiles_rebuild_remove_gc_roots "$state_root" "$parent_id" || \
    die 1 "failed to remove superseded parent rebuild GC roots"
}

observe_first_boot() {
  local direction=$1 target=$2 expected_user=$3 receipt state effect
  local before_boot current_boot current profile booted timestamp next_state
  receipt=$(receipt_read) || die 1 "failed to read the active rebuild receipt"
  state=$(jq -r '.state' <<< "$receipt")
  if [[ $direction == forward ]]; then
    effect=$(jq -r '.effect' <<< "$receipt")
    before_boot=$(jq -c '.bootInstances.beforeApply' <<< "$receipt")
    next_state=first-boot-observed
    [[ $state == restart-pending ]] || die 2 "first boot cannot be recorded from state $state"
  else
    effect=$(jq -r '.rollback.effect' <<< "$receipt")
    before_boot=$(jq -c '.rollback.bootInstances.beforeApply' <<< "$receipt")
    next_state=rollback-first-boot-observed
    [[ $state == rollback-restart-pending ]] || die 2 "rollback first boot cannot be recorded from state $state"
  fi
  [[ $effect == boot-two-stage ]] || die 2 "first boot is only valid for a two-stage WSL transition"
  [[ ${WSL_DISTRO_NAME:-} == "$(jq -r '.distro' <<< "$receipt")" ]] || \
    die 2 "first boot is running in the wrong WSL distribution"
  [[ $(id -un) == "$expected_user" ]] || \
    die 2 "first boot observer must run as $expected_user"

  current=$(readlink -f -- /run/current-system 2>/dev/null || true)
  profile=$(readlink -f -- "$system_profile_path" 2>/dev/null || true)
  booted=$(readlink -f -- /run/booted-system 2>/dev/null || true)
  [[ $current == "$target" && $profile == "$target" && $booted == "$target" ]] || \
    die 3 "the first boot has not converged current/profile/booted to $target"
  current_boot=$(boot_instance) || die 2 "failed to identify the first systemd manager instance"
  if same_boot_instance "$current_boot" "$before_boot"; then
    die 3 "the first WSL restart has not created a new systemd manager instance"
  fi

  timestamp=$(now)
  if [[ $direction == forward ]]; then
    receipt_update \
      --arg state "$next_state" \
      --argjson boot "$current_boot" \
      --arg timestamp "$timestamp" '
        .state = $state |
        .bootInstances.firstBoot = $boot |
        .updatedAt = $timestamp
      '
  else
    receipt_update \
      --arg state "$next_state" \
      --argjson boot "$current_boot" \
      --arg timestamp "$timestamp" '
        .state = $state |
        .rollback.bootInstances.firstBoot = $boot |
        .updatedAt = $timestamp
      '
  fi
  echo "First boot instance recorded: $current_boot"
  echo "Terminate this distribution once more, then run the receipt's --resume command."
  return 3
}

restart_wait() {
  local direction=$1 effect=$2 message=$3 receipt state timestamp
  receipt=$(receipt_read) || die 1 "failed to read restart-pending receipt"
  if [[ $direction == forward ]]; then
    if [[ $effect == boot-two-stage ]] && jq -e '.bootInstances.firstBoot != null' <<< "$receipt" >/dev/null; then
      state=first-boot-observed
    else
      state=restart-pending
    fi
  elif [[ $effect == boot-two-stage ]] && jq -e '.rollback.bootInstances.firstBoot != null' <<< "$receipt" >/dev/null; then
    state=rollback-first-boot-observed
  else
    state=rollback-restart-pending
  fi
  timestamp=$(now)
  receipt_update \
    --arg state "$state" \
    --arg timestamp "$timestamp" '
      .state = $state |
      .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
      .failureStage = null |
      .updatedAt = $timestamp
    '
  echo "PENDING: $message" >&2
  print_restart_instructions "$direction" "$effect" >&2
  return 3
}

verify_target() {
  local direction=$1 target=$2 expected_user=$3 target_effect=$4 state timestamp receipt expected_distro
  local actual_current actual_profile actual_booted observed_effect doctor_status=0
  local doctor_report doctor_report_json='' doctor_failed_check_ids='[]'
  local doctor_manifest_schema doctor_protocol doctor_route doctor_helper
  local before_boot first_boot current_boot

  receipt=$(receipt_read) || die 1 "failed to read verification receipt"
  expected_distro=$(jq -r '.distro' <<< "$receipt")
  [[ ${WSL_DISTRO_NAME:-} == "$expected_distro" ]] || \
    verification_failed "$direction" distro 20 "resume is running in ${WSL_DISTRO_NAME:-<none>}, expected $expected_distro"

  actual_current=$(readlink -f -- /run/current-system 2>/dev/null || true)
  actual_profile=$(readlink -f -- "$system_profile_path" 2>/dev/null || true)
  actual_booted=$(readlink -f -- /run/booted-system 2>/dev/null || true)
  if [[ $actual_current != "$target" || $actual_profile != "$target" ]]; then
    if [[ $target_effect != switch ]]; then
      restart_wait "$direction" "$target_effect" "current/profile generation has not converged to $target"
    fi
    verification_failed "$direction" generation 21 "current/profile generation has not converged to $target"
  fi
  if [[ $(id -un) != "$expected_user" ]]; then
    if [[ $target_effect != switch ]]; then
      restart_wait "$direction" "$target_effect" "WSL default user has not converged to $expected_user"
    fi
    verification_failed "$direction" user 22 "resume is running as $(id -un), expected $expected_user"
  fi

  if [[ $target_effect != switch ]]; then
    [[ $actual_booted == "$target" ]] || \
      restart_wait "$direction" "$target_effect" "booted generation has not converged to $target"
    current_boot=$(boot_instance) || \
      verification_failed "$direction" boot-instance 26 "failed to identify the resumed systemd manager instance"
    if [[ $direction == forward ]]; then
      before_boot=$(jq -c '.bootInstances.beforeApply' <<< "$receipt")
      first_boot=$(jq -c '.bootInstances.firstBoot // empty' <<< "$receipt")
    else
      before_boot=$(jq -c '.rollback.bootInstances.beforeApply' <<< "$receipt")
      first_boot=$(jq -c '.rollback.bootInstances.firstBoot // empty' <<< "$receipt")
    fi
    if same_boot_instance "$current_boot" "$before_boot"; then
      restart_wait "$direction" "$target_effect" "WSL has not started a new systemd manager instance"
    fi
    if [[ $target_effect == boot-two-stage ]]; then
      [[ -n $first_boot ]] || \
        restart_wait "$direction" "$target_effect" "the first WSL boot has not been recorded"
      if same_boot_instance "$current_boot" "$first_boot"; then
        restart_wait "$direction" "$target_effect" "the second WSL boot has not been observed"
      fi
    fi
  fi

  if ! observed_effect=$(dotfiles-wsl-restart-required \
    --plan --booted-system "$actual_booted" --current-system "$actual_current" "$target"); then
    verification_failed "$direction" cold-start 23 "failed to classify the resumed generation"
  fi
  if [[ $observed_effect != switch ]]; then
    if [[ $target_effect != switch ]]; then
      restart_wait "$direction" "$target_effect" "WSL cold-start transition is incomplete: $observed_effect"
    fi
    verification_failed "$direction" cold-start 24 "WSL cold-start transition is incomplete: $observed_effect"
  fi

  if ! doctor_route=$(doctor_manifest_route "$direction" "$target"); then
    verification_failed \
      "$direction" doctor 2 "unsupported or invalid doctor manifest for $direction target $target" \
      '["doctor.manifest"]'
  fi
  IFS='|' read -r doctor_manifest_schema doctor_protocol <<< "$doctor_route"
  if [[ $direction == forward && $(jq -r '.schemaVersion' <<< "$receipt") -eq 4 ]]; then
    doctor_helper=$(resolve_receipt_execution_helper "$receipt" doctor) || \
      verification_failed \
        "$direction" doctor 2 "doctor helper differs from the successor execution contract" \
        '["doctor.executable"]'
  else
    doctor_helper=$(resolve_store_executable "$target/sw/bin/dotfiles-doctor") || \
      verification_failed \
        "$direction" doctor 2 "doctor helper is not an immutable store executable: $target" \
        '["doctor.executable"]'
  fi

  if [[ $direction == forward ]]; then
    state=verifying
  else
    state=rollback-verifying
  fi
  timestamp=$(now)
  receipt_update \
    --arg state "$state" \
    --arg timestamp "$timestamp" '
      .state = $state |
      .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
      .failureStage = null |
      .updatedAt = $timestamp
    '

  doctor_report=$(mktemp)
  set +e
  if [[ $doctor_protocol == legacy ]]; then
    "$doctor_helper" > "$doctor_report"
    doctor_status=$?
    cat -- "$doctor_report"
    case $doctor_status in
      0)
        jq -cn --arg subject "$target/sw/bin/dotfiles-doctor" '{
          schemaVersion: 1,
          manifestSchemaVersion: 2,
          outcome: "healthy",
          summary: {total: 1, pass: 1, warn: 0, fail: 0, error: 0, blocked: 0},
          checks: [{
            id: "legacy.doctor", phase: "system", status: "pass", subject: $subject,
            expected: "legacy doctor status 0", observed: "status 0",
            message: "legacy dotfiles-doctor completed successfully", durationMs: 0
          }]
        }' > "$doctor_report"
        ;;
      1)
        jq -cn --arg subject "$target/sw/bin/dotfiles-doctor" '{
          schemaVersion: 1,
          manifestSchemaVersion: 2,
          outcome: "degraded",
          summary: {total: 1, pass: 0, warn: 0, fail: 1, error: 0, blocked: 0},
          checks: [{
            id: "legacy.doctor", phase: "system", status: "fail", subject: $subject,
            expected: "legacy doctor status 0", observed: "status 1",
            message: "legacy dotfiles-doctor reported drift", durationMs: 0
          }]
        }' > "$doctor_report"
        ;;
    esac
  else
    "$doctor_helper" --format json > "$doctor_report"
    doctor_status=$?
  fi
  set -e

  if doctor_report_json=$(jq -sc '
      if length == 1 then .[0] else error("doctor report must contain exactly one JSON document") end
    ' "$doctor_report" 2>/dev/null) && jq -e \
    --argjson exitCode "$doctor_status" \
    --argjson expectedManifestSchema "$doctor_manifest_schema" '
    def summary_for($checks): {
      total: ($checks | length),
      pass: ([$checks[] | select(.status == "pass")] | length),
      warn: ([$checks[] | select(.status == "warn")] | length),
      fail: ([$checks[] | select(.status == "fail")] | length),
      error: ([$checks[] | select(.status == "error")] | length),
      blocked: ([$checks[] | select(.status == "blocked")] | length)
    };

    .schemaVersion == 1 and
    .manifestSchemaVersion == $expectedManifestSchema and
    (.outcome | IN("healthy", "degraded", "invalid")) and
    (.summary | type) == "object" and
    (.summary | keys | sort) == ["blocked", "error", "fail", "pass", "total", "warn"] and
    (.checks | type) == "array" and (.checks | length) > 0 and
    ([.checks[].id] | length) == ([.checks[].id] | unique | length) and
    all(.checks[];
      (.id | type) == "string" and (.id | length) > 0 and
      (.phase | IN("foundation", "local", "system", "active")) and
      (.status | IN("pass", "warn", "fail", "error", "blocked")) and
      (.subject | type) == "string" and
      (.expected | type) == "string" and
      (.observed | type) == "string" and
      (.message | type) == "string" and (.message | length) > 0 and
      (.durationMs | type) == "number" and .durationMs >= 0 and (.durationMs | floor) == .durationMs
    ) and
    .summary == summary_for(.checks) and
    (if $exitCode == 0 then
      .outcome == "healthy" and
      all(.checks[]; .status == "pass" or .status == "warn")
    elif $exitCode == 1 then
      .outcome == "degraded" and
      any(.checks[]; .status == "fail" or .status == "blocked") and
      all(.checks[]; .status != "error")
    elif $exitCode == 2 then
      .outcome == "invalid" and
      any(.checks[]; .status == "error")
    else
      false
    end)
  ' <<< "$doctor_report_json" >/dev/null 2>&1; then
    while IFS=$'\t' read -r check_status check_message; do
      case $check_status in
        pass) printf 'OK: %s\n' "$check_message" ;;
        warn) printf 'WARN: %s\n' "$check_message" >&2 ;;
        fail) printf 'FAIL: %s\n' "$check_message" >&2 ;;
        error) printf 'ERROR: %s\n' "$check_message" >&2 ;;
        blocked) printf 'SKIP: %s\n' "$check_message" >&2 ;;
      esac
    done < <(jq -r '.checks[] | [.status, .message] | @tsv' <<< "$doctor_report_json")
    doctor_failed_check_ids=$(jq -c '
      [.checks[] | select(.status == "fail" or .status == "error") | .id] | unique
    ' <<< "$doctor_report_json")
  else
    doctor_failed_check_ids='["doctor.report"]'
    [[ $doctor_status -ne 0 ]] || doctor_status=2
    echo "ERROR: dotfiles-doctor returned an invalid JSON report" >&2
  fi
  rm -f -- "$doctor_report"
  [[ $doctor_status -eq 0 ]] || \
    verification_failed \
      "$direction" doctor "$doctor_status" "dotfiles-doctor failed for $target" \
      "$doctor_failed_check_ids"

  finish_transaction "$direction"
}

next_activation_attempt_number() {
  jq -r '
    ([.activation.attempts[]?.number, .rollback.activation.attempts[]?.number] |
      (max // 0) + 1)
  ' "$active_receipt"
}

prepare_activation_attempt() {
  local direction=$1 target=$2 action=$3 baseline=$4 state timestamp intent_json started_json
  local attempt_relative_prefix boot_baseline

  boot_baseline=$(boot_instance) || die 2 "failed to identify the activation attempt boot instance"
  activation_attempt_boot_baseline=$boot_baseline
  activation_attempt_number=$(next_activation_attempt_number) || \
    die 1 "failed to allocate an activation attempt number"
  [[ $activation_attempt_number =~ ^[1-9][0-9]*$ ]] || \
    die 1 "activation attempt number is invalid"
  activation_attempt_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ $activation_attempt_id =~ ^[0-9a-f]{32}$ ]] || \
    die 1 "failed to create an activation attempt ID"
  activation_attempt_root=$(dotfiles_rebuild_prepare_attempt_directory \
    "$state_root" "$EUID" "$(id -g)" "$(jq -r '.transactionId' "$active_receipt")" \
    "$activation_attempt_number" "$activation_attempt_id") || \
    die 1 "failed to prepare activation attempt storage"
  dotfiles_rebuild_prepare_partial_log "$activation_attempt_root" "$EUID" "$(id -g)" || \
    die 1 "failed to prepare activation attempt log"
  attempt_relative_prefix=${activation_attempt_root#"$state_root/"}
  activation_attempt_partial_log=$activation_attempt_root/activation.log.partial
  timestamp=$(now)
  intent_json=$(jq -cn \
    --argjson schemaVersion 1 \
    --arg transactionId "$(jq -r '.transactionId' "$active_receipt")" \
    --argjson number "$activation_attempt_number" \
    --arg attemptId "$activation_attempt_id" \
    --arg direction "$direction" \
    --arg target "$target" \
    --arg action "$action" \
    --arg driverProtocol "nixos-rebuild-ng-profile-before-activation-v1" \
    --arg driverExecutable "@nixosRebuildPath@" \
    --argjson activationBaseline "$baseline" \
    --argjson bootBaseline "$boot_baseline" \
    --arg createdAt "$timestamp" '
      {
        schemaVersion: $schemaVersion,
        transactionId: $transactionId,
        number: $number,
        attemptId: $attemptId,
        direction: $direction,
        target: $target,
        action: $action,
        driver: {protocol: $driverProtocol, executable: $driverExecutable},
        activationBaseline: $activationBaseline,
        bootBaseline: $bootBaseline,
        createdAt: $createdAt
      }
    ') || die 1 "failed to encode activation attempt intent"
  printf '%s\n' "$intent_json" | dotfiles_rebuild_create_attempt_json \
    "$activation_attempt_root" "$EUID" "$(id -g)" intent.json || \
    die 1 "failed to persist activation attempt intent"
  activation_attempt_intent=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$activation_attempt_root/intent.json" "$EUID" 600) || \
    die 1 "failed to bind activation attempt intent"

  if [[ $direction == forward ]]; then
    state=apply-intent
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --argjson baseline "$baseline" \
      --argjson bootBaseline "$boot_baseline" \
      --argjson number "$activation_attempt_number" \
      --arg attemptId "$activation_attempt_id" \
      --arg direction "$direction" \
      --arg target "$target" \
      --arg action "$action" \
      --arg partialLogPath "$attempt_relative_prefix/activation.log.partial" \
      --argjson intent "$activation_attempt_intent" '
        .state = $state |
        .activationBaseline = $baseline |
        .activation.status = "pending" |
        .activation.exitCode = null |
        .activation.attempts += [{
          number: $number,
          attemptId: $attemptId,
          direction: $direction,
          target: $target,
          action: $action,
          activationBaseline: $baseline,
          bootBaseline: $bootBaseline,
          status: "intent",
          boundary: null,
          createdAt: $timestamp,
          startedAt: null,
          finishedAt: null,
          exitCode: null,
          intent: $intent,
          started: null,
          partialLogPath: $partialLogPath,
          log: null,
          outcome: null
        }] |
        .failureStage = null |
        .updatedAt = $timestamp
      '
  else
    state=rollback-intent
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --argjson baseline "$baseline" \
      --argjson bootBaseline "$boot_baseline" \
      --argjson number "$activation_attempt_number" \
      --arg attemptId "$activation_attempt_id" \
      --arg direction "$direction" \
      --arg target "$target" \
      --arg action "$action" \
      --arg partialLogPath "$attempt_relative_prefix/activation.log.partial" \
      --argjson intent "$activation_attempt_intent" '
        .state = $state |
        .rollback.activationBaseline = $baseline |
        .rollback.activation.status = "pending" |
        .rollback.activation.exitCode = null |
        .rollback.activation.attempts += [{
          number: $number,
          attemptId: $attemptId,
          direction: $direction,
          target: $target,
          action: $action,
          activationBaseline: $baseline,
          bootBaseline: $bootBaseline,
          status: "intent",
          boundary: null,
          createdAt: $timestamp,
          startedAt: null,
          finishedAt: null,
          exitCode: null,
          intent: $intent,
          started: null,
          partialLogPath: $partialLogPath,
          log: null,
          outcome: null
        }] |
        .failureStage = null |
        .updatedAt = $timestamp
      '
  fi

  assert_activation_baseline "$direction" activation-handoff "$baseline"
  timestamp=$(now)
  started_json=$(jq -cn \
    --argjson schemaVersion 1 \
    --arg transactionId "$(jq -r '.transactionId' "$active_receipt")" \
    --argjson number "$activation_attempt_number" \
    --arg attemptId "$activation_attempt_id" \
    --arg runnerPid "$$" \
    --arg startedAt "$timestamp" '
      {
        schemaVersion: $schemaVersion,
        transactionId: $transactionId,
        number: $number,
        attemptId: $attemptId,
        runnerPid: $runnerPid,
        startedAt: $startedAt
      }
    ') || die 1 "failed to encode activation start marker"
  printf '%s\n' "$started_json" | dotfiles_rebuild_create_attempt_json \
    "$activation_attempt_root" "$EUID" "$(id -g)" started.json || \
    die 1 "failed to persist activation start marker"
  activation_attempt_started=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$activation_attempt_root/started.json" "$EUID" 600) || \
    die 1 "failed to bind activation start marker"
  if [[ $direction == forward ]]; then
    state=activating
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --arg attemptId "$activation_attempt_id" \
      --argjson started "$activation_attempt_started" '
        .state = $state |
        (.activation.attempts[] | select(.attemptId == $attemptId)) |=
          (.status = "running" | .started = $started | .startedAt = $timestamp) |
        .updatedAt = $timestamp
      '
  else
    state=rollback-activating
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --arg attemptId "$activation_attempt_id" \
      --argjson started "$activation_attempt_started" '
        .state = $state |
        (.rollback.activation.attempts[] | select(.attemptId == $attemptId)) |=
          (.status = "running" | .started = $started | .startedAt = $timestamp) |
        .updatedAt = $timestamp
      '
  fi
}

run_activation_attempt() {
  local direction=$1 target=$2 action=$3 baseline=$4
  local truncation_marker observed_runtime observed_boot outcome_json
  local activation_status capture_status timestamp
  local -a pipeline_status

  truncation_marker=$activation_attempt_root/truncated.partial
  if ! (umask 077; set -o noclobber; printf '%s\n' false > "$truncation_marker"); then
    die 1 "failed to prepare activation truncation marker"
  fi
  dotfiles_rebuild_validate_attempt_file "$truncation_marker" "$EUID" 600 || \
    die 1 "activation truncation marker is invalid"

  echo "==> $direction activation"
  set +e
  PATH="${sudo_command%/*}:$PATH" LC_ALL=C \
    @nixosRebuild@ "$action" --sudo --no-reexec --store-path "$target" -L 2>&1 |
    LC_ALL=C @awk@ \
      -v log_path="$activation_attempt_partial_log" \
      -v marker_path="$truncation_marker" \
      -v limit=@activationLogLimitBytes@ '
        {
          chunk = $0 ORS
          printf "%s", chunk
          fflush()
          remaining = limit - stored
          if (remaining > 0) {
            if (length(chunk) > remaining) {
              printf "%s", substr(chunk, 1, remaining) >> log_path
              stored = limit
              truncated = 1
            } else {
              printf "%s", chunk >> log_path
              stored += length(chunk)
            }
          } else {
            truncated = 1
          }
        }
        END {
          close(log_path)
          print (truncated ? "true" : "false") > marker_path
          close(marker_path)
        }
      '
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  activation_status=${pipeline_status[0]}
  capture_status=${pipeline_status[1]}
  [[ $activation_status =~ ^[0-9]+$ && $activation_status -le 255 ]] || activation_status=255
  [[ $capture_status =~ ^[0-9]+$ && $capture_status -le 255 ]] || capture_status=255
  activation_attempt_truncated=$(<"$truncation_marker")
  [[ $activation_attempt_truncated == true || $activation_attempt_truncated == false ]] || {
    activation_attempt_truncated=true
    capture_status=255
  }
  rm -f -- "$truncation_marker" || die 1 "failed to remove activation truncation marker"
  sync "$activation_attempt_root" || die 1 "failed to persist activation truncation marker removal"
  dotfiles_rebuild_finalize_attempt_log "$activation_attempt_root" "$EUID" "$(id -g)" || \
    die 1 "failed to finalize activation attempt log"
  activation_attempt_log=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$activation_attempt_root/activation.log" "$EUID" 400) || \
    die 1 "failed to bind activation attempt log"

  observed_runtime=$(runtime_snapshot) || die 1 "failed to observe runtime after activation attempt"
  observed_boot=$(boot_instance) || die 1 "failed to observe boot instance after activation attempt"
  if [[ $activation_status -eq 0 ]]; then
    activation_attempt_boundary=after-profile-commit
  elif same_runtime_snapshot "$baseline" "$observed_runtime" &&
    [[ $(jq -r '.profile' <<< "$baseline") != "$target" ]]; then
    activation_attempt_boundary=before-profile-commit
  elif [[ $(jq -r '.profile' <<< "$observed_runtime") == "$target" ]]; then
    activation_attempt_boundary=after-profile-commit
  else
    activation_attempt_boundary=unknown
  fi
  if ! same_boot_instance "$activation_attempt_boot_baseline" "$observed_boot" ||
    ! activation_outcome_snapshot_is_valid \
      "$action" "$target" "$baseline" "$observed_runtime" \
      "$activation_attempt_boundary" "$activation_status"; then
    die 2 "activation outcome contradicts its activation boundary"
  fi
  timestamp=$(now)
  outcome_json=$(jq -cn \
    --argjson schemaVersion 1 \
    --arg transactionId "$(jq -r '.transactionId' "$active_receipt")" \
    --argjson number "$activation_attempt_number" \
    --arg attemptId "$activation_attempt_id" \
    --argjson exitCode "$activation_status" \
    --argjson captureExitCode "$capture_status" \
    --argjson truncated "$activation_attempt_truncated" \
    --arg boundary "$activation_attempt_boundary" \
    --argjson observedRuntime "$observed_runtime" \
    --argjson observedBootInstance "$observed_boot" \
    --arg finishedAt "$timestamp" '
      {
        schemaVersion: $schemaVersion,
        transactionId: $transactionId,
        number: $number,
        attemptId: $attemptId,
        exitCode: $exitCode,
        captureExitCode: $captureExitCode,
        truncated: $truncated,
        boundary: $boundary,
        observedRuntime: $observedRuntime,
        observedBootInstance: $observedBootInstance,
        finishedAt: $finishedAt
      }
    ') || die 1 "failed to encode activation outcome"
  printf '%s\n' "$outcome_json" | dotfiles_rebuild_create_attempt_json \
    "$activation_attempt_root" "$EUID" "$(id -g)" outcome.json || \
    die 1 "failed to persist activation outcome"
  activation_attempt_outcome=$(dotfiles_rebuild_attempt_artifact_metadata \
    "$state_root" "$activation_attempt_root/outcome.json" "$EUID" 600) || \
    die 1 "failed to bind activation outcome"
  activation_attempt_exit_code=$activation_status
  activation_attempt_capture_exit_code=$capture_status
  activation_attempt_finished_at=$timestamp
}

activation_failed() {
  local direction=$1 exit_code=$2 state timestamp
  timestamp=$(now)
  if [[ $direction == forward ]]; then
    state=activation-failed
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --arg finishedAt "$activation_attempt_finished_at" \
      --arg attemptId "$activation_attempt_id" \
      --arg boundary "$activation_attempt_boundary" \
      --argjson log "$activation_attempt_log" \
      --argjson outcome "$activation_attempt_outcome" \
      --argjson truncated "$activation_attempt_truncated" \
      --argjson captureExitCode "$activation_attempt_capture_exit_code" \
      --argjson exitCode "$exit_code" '
        .state = $state |
        .activation.status = "failed" |
        .activation.exitCode = $exitCode |
        (.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "failed" |
          .boundary = $boundary |
          .finishedAt = $finishedAt |
          .exitCode = $exitCode |
          .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
          .outcome = $outcome
        ) |
        .failureStage = "activation" |
        .updatedAt = $timestamp
      '
  else
    state=rollback-activation-failed
    receipt_update \
      --arg state "$state" \
      --arg timestamp "$timestamp" \
      --arg finishedAt "$activation_attempt_finished_at" \
      --arg attemptId "$activation_attempt_id" \
      --arg boundary "$activation_attempt_boundary" \
      --argjson log "$activation_attempt_log" \
      --argjson outcome "$activation_attempt_outcome" \
      --argjson truncated "$activation_attempt_truncated" \
      --argjson captureExitCode "$activation_attempt_capture_exit_code" \
      --argjson exitCode "$exit_code" '
        .state = $state |
        .rollback.activation.status = "failed" |
        .rollback.activation.exitCode = $exitCode |
        (.rollback.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "failed" |
          .boundary = $boundary |
          .finishedAt = $finishedAt |
          .exitCode = $exitCode |
          .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
          .outcome = $outcome
        ) |
        .failureStage = "rollback-activation" |
        .updatedAt = $timestamp
      '
  fi
  echo "FATAL: nixos-rebuild activation failed with status $exit_code" >&2
  echo "Activation log: $state_root/$(jq -r '.path' <<< "$activation_attempt_log")" >&2
  print_recovery
  return 4
}

activate_target() {
  local direction=$1 target=$2 effect=$3 action=$4 expected_user=$5 baseline=$6
  local pending_state success_state timestamp
  assert_activation_baseline "$direction" intent-publication "$baseline"
  if [[ $direction == forward ]]; then
    pending_state=restart-pending
    success_state=verifying
  else
    pending_state=rollback-restart-pending
    success_state=rollback-verifying
  fi

  prepare_activation_attempt "$direction" "$target" "$action" "$baseline"
  run_activation_attempt "$direction" "$target" "$action" "$baseline"
  if [[ $activation_attempt_exit_code -ne 0 ]]; then
    activation_failed "$direction" "$activation_attempt_exit_code"
    return $?
  fi

  if [[ $effect != switch ]]; then
    success_state=$pending_state
  fi
  timestamp=$(now)
  if [[ $direction == forward ]]; then
    receipt_update \
      --arg state "$success_state" \
      --arg timestamp "$timestamp" \
      --arg finishedAt "$activation_attempt_finished_at" \
      --arg attemptId "$activation_attempt_id" \
      --arg boundary "$activation_attempt_boundary" \
      --argjson log "$activation_attempt_log" \
      --argjson outcome "$activation_attempt_outcome" \
      --argjson truncated "$activation_attempt_truncated" \
      --argjson captureExitCode "$activation_attempt_capture_exit_code" '
        .state = $state |
        .activation.status = "succeeded" |
        .activation.exitCode = 0 |
        (.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "succeeded" |
          .boundary = $boundary |
          .finishedAt = $finishedAt |
          .exitCode = 0 |
          .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
          .outcome = $outcome
        ) |
        .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
        .failureStage = null |
        .updatedAt = $timestamp
      '
  else
    receipt_update \
      --arg state "$success_state" \
      --arg timestamp "$timestamp" \
      --arg finishedAt "$activation_attempt_finished_at" \
      --arg attemptId "$activation_attempt_id" \
      --arg boundary "$activation_attempt_boundary" \
      --argjson log "$activation_attempt_log" \
      --argjson outcome "$activation_attempt_outcome" \
      --argjson truncated "$activation_attempt_truncated" \
      --argjson captureExitCode "$activation_attempt_capture_exit_code" '
        .state = $state |
        .rollback.activation.status = "succeeded" |
        .rollback.activation.exitCode = 0 |
        (.rollback.activation.attempts[] | select(.attemptId == $attemptId)) |= (
          .status = "succeeded" |
          .boundary = $boundary |
          .finishedAt = $finishedAt |
          .exitCode = 0 |
          .log = ($log + {truncated: $truncated, captureExitCode: $captureExitCode}) |
          .outcome = $outcome
        ) |
        .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
        .failureStage = null |
        .updatedAt = $timestamp
      '
  fi

  if [[ $effect == switch ]]; then
    verify_target "$direction" "$target" "$expected_user" "$effect"
  else
    print_restart_instructions "$direction" "$effect"
    return 3
  fi
}

resume_activation() {
  local direction=$1 target=$2 effect=$3 action=$4 expected_user=$5
  local baseline persisted_baseline
  baseline=$(runtime_snapshot) || die 2 "failed to resolve runtime generation before resuming activation"

  if [[ $direction == forward ]]; then
    persisted_baseline=$(jq -c '.activationBaseline' "$active_receipt")
  else
    persisted_baseline=$(jq -c '.rollback.activationBaseline' "$active_receipt")
  fi
  activation_snapshot_is_owned "$action" "$target" "$persisted_baseline" "$baseline" ||
    abort_runtime_drift "$direction" activation-handoff "$persisted_baseline" "$baseline"
  activate_target "$direction" "$target" "$effect" "$action" "$expected_user" "$baseline"
}

successor_edge_for_parent() {
  local directory=$1 parent_id=$2 entry found=
  [[ -d $directory && ! -L $directory ]] || return 3
  for entry in "$directory"/"$parent_id"-*.json; do
    [[ -e $entry || -L $entry ]] || continue
    [[ -z $found ]] || return 2
    found=$entry
  done
  [[ -n $found ]] || return 3
  printf '%s\n' "$found"
}

cancel_forward_recovery() {
  local parent_id=$1 parent_sha edge child_id reason=cancel-requested
  parent_sha=$(sha256sum "$active_receipt" | cut -d ' ' -f 1) || \
    die 1 "failed to fingerprint forward recovery parent before cancellation"
  edge=
  if edge=$(successor_edge_for_parent "$state_root/successor-erasures" "$parent_id"); then
    child_id=${edge##*/}
    child_id=${child_id#"$parent_id-"}
    child_id=${child_id%.json}
    reason=$(jq -er '.reason' "$edge") || \
      die 2 "forward recovery erasure reason is invalid"
    [[ $reason == cancel-requested || $reason == discard-partial ]] || \
      die 2 "active-child handoff erasure cannot be cancelled by the parent"
  elif edge=$(successor_edge_for_parent "$state_root/successor-preparations" "$parent_id"); then
    child_id=${edge##*/}
    child_id=${child_id#"$parent_id-"}
    child_id=${child_id%.json}
  else
    die 2 "there is no prepared forward recovery to cancel"
  fi
  dotfiles_rebuild_cleanup_successor_v2 \
    "$state_root" "$parent_id" "$child_id" "$reason" 0 run "$active_receipt" \
    "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
    "$configured_user" || die 2 "forward recovery erasure state is invalid"
  dotfiles_rebuild_cleanup_successor_v2 \
    "$state_root" "$parent_id" "$child_id" "$reason" 0 retire "$active_receipt" \
    "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
    "$configured_user" || die 2 "cancelled forward recovery erasure is invalid"
  [[ $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$parent_sha" ]] || \
    die 2 "parent rebuild receipt changed during forward recovery cancellation"
  printf 'Forward recovery for transaction %s: cancelled\n' "$parent_id"
}

resume_authorized_forward_recovery() {
  local parent_id=$1 authorization child_file child child_id candidate candidate_user effect action
  local baseline parent_sha child_sha child_bytes readiness_status authorization_recheck
  local rebuild_helper sync_helper
  authorization=$(dotfiles_rebuild_read_successor_authorization_v2 \
    "$state_root" "$parent_id" "$active_receipt" pending "$EUID" "$(id -g)" \
    "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user") || \
    die 2 "pending forward recovery authorization is invalid"
  child_file=$state_root/$(jq -r '.child.preparation.path' <<< "$authorization")
  child=$(cat -- "$child_file") || die 1 "failed to read prepared successor receipt"
  child_id=$(jq -r '.transactionId' <<< "$child")
  candidate=$(jq -r '.candidate' <<< "$child")
  candidate_user=$(jq -r '.candidateDefaultUser' <<< "$child")
  effect=$(jq -r '.effect' <<< "$child")
  action=$(jq -r '.action' <<< "$child")
  baseline=$(jq -c '.activationBaseline' <<< "$child")
  parent_sha=$(jq -r '.parent.receipt.sha256' <<< "$authorization")
  child_sha=$(jq -r '.child.preparation.sha256' <<< "$authorization")
  child_bytes=$(jq -r '.child.preparation.bytes' <<< "$authorization")
  rebuild_helper=$(jq -r '.child.helpers.rebuild.canonicalPath' <<< "$authorization")
  sync_helper=$(jq -r '.child.helpers.syncImages.canonicalPath' <<< "$authorization")

  echo "==> OCI image readiness"
  set +e
  "$sync_helper" --status
  readiness_status=$?
  set -e
  if [[ $readiness_status -ne 0 ]]; then
    if [[ $readiness_status -eq 1 ]]; then
      cat >&2 <<MSG
Synchronize the authorized immutable successor, then retry without rebuilding:
  $sync_helper
  $rebuild_helper --forward-recover $parent_id
MSG
    fi
    return "$readiness_status"
  fi

  authorization_recheck=$(dotfiles_rebuild_read_successor_authorization_v2 \
    "$state_root" "$parent_id" "$active_receipt" pending "$EUID" "$(id -g)" \
    "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user") || \
    die 2 "authorized successor evidence changed during readiness"
  [[ $(jq -cS . <<< "$authorization_recheck") == "$(jq -cS . <<< "$authorization")" ]] || \
    die 2 "authorized successor evidence changed during readiness"

  active=$(receipt_read) || die 2 "failed to re-read forward recovery parent before handoff"
  validate_forward_recovery_parent "$active"
  [[ $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$parent_sha" ]] || \
    die 2 "forward recovery parent changed after successor authorization"
  observed_runtime=$(runtime_snapshot) || die 2 "failed to observe runtime before successor handoff"
  same_runtime_snapshot "$baseline" "$observed_runtime" || \
    die 2 "runtime generation changed after successor authorization"
  authorization_recheck=$(dotfiles_rebuild_read_successor_authorization_v2 \
    "$state_root" "$parent_id" "$active_receipt" pending "$EUID" "$(id -g)" \
    "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user") || \
    die 2 "authorized successor evidence changed before handoff"
  [[ $(jq -cS . <<< "$authorization_recheck") == "$(jq -cS . <<< "$authorization")" ]] || \
    die 2 "authorized successor evidence changed before handoff"
  if cat -- "$child_file" | dotfiles_rebuild_handoff_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" \
    "$parent_id" "$parent_sha" "$child_sha" "$child_bytes" "$child_id"; then
    :
  else
    handoff_status=$?
    if [[ $handoff_status -eq 2 ]]; then
      die 2 "authorized successor bytes changed before handoff"
    fi
    if dotfiles_rebuild_validate_receipt_file \
      "$active_receipt" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" &&
      [[ $(jq -r '.transactionId' "$active_receipt") == "$child_id" &&
        $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$child_sha" ]]; then
      reconcile_lineage_handoff
    fi
    die 1 "failed to hand off the active rebuild receipt to its authorized successor"
  fi
  reconcile_lineage_handoff
  assert_activation_baseline forward receipt-publication "$baseline"
  activate_target forward "$candidate" "$effect" "$action" "$candidate_user" "$baseline"
}

if [[ $mode == cancel-forward-recover ]]; then
  cancel_forward_recovery "$transaction_argument"
  exit $?
fi

if [[ $mode == apply || $mode == plan || $mode == forward-recover ]]; then
  sops_enrollment_transaction_id=
  forward_parent_id=
  forward_parent_sha=
  forward_parent_artifact_metadata=null
  if [[ $mode == forward-recover ]]; then
    active=$(receipt_read) || die 2 "failed to read forward recovery parent"
    validate_forward_recovery_parent "$active"
    forward_parent_id=$(jq -r '.transactionId' <<< "$active")
    forward_parent_sha=$(sha256sum "$active_receipt" | cut -d ' ' -f 1) || \
      die 1 "failed to fingerprint forward recovery parent"
    if erasure_edge=$(successor_edge_for_parent \
      "$state_root/successor-erasures" "$forward_parent_id"); then
      erased_child_id=${erasure_edge##*/}
      erased_child_id=${erased_child_id#"$forward_parent_id-"}
      erased_child_id=${erased_child_id%.json}
      [[ $(jq -r '.keepRoots' "$erasure_edge") == false ]] || \
        die 2 "active parent has an invalid keep-roots erasure"
      erasure_reason=$(jq -er '.reason' "$erasure_edge") || \
        die 2 "forward recovery erasure reason is invalid"
      case $erasure_reason in
        discard-partial)
          dotfiles_rebuild_cleanup_successor_v2 \
            "$state_root" "$forward_parent_id" "$erased_child_id" "$erasure_reason" \
            0 run "$active_receipt" "$EUID" "$(id -g)" "$dotfiles" \
            "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user" || \
            die 2 "discarded forward recovery erasure is invalid"
          ;;
        cancel-requested) ;;
        *) die 2 "active parent has an invalid forward recovery erasure reason" ;;
      esac
      dotfiles_rebuild_cleanup_successor_v2 \
        "$state_root" "$forward_parent_id" "$erased_child_id" "$erasure_reason" \
        0 retire "$active_receipt" "$EUID" "$(id -g)" "$dotfiles" \
        "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user" || \
        die 2 "erasing forward recovery blocks a new successor; resume --cancel-forward-recover"
    fi
    if [[ -f $state_root/successors/$forward_parent_id.json &&
      ! -L $state_root/successors/$forward_parent_id.json ]]; then
      resume_authorized_forward_recovery "$forward_parent_id"
      exit $?
    fi
    if preparation_edge=$(successor_edge_for_parent \
      "$state_root/successor-preparations" "$forward_parent_id"); then
      partial_child_id=${preparation_edge##*/}
      partial_child_id=${partial_child_id#"$forward_parent_id-"}
      partial_child_id=${partial_child_id%.json}
      dotfiles_rebuild_cleanup_successor_v2 \
        "$state_root" "$forward_parent_id" "$partial_child_id" discard-partial 0 run "$active_receipt" \
        "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
        "$configured_user" || die 2 "partial forward recovery state is invalid"
      dotfiles_rebuild_cleanup_successor_v2 \
        "$state_root" "$forward_parent_id" "$partial_child_id" discard-partial 0 retire "$active_receipt" \
        "$EUID" "$(id -g)" "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
        "$configured_user" || die 2 "completed forward recovery erasure is invalid"
    fi
  elif [[ -e $active_enrollment || -L $active_enrollment ]]; then
    marker=$(read_enrollment_marker) || die 1 "the SOPS enrollment marker is invalid"
    [[ $(jq -r '.phase' <<< "$marker") == generation-pending ]] || \
      die 1 "an enrollment transaction blocks normal rebuild"
    sops_enrollment_transaction_id=$(jq -r '.transactionId' <<< "$marker")
    new_config_hash=$(jq -er '.newConfigHash | select(type == "string")' <<< "$marker")
    new_secrets_hash=$(jq -er '.newSecretsHash | select(type == "string")' <<< "$marker")
    [[ $(sha256sum "$dotfiles/secrets/.sops.yaml" | cut -d ' ' -f 1) == "$new_config_hash" &&
      $(sha256sum "$dotfiles/secrets/secrets.yaml" | cut -d ' ' -f 1) == "$new_secrets_hash" ]] || \
      die 1 "the prepared SOPS files do not match the enrollment marker"
    mapfile -t enrollment_changes < <(git -C "$dotfiles" diff --name-only | sort)
    [[ ${#enrollment_changes[@]} -eq 2 &&
      ${enrollment_changes[0]} == secrets/.sops.yaml &&
      ${enrollment_changes[1]} == secrets/secrets.yaml ]] || \
      die 1 "only the prepared SOPS files may differ during enrollment rebuild"
    git -C "$dotfiles" diff --cached --quiet HEAD || \
      die 1 "staged changes block enrollment rebuild"
    git -C "$dotfiles" diff --check -- secrets/.sops.yaml secrets/secrets.yaml || \
      die 1 "the prepared SOPS patch is invalid"
    echo "==> SOPS enrollment generation"
  fi

  # untracked file は Git flake snapshot から見えず、無言で配備から落ちる
  untracked=$(git -C "$dotfiles" ls-files --others --exclude-standard)
  if [[ -n $untracked ]]; then
    printf '%s\n' "$untracked" >&2
    die 1 "untracked files block the flake snapshot; run: git -C $dotfiles add -A"
  fi

  temporary_gc_roots=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-rebuild-roots.XXXXXX")
  chmod 0700 "$temporary_gc_roots"
  trap cleanup_temporary_gc_roots EXIT

  echo "==> snapshot"
  source_path=$(
    nix build --out-link "$temporary_gc_roots/source" \
      --print-out-paths --no-write-lock-file "$flake#sourceSnapshot"
  )
  [[ $source_path != *$'\n'* && $source_path == "$nix_store_dir/"* && -d $source_path ]] || \
    die 2 "source snapshot build did not return one store path"
  [[ -L $temporary_gc_roots/source &&
    $(readlink -f -- "$temporary_gc_roots/source") == "$source_path" ]] || \
    die 1 "source snapshot build did not create its temporary GC root"
  source_flake="path:$source_path"

  echo "==> check"
  nix flake check --no-write-lock-file --log-format internal-json -v "$source_flake" |& nom --json

  echo "==> build"
  candidate=$(
    nix build --out-link "$temporary_gc_roots/candidate" \
      --print-out-paths --no-write-lock-file \
      "$source_flake#nixosConfigurations.nixos.config.system.build.toplevel"
  )
  [[ $candidate != *$'\n'* && $candidate == "$nix_store_dir/"* && -d $candidate ]] || \
    die 2 "candidate build did not return one system path"
  [[ -L $temporary_gc_roots/candidate &&
    $(readlink -f -- "$temporary_gc_roots/candidate") == "$candidate" ]] || \
    die 1 "candidate build did not create its temporary GC root"
  doctor_manifest_route forward "$candidate" >/dev/null || \
    die 2 "candidate does not contain a supported schema version $doctor_schema_version doctor manifest"
  candidate_rebuild_logical=$candidate/sw/bin/dotfiles-rebuild
  candidate_sync_logical=$candidate/sw/bin/dotfiles-sync-images
  candidate_doctor_logical=$candidate/sw/bin/dotfiles-doctor
  resolve_store_executable "$candidate_rebuild_logical" >/dev/null || \
    die 2 "candidate does not contain an immutable rebuild resume helper"
  resolve_store_executable "$candidate_sync_logical" >/dev/null || \
    die 2 "candidate target does not contain an executable OCI image sync helper"
  resolve_store_executable "$candidate_doctor_logical" >/dev/null || \
    die 2 "candidate does not contain an immutable doctor helper"
  if [[ $mode == forward-recover && $candidate == $(jq -r '.candidate' "$active_receipt") ]]; then
    die 2 "forward recovery candidate must differ from the failed parent candidate"
  fi

  previous_current=$(readlink -f -- /run/current-system) || die 2 "failed to resolve current system"
  previous_booted=$(readlink -f -- /run/booted-system) || die 2 "failed to resolve booted system"
  previous_profile=$(readlink -f -- "$system_profile_path") || die 2 "failed to resolve system profile"
  for generation in "$previous_current" "$previous_booted" "$previous_profile"; do
    [[ $generation == "$nix_store_dir/"* && -d $generation ]] || \
      die 2 "a previous generation is not a readable Nix store path: $generation"
  done
  previous_runtime=$(jq -cn \
    --arg current "$previous_current" \
    --arg booted "$previous_booted" \
    --arg profile "$previous_profile" \
    '{current: $current, booted: $booted, profile: $profile}')

  echo "==> diff"
  nvd diff "$previous_current" "$candidate"

  if ! effect=$(dotfiles-wsl-restart-required \
    --plan --booted-system "$previous_booted" --current-system "$previous_current" "$candidate"); then
    die 2 "failed to classify the candidate activation effect"
  fi
  case $effect in
    switch | switch-restart) action=switch ;;
    boot-restart | boot-two-stage) action=boot ;;
    *) die 2 "unknown activation effect: $effect" ;;
  esac
  printf '\nCandidate: %s\nEffect:    %s\nAction:    %s\n' "$candidate" "$effect" "$action"

  candidate_user=$(dotfiles-wsl-restart-required --default-user "$candidate") || \
    die 2 "failed to read candidate WSL default user"
  previous_user=$(dotfiles-wsl-restart-required --default-user "$previous_current") || \
    die 2 "failed to read previous WSL default user"
  [[ $candidate_user == "$configured_user" ]] || \
    die 2 "candidate WSL default user $candidate_user does not match configured user $configured_user"
  [[ $previous_user == "$configured_user" ]] || \
    die 2 "previous WSL default user $previous_user does not match configured user $configured_user"

  if [[ $mode == forward-recover ]]; then
    require_target_oci_capability "$candidate" candidate
    successor_rebuild_metadata=$(dotfiles_rebuild_successor_helper_metadata \
      "$candidate_rebuild_logical" "$nix_store_dir") || \
      die 2 "successor rebuild helper is not immutable"
    successor_sync_metadata=$(dotfiles_rebuild_successor_helper_metadata \
      "$candidate_sync_logical" "$nix_store_dir") || \
      die 2 "successor OCI sync helper is not immutable"
    successor_doctor_metadata=$(dotfiles_rebuild_successor_helper_metadata \
      "$candidate_doctor_logical" "$nix_store_dir") || \
      die 2 "successor doctor helper is not immutable"
    successor_manifest_metadata=$(dotfiles_rebuild_successor_manifest_metadata \
      "$candidate/etc/dotfiles/oci-images.json" "$nix_store_dir") || \
      die 2 "candidate OCI manifest is not immutable"
    forward_execution=$(jq -cn \
      --argjson rebuild "$successor_rebuild_metadata" \
      --argjson syncImages "$successor_sync_metadata" \
      --argjson doctor "$successor_doctor_metadata" \
      --argjson manifest "$successor_manifest_metadata" '
        {manifest: $manifest, helpers: {
          rebuild: $rebuild, syncImages: $syncImages, doctor: $doctor
        }}
      ') || die 1 "failed to encode successor execution contract"
  else
    forward_execution=null
    require_target_oci_readiness "$candidate" candidate || exit $?
  fi

  if [[ $mode == plan ]]; then
    cleanup_temporary_gc_roots
    temporary_gc_roots=
    trap - EXIT
    echo "Plan complete; no system profile, runtime state, or rebuild receipt was changed."
    exit 0
  fi

  [[ -n ${WSL_DISTRO_NAME:-} && $WSL_DISTRO_NAME != *$'\n'* ]] || \
    die 2 "WSL_DISTRO_NAME must identify the running distribution"
  observed_runtime=$(runtime_snapshot) || die 2 "failed to resolve runtime generation after planning"
  same_runtime_snapshot "$previous_runtime" "$observed_runtime" || \
    die 2 "runtime generation changed while planning the rebuild; retry from a stable state"

  if [[ $mode == forward-recover ]]; then
    active=$(receipt_read) || die 2 "failed to re-read forward recovery parent"
    verify_receipt_artifacts "$active" || die 2 "forward recovery parent artifacts changed during planning"
    validate_forward_recovery_parent "$active"
    [[ $(sha256sum "$active_receipt" | cut -d ' ' -f 1) == "$forward_parent_sha" ]] || \
      die 2 "forward recovery parent changed while planning"
    forward_parent_artifact_metadata=$(dotfiles_rebuild_expected_artifact_metadata \
      "lineage/$forward_parent_id/verification-failed.json" "$active_receipt") || \
      die 1 "failed to bind the future forward recovery parent artifact"
  fi

  transaction_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ $transaction_id =~ ^[0-9a-f]{32}$ ]] || die 2 "failed to create a rebuild transaction ID"
  before_apply_boot=$(boot_instance) || die 2 "failed to identify the running systemd manager instance"
  timestamp=$(now)
  helper_path=$candidate_rebuild_logical
  receipt_schema_version=3
  [[ $mode != forward-recover ]] || receipt_schema_version=4

  dotfiles_rebuild_prepare_state_root "$state_root" "$EUID" "$(id -g)" || \
    die 1 "failed to prepare rebuild receipt storage"
  if [[ $mode == forward-recover ]]; then
    successor_pending_id=$transaction_id
    successor_parent_id=$forward_parent_id
  else
    dotfiles_rebuild_ensure_gc_roots \
      "$state_root" "$transaction_id" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
      source "$source_path" \
      candidate "$candidate" \
      recovery-target "$previous_current" \
      previous-booted "$previous_booted" \
      displaced-profile "$previous_profile" || \
      die 1 "failed to protect rebuild transaction store paths from garbage collection"
  fi
  observed_runtime=$(runtime_snapshot) || die 2 "failed to resolve runtime generation before receipt publication"
  if ! same_runtime_snapshot "$previous_runtime" "$observed_runtime"; then
    dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
      die 1 "failed to remove rebuild GC roots after runtime drift"
    die 2 "runtime generation changed before publishing the rebuild receipt; retry from a stable state"
  fi
  receipt_json=$(jq -n \
    --argjson schemaVersion "$receipt_schema_version" \
    --arg transactionId "$transaction_id" \
    --arg worktree "$dotfiles" \
    --arg source "$source_path" \
    --arg candidate "$candidate" \
    --arg helperPath "$helper_path" \
    --arg previousCurrent "$previous_current" \
    --arg previousBooted "$previous_booted" \
    --arg previousProfile "$previous_profile" \
    --arg effect "$effect" \
    --arg action "$action" \
    --arg distro "$WSL_DISTRO_NAME" \
    --arg transactionUser "$transaction_user" \
    --argjson transactionUid "$EUID" \
    --arg candidateDefaultUser "$candidate_user" \
    --arg previousDefaultUser "$previous_user" \
    --arg sopsEnrollmentTransactionId "$sops_enrollment_transaction_id" \
    --arg forwardParentId "$forward_parent_id" \
    --argjson forwardParentReceipt "$forward_parent_artifact_metadata" \
    --argjson forwardExecution "$forward_execution" \
    --argjson beforeApplyBoot "$before_apply_boot" \
    --argjson activationBaseline "$previous_runtime" \
    --arg timestamp "$timestamp" '
      {
        schemaVersion: $schemaVersion,
        transactionId: $transactionId,
        worktree: $worktree,
        source: $source,
        candidate: $candidate,
        helperPath: $helperPath,
        previous: {
          running: $previousCurrent,
          booted: $previousBooted,
          displacedProfile: $previousProfile
        },
        recoveryTarget: $previousCurrent,
        effect: $effect,
        action: $action,
        distro: $distro,
        transactionUid: $transactionUid,
        transactionUser: $transactionUser,
        candidateDefaultUser: $candidateDefaultUser,
        previousDefaultUser: $previousDefaultUser,
        sopsEnrollmentTransactionId:
          (if $sopsEnrollmentTransactionId == "" then null else $sopsEnrollmentTransactionId end),
        bootInstances: {beforeApply: $beforeApplyBoot, firstBoot: null},
        activationBaseline: $activationBaseline,
        state: "prepared",
        activationDriver: {
          protocol: "nixos-rebuild-ng-profile-before-activation-v1",
          executable: "@nixosRebuildPath@"
        },
        activation: {status: "pending", exitCode: null, attempts: []},
        verification: {status: "pending", exitCode: null, failedCheckIds: []},
        abort: null,
        cancellation: null,
        migration: null,
        lineage: (
          if $schemaVersion == 4 then {
            kind: "verification-successor",
            protocolVersion: 2,
            parentTransactionId: $forwardParentId,
            parentReceipt: $forwardParentReceipt,
            execution: $forwardExecution,
            createdAt: $timestamp
          } else null end
        ),
        supersession: null,
        failureStage: null,
        rollback: null,
        startedAt: $timestamp,
        updatedAt: $timestamp,
        finishedAt: null
      }
    ')
  if [[ $mode == forward-recover ]]; then
    successor_child_file=$(printf '%s\n' "$receipt_json" | \
      dotfiles_rebuild_publish_successor_preparation \
        "$state_root" "$forward_parent_id" "$transaction_id" "$EUID" "$(id -g)" \
        "$dotfiles" "$nix_store_dir" "$configured_user") || \
      die 1 "failed to publish the forward recovery preparation"
    successor_preparation_published=1
    forward_parent_artifact=$(dotfiles_rebuild_preserve_verification_parent \
      "$state_root" "$EUID" "$(id -g)" "$forward_parent_id" "$active_receipt" \
      "$nix_store_dir" "$transaction_id") || \
      die 1 "failed to preserve forward recovery parent receipt"
    actual_parent_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
      "$state_root" "$forward_parent_artifact" "$EUID" "$(id -g)" 400) || \
      die 1 "failed to bind forward recovery parent receipt"
    [[ $(jq -cS . <<< "$actual_parent_metadata") == \
      $(jq -cS . <<< "$forward_parent_artifact_metadata") ]] || \
      die 2 "forward recovery parent artifact differs from its preparation binding"
    verify_receipt_artifacts "$receipt_json" || \
      die 2 "successor receipt or preserved parent artifact is invalid before authorization"
    dotfiles_rebuild_ensure_gc_roots \
      "$state_root" "$transaction_id" "$nix_store_dir" "$nix_gc_auto_roots_dir" \
      source "$source_path" \
      candidate "$candidate" \
      recovery-target "$previous_current" \
      previous-booted "$previous_booted" \
      displaced-profile "$previous_profile" || \
      die 1 "failed to protect forward recovery store paths from garbage collection"
    successor_child_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
      "$state_root" "$successor_child_file" "$EUID" "$(id -g)" 400) || \
      die 1 "failed to bind the prepared forward recovery successor"
    successor_desired_roots=$(dotfiles_rebuild_desired_successor_roots "$receipt_json") || \
      die 1 "failed to encode successor roots"
    successor_authorization=$(jq -n \
      --argjson schemaVersion 2 \
      --arg parentId "$forward_parent_id" \
      --arg parentCandidate "$(jq -r '.candidate' "$active_receipt")" \
      --argjson parentReceipt "$actual_parent_metadata" \
      --arg childId "$transaction_id" \
      --arg childSource "$source_path" \
      --arg childCandidate "$candidate" \
      --argjson preparation "$successor_child_metadata" \
      --argjson rebuildHelper "$successor_rebuild_metadata" \
      --argjson syncHelper "$successor_sync_metadata" \
      --argjson doctorHelper "$successor_doctor_metadata" \
      --argjson manifest "$successor_manifest_metadata" \
      --argjson activationBaseline "$previous_runtime" \
      --argjson roots "$successor_desired_roots" \
      --arg timestamp "$timestamp" '
        {
          schemaVersion: $schemaVersion,
          kind: "verification-successor-authorization",
          parent: {
            transactionId: $parentId,
            candidate: $parentCandidate,
            receipt: $parentReceipt
          },
          child: {
            transactionId: $childId,
            source: $childSource,
            candidate: $childCandidate,
            preparation: $preparation,
            helpers: {
              rebuild: $rebuildHelper,
              syncImages: $syncHelper,
              doctor: $doctorHelper
            },
            manifest: $manifest
          },
          lineage: {parentReceipt: $parentReceipt},
          activationBaseline: $activationBaseline,
          roots: $roots,
          createdAt: $timestamp
        }
      ') || die 1 "failed to encode forward recovery authorization"
    if printf '%s\n' "$successor_authorization" | \
      dotfiles_rebuild_publish_successor_authorization_v2 \
        "$state_root" "$forward_parent_id" "$active_receipt" "$EUID" "$(id -g)" \
        "$dotfiles" "$nix_store_dir" "$nix_gc_auto_roots_dir" "$configured_user"; then
      :
    else
      authorization_status=$?
      if [[ $authorization_status -eq 2 ]]; then
        die 2 "successor authorization inputs changed before publication"
      fi
      die 1 "failed to publish forward recovery authorization"
    fi
    successor_preparation_published=0
    cleanup_temporary_gc_roots
    temporary_gc_roots=
    trap - EXIT
    resume_authorized_forward_recovery "$forward_parent_id"
    exit $?
  fi

  if ! printf '%s\n' "$receipt_json" | dotfiles_rebuild_create_active_receipt \
    "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user"; then
    if [[ ! -e $active_receipt && ! -L $active_receipt ]]; then
      dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
        die 1 "failed to clean GC roots after receipt publication failure"
    fi
    die 1 "failed to create the active rebuild receipt"
  fi
  cleanup_temporary_gc_roots
  temporary_gc_roots=
  trap - EXIT
  assert_activation_baseline forward receipt-publication "$previous_runtime"
  activate_target forward "$candidate" "$effect" "$action" "$candidate_user" "$previous_runtime"
  exit $?
fi

active=$(receipt_read) || die 1 "failed to read the active rebuild receipt"
if [[ $(jq -r '.lineage != null' <<< "$active") == true ]]; then
  resolve_receipt_execution_helper "$active" rebuild >/dev/null || \
    die 2 "active successor rebuild helper differs from its execution contract"
  reconcile_lineage_handoff
fi
validate_enrollment_binding || die 2 "rebuild receipt and SOPS enrollment state do not match"
ensure_receipt_roots
active=$(receipt_read) || die 1 "failed to read the active rebuild receipt"
state=$(jq -r '.state' <<< "$active")
candidate=$(jq -r '.candidate' <<< "$active")
candidate_user=$(jq -r '.candidateDefaultUser' <<< "$active")

case $state in
  activating) reconcile_interrupted_activation forward ;;
  rollback-activating) reconcile_interrupted_activation rollback ;;
esac
active=$(receipt_read) || die 1 "failed to read the active rebuild receipt after reconciliation"
state=$(jq -r '.state' <<< "$active")

if [[ $mode == abort ]]; then
  cancel_transaction
  exit $?
fi

if [[ $mode == first-boot ]]; then
  set +e
  case $state in
    restart-pending)
      observe_first_boot forward "$candidate" "$candidate_user"
      first_boot_status=$?
      ;;
    rollback-restart-pending)
      previous=$(jq -r '.rollback.target' <<< "$active")
      previous_user=$(jq -r '.previousDefaultUser' <<< "$active")
      observe_first_boot rollback "$previous" "$previous_user"
      first_boot_status=$?
      ;;
    *)
      echo "FATAL: first boot cannot be recorded from state $state" >&2
      first_boot_status=2
      ;;
  esac
  set -e
  exit "$first_boot_status"
fi

if [[ $mode == rollback && $state != aborted ]] && jq -e '.rollback == null' <<< "$active" >/dev/null; then
  previous=$(jq -r '.recoveryTarget' <<< "$active")
  previous_user=$(jq -r '.previousDefaultUser' <<< "$active")
  [[ $(read_doctor_manifest_schema "$previous" 2>/dev/null || true) == "$doctor_schema_version" ]] || \
    die 2 "recovery target requires doctor manifest schema version $doctor_schema_version"
  require_target_oci_readiness "$previous" recovery || exit $?
  rollback_current=$(readlink -f -- /run/current-system) || die 2 "failed to resolve current system for rollback"
  rollback_booted=$(readlink -f -- /run/booted-system) || die 2 "failed to resolve booted system for rollback"
  rollback_profile=$(readlink -f -- "$system_profile_path") || \
    die 2 "failed to resolve system profile for rollback"
  for generation in "$rollback_current" "$rollback_booted" "$rollback_profile"; do
    [[ $generation == "$nix_store_dir/"* && -d $generation ]] || \
      die 2 "a rollback generation is not a readable Nix store path: $generation"
  done
  rollback_runtime=$(jq -cn \
    --arg current "$rollback_current" \
    --arg booted "$rollback_booted" \
    --arg profile "$rollback_profile" \
    '{current: $current, booted: $booted, profile: $profile}')
  if ! rollback_effect=$(dotfiles-wsl-restart-required \
    --plan --booted-system "$rollback_booted" --current-system "$rollback_current" "$previous"); then
    die 2 "failed to classify the recorded previous system"
  fi
  case $rollback_effect in
    switch | switch-restart) rollback_action=switch ;;
    boot-restart | boot-two-stage) rollback_action=boot ;;
    *) die 2 "unknown rollback activation effect: $rollback_effect" ;;
  esac
  rollback_before_boot=$(boot_instance) || die 2 "failed to identify the rollback systemd manager instance"
  observed_runtime=$(runtime_snapshot) || die 2 "failed to resolve runtime generation after planning the rollback"
  same_runtime_snapshot "$rollback_runtime" "$observed_runtime" || \
    die 2 "runtime generation changed while planning the rollback; retry from a stable state"
  timestamp=$(now)
  receipt_update \
    --arg target "$previous" \
    --arg effect "$rollback_effect" \
    --arg action "$rollback_action" \
    --argjson beforeApplyBoot "$rollback_before_boot" \
    --argjson activationBaseline "$rollback_runtime" \
    --arg timestamp "$timestamp" '
      .rollback = {
        target: $target,
        effect: $effect,
        action: $action,
        activationBaseline: $activationBaseline,
        bootInstances: {beforeApply: $beforeApplyBoot, firstBoot: null},
        activation: {status: "pending", exitCode: null, attempts: []}
      } |
      .state = "rollback-intent" |
      .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
      .failureStage = null |
      .finishedAt = null |
      .updatedAt = $timestamp
    '
  activate_target rollback "$previous" "$rollback_effect" "$rollback_action" "$previous_user" "$rollback_runtime"
  exit $?
fi

case $state in
  prepared | apply-intent | activation-indeterminate | activation-failed)
    require_target_oci_readiness "$candidate" candidate || exit $?
    effect=$(jq -r '.effect' <<< "$active")
    action=$(jq -r '.action' <<< "$active")
    resume_activation forward "$candidate" "$effect" "$action" "$candidate_user"
    ;;
  restart-pending)
    effect=$(jq -r '.effect' <<< "$active")
    if [[ $effect == boot-two-stage ]]; then
      print_restart_instructions forward "$effect"
      exit 3
    fi
    verify_target forward "$candidate" "$candidate_user" "$effect"
    ;;
  first-boot-observed | verifying | verification-failed)
    effect=$(jq -r '.effect' <<< "$active")
    verify_target forward "$candidate" "$candidate_user" "$effect"
    ;;
  rollback-intent | rollback-activation-indeterminate | rollback-activation-failed)
    previous=$(jq -r '.rollback.target' <<< "$active")
    require_target_oci_readiness "$previous" recovery || exit $?
    previous_user=$(jq -r '.previousDefaultUser' <<< "$active")
    rollback_effect=$(jq -r '.rollback.effect' <<< "$active")
    rollback_action=$(jq -r '.rollback.action' <<< "$active")
    resume_activation rollback "$previous" "$rollback_effect" "$rollback_action" "$previous_user"
    ;;
  rollback-restart-pending)
    previous=$(jq -r '.rollback.target' <<< "$active")
    previous_user=$(jq -r '.previousDefaultUser' <<< "$active")
    rollback_effect=$(jq -r '.rollback.effect' <<< "$active")
    if [[ $rollback_effect == boot-two-stage ]]; then
      print_restart_instructions rollback "$rollback_effect"
      exit 3
    fi
    verify_target rollback "$previous" "$previous_user" "$rollback_effect"
    ;;
  rollback-first-boot-observed | rollback-verifying | rollback-verification-failed)
    previous=$(jq -r '.rollback.target' <<< "$active")
    previous_user=$(jq -r '.previousDefaultUser' <<< "$active")
    rollback_effect=$(jq -r '.rollback.effect' <<< "$active")
    verify_target rollback "$previous" "$previous_user" "$rollback_effect"
    ;;
  complete | rolled-back | aborted)
    transaction_id=$(jq -r '.transactionId' <<< "$active")
    dotfiles_rebuild_archive_active_receipt \
      "$state_root" "$EUID" "$dotfiles" "$nix_store_dir" "$configured_user" "$transaction_id" || \
      die 1 "failed to archive terminal rebuild receipt"
    dotfiles_rebuild_remove_gc_roots "$state_root" "$transaction_id" || \
      die 1 "failed to remove terminal rebuild GC roots"
    ;;
  *) die 2 "cannot resume rebuild transaction in state $state" ;;
esac
