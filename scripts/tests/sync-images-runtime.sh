#!/usr/bin/env bash
set -euo pipefail

report_test_failure() {
  local status=$?
  if [[ $- == *e* ]]; then
    printf 'sync-images runtime test stopped at line %s (status %s)\n' \
      "${BASH_LINENO[0]}" "$status" >&2
  fi
  return "$status"
}
trap report_test_failure ERR

if [[ $# -ne 1 ]]; then
  echo "usage: $0 SYNC_IMAGES_COMMAND" >&2
  exit 2
fi

sync_images=$1
test_root=$(mktemp -d)
state_root=$test_root/state
git_common_dir=$test_root/git-common
dotfiles=$test_root/dotfiles-wsl
nix_store_dir=$test_root/nix/store
nix_gc_auto_roots_dir=$test_root/nix/var/nix/gcroots/auto
docker_state=$test_root/docker-state.json
docker_log=$test_root/docker.log
manifest=$nix_store_dir/oci-images.json
stdout_log=$test_root/stdout.log
stderr_log=$test_root/stderr.log
fake_docker=$test_root/docker
sync_pid=
mkdir -m 0700 "$git_common_dir" "$dotfiles"
mkdir -p "$nix_store_dir" "$nix_gc_auto_roots_dir"

cleanup() {
  local status=$?
  if [[ -n $sync_pid ]]; then
    kill "$sync_pid" 2>/dev/null || true
    wait "$sync_pid" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    echo "sync-images runtime fixture failed with status $status" >&2
    if [[ -s $stdout_log ]]; then
      echo "--- captured stdout ---" >&2
      sed 's/^/  /' "$stdout_log" >&2
    fi
    if [[ -s $stderr_log ]]; then
      echo "--- captured stderr ---" >&2
      sed 's/^/  /' "$stderr_log" >&2
    fi
  fi
  if [[ -d $state_root && ! -L $state_root ]]; then
    chmod -R u+rwx "$state_root" 2>/dev/null || true
  fi
  rm -r -- "$test_root"
}
trap cleanup EXIT

digest_a=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
digest_b=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
image_a="example.test/a:latest@$digest_a"
image_b="example.test/b:v1@$digest_b"

auto_registration_for() {
  local root=$1 name
  name=$(printf '%s' "$root" | sha256sum | cut -d ' ' -f 1 | tr e z | cut -c 1-32)
  printf '%s/%s\n' "$nix_gc_auto_roots_dir" "$name"
}

jq -n \
  --arg digestA "$digest_a" \
  --arg digestB "$digest_b" \
  --arg imageA "$image_a" \
  --arg imageB "$image_b" '
    {
      schemaVersion: 2,
      images: [
        {
          id: "agentmemory", kind: "nix", container: "agentmemory",
          image: "agentmemory:fixture", repository: null, digest: null,
          imageFile: "/nix/store/fixture-agentmemory.tar.gz"
        },
        {
          id: "image-a", kind: "upstream", container: "image-a",
          image: $imageA, repository: "example.test/a", digest: $digestA, imageFile: null
        },
        {
          id: "image-b", kind: "upstream", container: "image-b",
          image: $imageB, repository: "example.test/b", digest: $digestB, imageFile: null
        }
      ]
    }
  ' > "$manifest"

{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'DOCKER'
set -euo pipefail

case ${1-}:${2-} in
  image:inspect)
    [[ $# -eq 3 ]]
    image=$3
    jq -e --arg image "$image" '
      if has($image) then [.[$image]] else empty end
    ' "$TEST_DOCKER_STATE"
    ;;
  pull:*)
    [[ $# -eq 2 ]]
    image=$2
    printf '%s\n' "$image" >> "$TEST_DOCKER_LOG"
    if [[ $image == "${TEST_DOCKER_WAIT_IMAGE:-}" ]]; then
      : > "$TEST_DOCKER_READY"
      while [[ ! -e $TEST_DOCKER_RELEASE ]]; do
        sleep 0.01
      done
    fi
    [[ $image != "${TEST_DOCKER_FAIL_IMAGE:-}" ]] || exit 23
    row=$(jq -ec --arg image "$image" '.images[] | select(.image == $image)' "$TEST_DOCKER_MANIFEST")
    repository=$(jq -r '.repository' <<< "$row")
    digest=$(jq -r '.digest' <<< "$row")
    if [[ $image == "${TEST_DOCKER_DIGEST_MISMATCH_IMAGE:-}" ]]; then
      digest=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    fi
    image_id="sha256:$(printf '%s' "$image" | sha256sum | cut -d ' ' -f 1)"
    temporary=$(mktemp "${TEST_DOCKER_STATE}.XXXXXX")
    jq \
      --arg image "$image" \
      --arg id "$image_id" \
      --arg repoDigest "${repository}@${digest}" '
        .[$image] = {Id: $id, RepoDigests: [$repoDigest]}
      ' "$TEST_DOCKER_STATE" > "$temporary"
    mv -T -- "$temporary" "$TEST_DOCKER_STATE"
    ;;
  *)
    echo "unexpected docker invocation: $*" >&2
    exit 64
    ;;
esac
DOCKER
} > "$fake_docker"
chmod +x "$fake_docker"

export TEST_DOCKER_STATE=$docker_state
export TEST_DOCKER_LOG=$docker_log
export TEST_DOCKER_MANIFEST=$manifest
export TEST_DOCKER_FAIL_IMAGE=
export TEST_DOCKER_DIGEST_MISMATCH_IMAGE=
export TEST_DOCKER_WAIT_IMAGE=
export TEST_DOCKER_READY=$test_root/docker.ready
export TEST_DOCKER_RELEASE=$test_root/docker.release

reset_fixture() {
  if [[ -e $state_root || -L $state_root ]]; then
    if [[ -d $state_root && ! -L $state_root ]]; then
      chmod -R u+rwx "$state_root" 2>/dev/null || true
    fi
    rm -r -- "$state_root"
  fi
  printf '%s\n' '{}' > "$docker_state"
  : > "$docker_log"
  : > "$stdout_log"
  : > "$stderr_log"
  rm -f -- "$TEST_DOCKER_READY" "$TEST_DOCKER_RELEASE"
  TEST_DOCKER_FAIL_IMAGE=
  TEST_DOCKER_DIGEST_MISMATCH_IMAGE=
  TEST_DOCKER_WAIT_IMAGE=
  export TEST_DOCKER_FAIL_IMAGE TEST_DOCKER_DIGEST_MISMATCH_IMAGE TEST_DOCKER_WAIT_IMAGE
}

run_sync() {
  local command=${TEST_SYNC_COMMAND:-$sync_images}
  set +e
  DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
    DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
    DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
    DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
    DOTFILES_IMAGE_SYNC_TEST_DOTFILES=$dotfiles \
    DOTFILES_IMAGE_SYNC_TEST_NIX_STORE_DIR=$nix_store_dir \
    DOTFILES_IMAGE_SYNC_TEST_NIX_GC_AUTO_ROOTS_DIR=$nix_gc_auto_roots_dir \
    DOTFILES_IMAGE_SYNC_TEST_EXPECTED_USER=$(id -un) \
    "$command" "$@" > "$stdout_log" 2> "$stderr_log"
  sync_status=$?
  set -e
}

candidate_target=$nix_store_dir/candidate-system
recovery_target=$nix_store_dir/recovery-system
source_target=$nix_store_dir/source
booted_target=$nix_store_dir/booted-system
profile_target=$nix_store_dir/profile-system
mkdir -p \
  "$candidate_target/etc/dotfiles" "$recovery_target/etc/dotfiles" \
  "$source_target" "$booted_target" "$profile_target"
ln -s "$manifest" "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$recovery_target/etc/dotfiles/oci-images.json"

write_active_rebuild_receipt() {
  local state=$1 receipt_dir receipt
  local activation_status=pending activation_exit=null failure_stage=null finished_at=null
  receipt_dir=$git_common_dir/dotfiles-rebuild
  receipt=$receipt_dir/active.json
  case $state in
    prepared) ;;
    activation-failed)
      activation_status=failed
      activation_exit=71
      failure_stage=activation
      ;;
    complete)
      activation_status=succeeded
      activation_exit=0
      finished_at='2026-07-19T00:01:00Z'
      ;;
    *) return 2 ;;
  esac
  install -d -m 0700 "$receipt_dir" "$receipt_dir/receipts" "$receipt_dir/roots"
  jq -n \
    --arg worktree "$dotfiles" \
    --arg store "$nix_store_dir" \
    --arg source "$source_target" \
    --arg candidate "$candidate_target" \
    --arg recovery "$recovery_target" \
    --arg booted "$booted_target" \
    --arg profile "$profile_target" \
    --arg user "$(id -un)" \
    --arg state "$state" \
    --arg activationStatus "$activation_status" \
    --argjson activationExit "$activation_exit" \
    --arg failureStage "$failure_stage" \
    --arg finishedAt "$finished_at" \
    --argjson uid "$EUID" '
      {
        schemaVersion: 2,
        transactionId: "0123456789abcdef0123456789abcdef",
        worktree: $worktree,
        source: $source,
        candidate: $candidate,
        helperPath: ($candidate + "/sw/bin/dotfiles-rebuild"),
        previous: {running: $recovery, booted: $booted, displacedProfile: $profile},
        recoveryTarget: $recovery,
        effect: "switch",
        action: "switch",
        distro: "NixOS",
        transactionUid: $uid,
        transactionUser: $user,
        candidateDefaultUser: $user,
        previousDefaultUser: $user,
        sopsEnrollmentTransactionId: null,
        bootInstances: {
          beforeApply: {
            kernelBootId: "11111111-1111-1111-1111-111111111111",
            userspaceTimestampMonotonic: "100"
          },
          firstBoot: null
        },
        activationBaseline: {current: $recovery, booted: $booted, profile: $profile},
        state: $state,
        activation: {status: $activationStatus, exitCode: $activationExit},
        verification:
          if $state == "complete" then
            {status: "succeeded", exitCode: 0, failedCheckIds: []}
          else
            {status: "pending", exitCode: null, failedCheckIds: []}
          end,
        abort: null,
        failureStage: (if $failureStage == "null" then null else $failureStage end),
        rollback: null,
        startedAt: "2026-07-19T00:00:00Z",
        updatedAt: "2026-07-19T00:01:00Z",
        finishedAt: (if $finishedAt == "null" then null else $finishedAt end)
      }
    ' > "$receipt"
  chmod 0600 "$receipt"
}

write_cancelled_rebuild_receipt() {
  local receipt
  write_active_rebuild_receipt prepared
  receipt=$git_common_dir/dotfiles-rebuild/active.json
  jq '
    .schemaVersion = 3 |
    .state = "cancelled" |
    .activationDriver = {
      protocol: "nixos-rebuild-ng-profile-before-activation-v1",
      executable: "/fixture/nixos-rebuild"
    } |
    .activation.attempts = [] |
    .cancellation = {
      kind: "manual-zero-effect",
      fromState: "prepared",
      boundary: "before-profile-commit",
      driverContract: "nixos-rebuild-ng-profile-before-activation-v1",
      expectedRuntime: .activationBaseline,
      observedRuntime: .activationBaseline,
      expectedBootInstance: .bootInstances.beforeApply,
      observedBootInstance: .bootInstances.beforeApply,
      requestedAt: "2026-07-19T00:01:00Z"
    } |
    .migration = null |
    .lineage = null |
    .supersession = null |
    .updatedAt = "2026-07-19T00:01:00Z" |
    .finishedAt = "2026-07-19T00:01:00Z"
  ' "$receipt" > "$receipt.tmp"
  mv -T -- "$receipt.tmp" "$receipt"
  chmod 0600 "$receipt"
}

write_authorized_successor_fixture() {
  local rebuild_root parent_id child_id attempt_id parent_receipt parent_artifact
  local attempt_root intent_file started_file log_file outcome_file
  local intent_metadata started_metadata log_metadata outcome_metadata
  local child_receipt child_source child_candidate child_rebuild_helper child_sync_helper
  local child_doctor_helper child_sha child_bytes rebuild_metadata sync_metadata doctor_metadata
  local manifest_metadata
  local manifest_canonical manifest_sha manifest_bytes label target
  local parent_artifact_sha parent_artifact_bytes parent_metadata preparation_metadata
  rebuild_root=$git_common_dir/dotfiles-rebuild
  parent_id=11111111111111111111111111111111
  child_id=22222222222222222222222222222222
  attempt_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  parent_receipt=$rebuild_root/active.json
  parent_artifact=$rebuild_root/lineage/$parent_id/verification-failed.json
  child_source=$nix_store_dir/successor-source
  child_candidate=$nix_store_dir/successor-system
  child_rebuild_helper=$child_candidate/sw/bin/dotfiles-rebuild
  child_sync_helper=$child_candidate/sw/bin/dotfiles-sync-images
  child_doctor_helper=$child_candidate/sw/bin/dotfiles-doctor
  child_receipt=$rebuild_root/successor-preparations/$parent_id-$child_id.json

  mkdir -p \
    "$child_source" "$child_candidate/etc/dotfiles" "$child_candidate/sw/bin" \
    "$rebuild_root/receipts" "$rebuild_root/roots/$child_id" \
    "$rebuild_root/lineage/$parent_id" "$rebuild_root/successor-preparations" \
    "$rebuild_root/successors" "$rebuild_root/successor-erasures" \
    "$rebuild_root/successor-garbage"
  chmod 0700 \
    "$rebuild_root" "$rebuild_root/receipts" "$rebuild_root/roots" \
    "$rebuild_root/roots/$child_id" "$rebuild_root/lineage" \
    "$rebuild_root/lineage/$parent_id" "$rebuild_root/successor-preparations" \
    "$rebuild_root/successors" "$rebuild_root/successor-erasures" \
    "$rebuild_root/successor-garbage"
  ln -sfn "$manifest" "$child_candidate/etc/dotfiles/oci-images.json"
  rm -f -- "$child_rebuild_helper" "$child_sync_helper" "$child_doctor_helper"
  printf '#!%s\nexit 0\n' "$(command -v bash)" > "$child_rebuild_helper"
  cp -- "$sync_images" "$child_sync_helper"
  printf '#!%s\nexit 0\n' "$(command -v bash)" > "$child_doctor_helper"
  chmod 0500 "$child_rebuild_helper" "$child_sync_helper" "$child_doctor_helper"
  rebuild_metadata=$(jq -cn --arg logicalPath "$child_rebuild_helper" \
    --arg canonicalPath "$(readlink -e "$child_rebuild_helper")" \
    --arg sha256 "$(sha256sum "$child_rebuild_helper" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$child_rebuild_helper")" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}')
  sync_metadata=$(jq -cn --arg logicalPath "$child_sync_helper" \
    --arg canonicalPath "$(readlink -e "$child_sync_helper")" \
    --arg sha256 "$(sha256sum "$child_sync_helper" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$child_sync_helper")" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}')
  doctor_metadata=$(jq -cn --arg logicalPath "$child_doctor_helper" \
    --arg canonicalPath "$(readlink -e "$child_doctor_helper")" \
    --arg sha256 "$(sha256sum "$child_doctor_helper" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$child_doctor_helper")" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}')
  TEST_SYNC_COMMAND=$child_sync_helper
  export TEST_SYNC_COMMAND

  jq -n \
    --arg parentId "$parent_id" \
    --arg attemptId "$attempt_id" \
    --arg worktree "$dotfiles" \
    --arg source "$source_target" \
    --arg candidate "$candidate_target" \
    --arg recovery "$recovery_target" \
    --arg booted "$booted_target" \
    --arg profile "$profile_target" \
    --arg user "$(id -un)" \
    --argjson uid "$EUID" '
      {
        schemaVersion: 3,
        transactionId: $parentId,
        worktree: $worktree,
        source: $source,
        candidate: $candidate,
        helperPath: ($candidate + "/sw/bin/dotfiles-rebuild"),
        previous: {running: $recovery, booted: $booted, displacedProfile: $profile},
        recoveryTarget: $recovery,
        effect: "switch",
        action: "switch",
        distro: "NixOS",
        transactionUid: $uid,
        transactionUser: $user,
        candidateDefaultUser: $user,
        previousDefaultUser: $user,
        sopsEnrollmentTransactionId: null,
        bootInstances: {
          beforeApply: {
            kernelBootId: "11111111-1111-1111-1111-111111111111",
            userspaceTimestampMonotonic: "100"
          },
          firstBoot: null
        },
        activationBaseline: {current: $recovery, booted: $booted, profile: $profile},
        state: "verification-failed",
        activationDriver: {
          protocol: "nixos-rebuild-ng-profile-before-activation-v1",
          executable: "/fixture/nixos-rebuild"
        },
        activation: {
          status: "succeeded",
          exitCode: 0,
          attempts: [{
            number: 1,
            attemptId: $attemptId,
            direction: "forward",
            target: $candidate,
            action: "switch",
            activationBaseline: {current: $recovery, booted: $booted, profile: $profile},
            bootBaseline: {
              kernelBootId: "11111111-1111-1111-1111-111111111111",
              userspaceTimestampMonotonic: "100"
            },
            status: "succeeded",
            boundary: "after-profile-commit",
            createdAt: "2026-07-19T00:00:00Z",
            startedAt: "2026-07-19T00:00:01Z",
            finishedAt: "2026-07-19T00:00:02Z",
            exitCode: 0,
            intent: {
              path: ("attempts/" + $parentId + "/1-" + $attemptId + "/intent.json"),
              sha256: ("0" * 64), bytes: 1
            },
            partialLogPath:
              ("attempts/" + $parentId + "/1-" + $attemptId + "/activation.log.partial"),
            started: {
              path: ("attempts/" + $parentId + "/1-" + $attemptId + "/started.json"),
              sha256: ("1" * 64), bytes: 1
            },
            log: {
              path: ("attempts/" + $parentId + "/1-" + $attemptId + "/activation.log"),
              sha256: ("2" * 64), bytes: 1, truncated: false, captureExitCode: 0
            },
            outcome: {
              path: ("attempts/" + $parentId + "/1-" + $attemptId + "/outcome.json"),
              sha256: ("3" * 64), bytes: 1
            }
          }]
        },
        verification: {status: "failed", exitCode: 1, failedCheckIds: ["mcp.fixture"]},
        abort: null,
        cancellation: null,
        migration: null,
        lineage: null,
        supersession: null,
        failureStage: "doctor",
        rollback: null,
        startedAt: "2026-07-19T00:00:00Z",
        updatedAt: "2026-07-19T00:01:00Z",
        finishedAt: null
      }
    ' > "$parent_receipt"
  chmod 0600 "$parent_receipt"

  attempt_root=$rebuild_root/attempts/$parent_id/1-$attempt_id
  mkdir -p "$attempt_root"
  chmod 0700 \
    "$rebuild_root/attempts" "$rebuild_root/attempts/$parent_id" "$attempt_root"
  intent_file=$attempt_root/intent.json
  started_file=$attempt_root/started.json
  log_file=$attempt_root/activation.log
  outcome_file=$attempt_root/outcome.json
  jq -n \
    --arg transactionId "$parent_id" \
    --arg attemptId "$attempt_id" \
    --arg target "$candidate_target" \
    --arg recovery "$recovery_target" \
    --arg booted "$booted_target" \
    --arg profile "$profile_target" '
      {
        schemaVersion: 1,
        transactionId: $transactionId,
        number: 1,
        attemptId: $attemptId,
        direction: "forward",
        target: $target,
        action: "switch",
        driver: {
          protocol: "nixos-rebuild-ng-profile-before-activation-v1",
          executable: "/fixture/nixos-rebuild"
        },
        activationBaseline: {current: $recovery, booted: $booted, profile: $profile},
        bootBaseline: {
          kernelBootId: "11111111-1111-1111-1111-111111111111",
          userspaceTimestampMonotonic: "100"
        },
        createdAt: "2026-07-19T00:00:00Z"
      }
    ' > "$intent_file"
  jq -n \
    --arg transactionId "$parent_id" \
    --arg attemptId "$attempt_id" '
      {
        schemaVersion: 1,
        transactionId: $transactionId,
        number: 1,
        attemptId: $attemptId,
        runnerPid: "1234",
        startedAt: "2026-07-19T00:00:01Z"
      }
    ' > "$started_file"
  printf '%s\n' 'fixture activation log' > "$log_file"
  jq -n \
    --arg transactionId "$parent_id" \
    --arg attemptId "$attempt_id" \
    --arg candidate "$candidate_target" \
    --arg booted "$booted_target" '
      {
        schemaVersion: 1,
        transactionId: $transactionId,
        number: 1,
        attemptId: $attemptId,
        exitCode: 0,
        captureExitCode: 0,
        truncated: false,
        boundary: "after-profile-commit",
        finishedAt: "2026-07-19T00:00:02Z",
        observedRuntime: {current: $candidate, booted: $booted, profile: $candidate},
        observedBootInstance: {
          kernelBootId: "11111111-1111-1111-1111-111111111111",
          userspaceTimestampMonotonic: "100"
        }
      }
    ' > "$outcome_file"
  chmod 0600 "$intent_file" "$started_file" "$outcome_file"
  chmod 0400 "$log_file"
  intent_metadata=$(jq -cn \
    --arg path "attempts/$parent_id/1-$attempt_id/intent.json" \
    --arg sha256 "$(sha256sum "$intent_file" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$intent_file")" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')
  started_metadata=$(jq -cn \
    --arg path "attempts/$parent_id/1-$attempt_id/started.json" \
    --arg sha256 "$(sha256sum "$started_file" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$started_file")" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')
  log_metadata=$(jq -cn \
    --arg path "attempts/$parent_id/1-$attempt_id/activation.log" \
    --arg sha256 "$(sha256sum "$log_file" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$log_file")" \
    '{path: $path, sha256: $sha256, bytes: $bytes, truncated: false, captureExitCode: 0}')
  outcome_metadata=$(jq -cn \
    --arg path "attempts/$parent_id/1-$attempt_id/outcome.json" \
    --arg sha256 "$(sha256sum "$outcome_file" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$outcome_file")" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')
  jq \
    --argjson intent "$intent_metadata" \
    --argjson started "$started_metadata" \
    --argjson log "$log_metadata" \
    --argjson outcome "$outcome_metadata" '
      .activation.attempts[0].intent = $intent |
      .activation.attempts[0].started = $started |
      .activation.attempts[0].log = $log |
      .activation.attempts[0].outcome = $outcome
    ' "$parent_receipt" > "$parent_receipt.tmp"
  mv -T -- "$parent_receipt.tmp" "$parent_receipt"
  chmod 0600 "$parent_receipt"
  cp -- "$parent_receipt" "$parent_artifact"
  chmod 0400 "$parent_artifact"
  parent_artifact_sha=$(sha256sum "$parent_artifact" | cut -d ' ' -f 1)
  parent_artifact_bytes=$(stat -c '%s' "$parent_artifact")
  manifest_canonical=$(readlink -e "$child_candidate/etc/dotfiles/oci-images.json")
  manifest_sha=$(sha256sum "$manifest_canonical" | cut -d ' ' -f 1)
  manifest_bytes=$(stat -c '%s' "$manifest_canonical")
  manifest_metadata=$(jq -cn \
    --arg logicalPath "$child_candidate/etc/dotfiles/oci-images.json" \
    --arg canonicalPath "$manifest_canonical" --arg sha256 "$manifest_sha" \
    --argjson bytes "$manifest_bytes" \
    '{logicalPath: $logicalPath, canonicalPath: $canonicalPath, sha256: $sha256, bytes: $bytes}')

  jq -n \
    --arg childId "$child_id" \
    --arg parentId "$parent_id" \
    --arg worktree "$dotfiles" \
    --arg source "$child_source" \
    --arg candidate "$child_candidate" \
    --arg recovery "$candidate_target" \
    --arg booted "$booted_target" \
    --arg profile "$candidate_target" \
    --arg user "$(id -un)" \
    --arg parentArtifactSha "$parent_artifact_sha" \
    --argjson parentArtifactBytes "$parent_artifact_bytes" \
    --argjson rebuildHelper "$rebuild_metadata" \
    --argjson syncHelper "$sync_metadata" \
    --argjson doctorHelper "$doctor_metadata" \
    --argjson manifest "$manifest_metadata" \
    --argjson uid "$EUID" '
      {
        schemaVersion: 4,
        transactionId: $childId,
        worktree: $worktree,
        source: $source,
        candidate: $candidate,
        helperPath: ($candidate + "/sw/bin/dotfiles-rebuild"),
        previous: {running: $recovery, booted: $booted, displacedProfile: $profile},
        recoveryTarget: $recovery,
        effect: "switch",
        action: "switch",
        distro: "NixOS",
        transactionUid: $uid,
        transactionUser: $user,
        candidateDefaultUser: $user,
        previousDefaultUser: $user,
        sopsEnrollmentTransactionId: null,
        bootInstances: {
          beforeApply: {
            kernelBootId: "11111111-1111-1111-1111-111111111111",
            userspaceTimestampMonotonic: "100"
          },
          firstBoot: null
        },
        activationBaseline: {current: $recovery, booted: $booted, profile: $profile},
        state: "prepared",
        activationDriver: {
          protocol: "nixos-rebuild-ng-profile-before-activation-v1",
          executable: "/fixture/nixos-rebuild"
        },
        activation: {status: "pending", exitCode: null, attempts: []},
        verification: {status: "pending", exitCode: null, failedCheckIds: []},
        abort: null,
        cancellation: null,
        migration: null,
        lineage: {
          kind: "verification-successor",
          protocolVersion: 2,
          parentTransactionId: $parentId,
          parentReceipt: {
            path: ("lineage/" + $parentId + "/verification-failed.json"),
            sha256: $parentArtifactSha,
            bytes: $parentArtifactBytes
          },
          execution: {
            helpers: {
              rebuild: $rebuildHelper,
              syncImages: $syncHelper,
              doctor: $doctorHelper
            },
            manifest: $manifest
          },
          createdAt: "2026-07-19T00:02:00Z"
        },
        supersession: null,
        failureStage: null,
        rollback: null,
        startedAt: "2026-07-19T00:02:00Z",
        updatedAt: "2026-07-19T00:02:00Z",
        finishedAt: null
      }
    ' > "$child_receipt"
  chmod 0400 "$child_receipt"
  child_sha=$(sha256sum "$child_receipt" | cut -d ' ' -f 1)
  child_bytes=$(stat -c '%s' "$child_receipt")
  manifest_canonical=$(readlink -e "$child_candidate/etc/dotfiles/oci-images.json")
  manifest_sha=$(sha256sum "$manifest_canonical" | cut -d ' ' -f 1)
  manifest_bytes=$(stat -c '%s' "$manifest_canonical")

  for label in source candidate recovery-target previous-booted displaced-profile; do
    case $label in
      source) target=$child_source ;;
      candidate) target=$child_candidate ;;
      recovery-target) target=$candidate_target ;;
      previous-booted) target=$booted_target ;;
      displaced-profile) target=$candidate_target ;;
    esac
    ln -s "$target" "$rebuild_root/roots/$child_id/$label"
    ln -s "$rebuild_root/roots/$child_id/$label" \
      "$(auto_registration_for "$rebuild_root/roots/$child_id/$label")"
  done

  parent_metadata=$(jq -cn \
    --arg path "lineage/$parent_id/verification-failed.json" \
    --arg sha256 "$parent_artifact_sha" --argjson bytes "$parent_artifact_bytes" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')
  preparation_metadata=$(jq -cn \
    --arg path "successor-preparations/$parent_id-$child_id.json" \
    --arg sha256 "$child_sha" --argjson bytes "$child_bytes" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')
  jq -n \
    --arg parentId "$parent_id" --arg parentCandidate "$candidate_target" \
    --arg childId "$child_id" --arg childSource "$child_source" \
    --arg childCandidate "$child_candidate" \
    --argjson parentReceipt "$parent_metadata" \
    --argjson preparation "$preparation_metadata" \
    --argjson rebuildHelper "$rebuild_metadata" \
    --argjson syncHelper "$sync_metadata" \
    --argjson doctorHelper "$doctor_metadata" \
    --argjson manifest "$manifest_metadata" \
    --arg recovery "$candidate_target" --arg booted "$booted_target" '
      {
        schemaVersion: 2,
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
        activationBaseline: {current: $recovery, booted: $booted, profile: $recovery},
        roots: {
          source: $childSource,
          candidate: $childCandidate,
          "recovery-target": $recovery,
          "previous-booted": $booted,
          "displaced-profile": $recovery
        },
        createdAt: "2026-07-19T00:02:00Z"
      }
    ' > "$rebuild_root/successors/$parent_id.json"
  chmod 0400 "$rebuild_root/successors/$parent_id.json"
}

rewrite_immutable_json() {
  local target=$1 filter=$2 temporary
  shift 2
  temporary=$target.replacement
  jq "$@" "$filter" "$target" > "$temporary"
  chmod 0400 "$temporary"
  mv -T -- "$temporary" "$target"
}

restore_immutable_file() {
  local source=$1 target=$2 temporary
  temporary=$target.replacement
  cp -- "$source" "$temporary"
  chmod 0400 "$temporary"
  mv -T -- "$temporary" "$target"
}

assert_invalid_successor_authorization() {
  run_sync
  [[ $sync_status -eq 2 ]]
  [[ ! -e $state_root && ! -L $state_root ]]
  grep -Fqx 'FATAL: forward recovery protocol state is invalid' "$stderr_log"
}

reset_fixture
run_sync --status
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'MISSING: image-a has no sync receipt' "$stdout_log"
grep -Fqx 'MISSING: image-b has no sync receipt' "$stdout_log"

mkdir -m 0700 "$state_root"
run_sync --status
[[ $sync_status -eq 2 ]]
[[ ! -e $state_root/receipts && ! -L $state_root/receipts ]]
[[ ! -e $state_root/operation.lock && ! -L $state_root/operation.lock ]]
grep -Fqx "FATAL: OCI image sync state root is invalid: $state_root" "$stderr_log"
reset_fixture

run_sync
[[ $sync_status -eq 0 ]]
[[ $(wc -l < "$docker_log") -eq 2 ]]
grep -Fqx "$image_a" "$docker_log"
grep -Fqx "$image_b" "$docker_log"
[[ ! -e $state_root/receipts/agentmemory.json ]]
jq -e '.status == "succeeded" and (.localImageId | startswith("sha256:"))' \
  "$state_root/receipts/image-a.json" >/dev/null
jq -e '.status == "succeeded" and (.localImageId | startswith("sha256:"))' \
  "$state_root/receipts/image-b.json" >/dev/null

: > "$docker_log"
run_sync
[[ $sync_status -eq 0 ]]
[[ ! -s $docker_log ]]
grep -Fqx 'OK: image-a exact digest was already present' <(sed -E 's/ \(sha256:[0-9a-f]{64}\)$//' "$stdout_log")

run_sync --status
[[ $sync_status -eq 0 ]]
grep -Eq '^OK: image-a is synchronized as sha256:[0-9a-f]{64}$' "$stdout_log"
grep -Eq '^OK: image-b is synchronized as sha256:[0-9a-f]{64}$' "$stdout_log"

chmod 0644 "$state_root/receipts/image-a.json"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: invalid OCI image receipt: $state_root/receipts/image-a.json" "$stderr_log"
chmod 0600 "$state_root/receipts/image-a.json"

ln "$state_root/receipts/image-a.json" "$state_root/receipts/image-a.hardlink"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: invalid OCI image receipt: $state_root/receipts/image-a.json" "$stderr_log"
rm -- "$state_root/receipts/image-a.hardlink"

receipt_hash=$(sha256sum "$state_root/receipts/image-a.json")
temporary=$(mktemp "${docker_state}.XXXXXX")
jq --arg image "$image_a" 'del(.[$image])' "$docker_state" > "$temporary"
mv -T -- "$temporary" "$docker_state"
TEST_DOCKER_WAIT_IMAGE=$image_a
export TEST_DOCKER_WAIT_IMAGE
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log" &
sync_pid=$!
for _ in $(seq 1 500); do
  [[ -e $TEST_DOCKER_READY ]] && break
  kill -0 "$sync_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -e $TEST_DOCKER_READY ]]
chmod 0500 "$state_root/receipts"
: > "$TEST_DOCKER_RELEASE"
set +e
wait "$sync_pid"
publish_status=$?
set -e
sync_pid=
[[ $publish_status -eq 2 ]]
grep -Fqx 'FATAL: failed to persist OCI image success receipt: image-a' "$stderr_log"
chmod 0700 "$state_root/receipts"
[[ $(sha256sum "$state_root/receipts/image-a.json") == "$receipt_hash" ]]
TEST_DOCKER_WAIT_IMAGE=
export TEST_DOCKER_WAIT_IMAGE

reset_fixture
TEST_DOCKER_FAIL_IMAGE=$image_a
export TEST_DOCKER_FAIL_IMAGE
run_sync
[[ $sync_status -eq 1 ]]
[[ $(wc -l < "$docker_log") -eq 2 ]]
jq -e '.status == "failed" and .localImageId == null and .message == "docker pull failed"' \
  "$state_root/receipts/image-a.json" >/dev/null
jq -e '.status == "succeeded"' "$state_root/receipts/image-b.json" >/dev/null

reset_fixture
TEST_DOCKER_DIGEST_MISMATCH_IMAGE=$image_a
export TEST_DOCKER_DIGEST_MISMATCH_IMAGE
run_sync
[[ $sync_status -eq 1 ]]
jq -e '
  .status == "failed" and
  .message == "pulled image does not expose the locked RepoDigest"
' "$state_root/receipts/image-a.json" >/dev/null
jq -e '.status == "succeeded"' "$state_root/receipts/image-b.json" >/dev/null

reset_fixture
mkdir -m 0700 "$test_root/real-state"
ln -s "$test_root/real-state" "$state_root"
run_sync
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: OCI image sync state root is invalid: $state_root" "$stderr_log"
rm -- "$state_root"
rm -r -- "$test_root/real-state"

reset_fixture
run_sync
[[ $sync_status -eq 0 ]]
receipt_target=$test_root/receipt-target.json
cp -- "$state_root/receipts/image-a.json" "$receipt_target"
rm -- "$state_root/receipts/image-a.json"
ln -s "$receipt_target" "$state_root/receipts/image-a.json"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: invalid OCI image receipt: $state_root/receipts/image-a.json" "$stderr_log"
run_sync
[[ $sync_status -eq 2 ]]
[[ -L $state_root/receipts/image-a.json ]]
grep -Fqx "FATAL: invalid OCI image receipt: $state_root/receipts/image-a.json" "$stderr_log"

reset_fixture
mkdir -m 0700 "$state_root" "$state_root/receipts"
lock_target=$test_root/lock-target
: > "$lock_target"
ln -s "$lock_target" "$state_root/operation.lock"
run_sync
[[ $sync_status -eq 2 ]]
[[ -L $state_root/operation.lock ]]
grep -Fqx "FATAL: OCI image sync state lock is invalid: $state_root" "$stderr_log"

reset_fixture
mkdir -m 0700 "$state_root" "$state_root/receipts"
: > "$state_root/operation.lock"
chmod 0600 "$state_root/operation.lock"
ln "$state_root/operation.lock" "$state_root/operation.hardlink"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: OCI image sync state lock is invalid: $state_root" "$stderr_log"
rm -- "$state_root/operation.hardlink"
chmod 0644 "$state_root/operation.lock"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: OCI image sync state lock is invalid: $state_root" "$stderr_log"

reset_fixture
TEST_DOCKER_WAIT_IMAGE=$image_a
export TEST_DOCKER_WAIT_IMAGE
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log" &
sync_pid=$!
for _ in $(seq 1 500); do
  [[ -e $TEST_DOCKER_READY ]] && break
  kill -0 "$sync_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -e $TEST_DOCKER_READY ]]
second_stdout=$test_root/second.stdout
second_stderr=$test_root/second.stderr
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" --status > "$second_stdout" 2> "$second_stderr"
second_status=$?
set -e
[[ $second_status -eq 1 ]]
grep -Fqx 'FATAL: another OCI image sync is running' "$second_stderr"
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$second_stdout" 2> "$second_stderr"
second_sync_status=$?
set -e
[[ $second_sync_status -eq 1 ]]
grep -Fqx 'FATAL: failed to acquire the dotfiles operation lock' "$second_stderr"
: > "$TEST_DOCKER_RELEASE"
wait "$sync_pid"
sync_pid=

reset_fixture
mkdir -m 0700 \
  "$git_common_dir/dotfiles-rebuild" \
  "$git_common_dir/dotfiles-rebuild/receipts" \
  "$git_common_dir/dotfiles-rebuild/roots"
: > "$git_common_dir/dotfiles-rebuild/active.json"
run_sync
[[ $sync_status -eq 2 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: the active rebuild receipt is invalid' "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-rebuild"

# active rebuild 中は、receipt に束縛された candidate または recovery target だけを同期できる。
unrelated_manifest=$test_root/unrelated-oci-images.json
cp -- "$manifest" "$unrelated_manifest"
rm "$candidate_target/etc/dotfiles/oci-images.json" "$recovery_target/etc/dotfiles/oci-images.json"
ln -s "$unrelated_manifest" "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$unrelated_manifest" "$recovery_target/etc/dotfiles/oci-images.json"
write_active_rebuild_receipt prepared
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: active rebuild target does not match this OCI image manifest' "$stderr_log"

# verification-failed parent が exact authorization で束縛した successor manifest は同期できる。
reset_fixture
rm -r -- "$git_common_dir/dotfiles-rebuild"
write_authorized_successor_fixture
run_sync
[[ $sync_status -eq 0 ]]
grep -Fqx 'OK: image-a exact digest synchronized' \
  <(sed -E 's/ \(sha256:[0-9a-f]{64}\)$//' "$stdout_log")
reset_fixture
authorization="$git_common_dir/dotfiles-rebuild/successors/11111111111111111111111111111111.json"
authorization_exact=$test_root/authorization.exact.json
cp -- "$authorization" "$authorization_exact"
chmod 0400 "$authorization_exact"

# write-once erasureが見えた時点でlive authorizationは失効し、OCI stateを作らない。
erasure_parent_id=11111111111111111111111111111111
erasure_child_id=22222222222222222222222222222222
erasure_preparation=$git_common_dir/dotfiles-rebuild/successor-preparations/$erasure_parent_id-$erasure_child_id.json
erasure_file=$git_common_dir/dotfiles-rebuild/successor-erasures/$erasure_parent_id-$erasure_child_id.json
erasure_roots=$git_common_dir/dotfiles-rebuild/roots/$erasure_child_id
erasure_observed_roots='{}'
erasure_observed_auto='[]'
for erasure_label in source candidate recovery-target previous-booted displaced-profile; do
  erasure_root=$erasure_roots/$erasure_label
  erasure_target=$(readlink -f "$erasure_root")
  erasure_auto=$(auto_registration_for "$erasure_root")
  erasure_observed_roots=$(jq -c --arg label "$erasure_label" \
    --arg path "$erasure_root" --arg target "$erasure_target" \
    --arg metadata "$(stat -c '%u|%g|%a|%h' "$erasure_root")" \
    '. + {($label): {path: $path, target: $target, metadata: $metadata}}' \
    <<< "$erasure_observed_roots")
  erasure_observed_auto=$(jq -c --arg label "$erasure_label" \
    --arg path "$erasure_auto" --arg literalTarget "$erasure_root" \
    --arg metadata "$(stat -c '%u|%g|%a|%h' "$erasure_auto")" \
    '. + [{label: $label, path: $path, literalTarget: $literalTarget, metadata: $metadata}]' \
    <<< "$erasure_observed_auto")
done
jq -n --arg parentId "$erasure_parent_id" --arg childId "$erasure_child_id" \
  --argjson preparation "$(jq -cn \
    --arg path "successor-preparations/$erasure_parent_id-$erasure_child_id.json" \
    --arg sha256 "$(sha256sum "$erasure_preparation" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$erasure_preparation")" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')" \
  --argjson authorization "$(jq -cn --arg path "successors/$erasure_parent_id.json" \
    --arg sha256 "$(sha256sum "$authorization" | cut -d ' ' -f 1)" \
    --argjson bytes "$(stat -c '%s' "$authorization")" \
    '{path: $path, sha256: $sha256, bytes: $bytes}')" \
  --argjson parentReceipt "$(jq -c '.lineage.parentReceipt' "$erasure_preparation")" \
  --argjson desiredRoots "$(jq -c '.roots' "$authorization")" \
  --argjson observedRoots "$erasure_observed_roots" \
  --argjson observedAutoRoots "$erasure_observed_auto" '
    {
      schemaVersion: 2,
      kind: "successor-erasure",
      parentTransactionId: $parentId,
      childTransactionId: $childId,
      reason: "cancel-requested",
      keepRoots: false,
      preparation: $preparation,
      authorization: $authorization,
      parentReceipt: $parentReceipt,
      desiredRoots: $desiredRoots,
      observedRoots: $observedRoots,
      observedRootTemps: [],
      observedAutoRoots: ($observedAutoRoots | sort_by(.label)),
      observedAutoRootTemps: [],
      createdAt: "2026-07-19T00:02:00Z"
    }
  ' > "$erasure_file"
chmod 0400 "$erasure_file"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: an erasing forward recovery blocks OCI image synchronization' "$stderr_log"
rm -- "$erasure_file"

# parent bytes、manifest bytes、persistent roots のいずれかが変われば認可を失う。
authorized_parent_intent=$git_common_dir/dotfiles-rebuild/attempts/11111111111111111111111111111111/1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/intent.json
mv -T -- "$authorized_parent_intent" "$authorized_parent_intent.absent"
run_sync
[[ $sync_status -eq 2 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: the active rebuild activation journal is invalid' "$stderr_log"
mv -T -- "$authorized_parent_intent.absent" "$authorized_parent_intent"

printf '\n' >> "$authorized_parent_intent"
run_sync
[[ $sync_status -eq 2 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: the active rebuild activation journal is invalid' "$stderr_log"
sed -i '$d' "$authorized_parent_intent"

rewrite_immutable_json "$authorization" \
  '.parent.receipt.sha256 = ("f" * 64)'
assert_invalid_successor_authorization
restore_immutable_file "$authorization_exact" "$authorization"

rewrite_immutable_json "$authorization" \
  '.createdAt = "2999-01-01T00:00:00Z"'
assert_invalid_successor_authorization
restore_immutable_file "$authorization_exact" "$authorization"

for authorized_helper_role in syncImages doctor; do
  for authorized_helper_field in logicalPath sha256 bytes; do
    case $authorized_helper_field in
      logicalPath)
        helper_filter='.child.helpers[$role].logicalPath = (.child.candidate + "/sw/bin/forged")'
        ;;
      sha256)
        helper_filter='.child.helpers[$role].sha256 = ("d" * 64)'
        ;;
      bytes)
        helper_filter='.child.helpers[$role].bytes += 1'
        ;;
    esac
    rewrite_immutable_json "$authorization" "$helper_filter" \
      --arg role "$authorized_helper_role"
    assert_invalid_successor_authorization
    restore_immutable_file "$authorization_exact" "$authorization"
  done
done

rewrite_immutable_json "$authorization" '.roots.unexpected = .roots.candidate'
assert_invalid_successor_authorization
restore_immutable_file "$authorization_exact" "$authorization"

authorized_candidate_auto_root=$(auto_registration_for \
  "$git_common_dir/dotfiles-rebuild/roots/22222222222222222222222222222222/candidate")
rm -- "$authorized_candidate_auto_root"
assert_invalid_successor_authorization
ln -s \
  "$git_common_dir/dotfiles-rebuild/roots/22222222222222222222222222222222/candidate" \
  "$authorized_candidate_auto_root"

authorized_manifest=$manifest
outside_authorized_manifest=$test_root/outside-authorized-oci-images.json
cp -- "$authorized_manifest" "$outside_authorized_manifest"
rm -- "$nix_store_dir/successor-system/etc/dotfiles/oci-images.json"
ln -s "$outside_authorized_manifest" \
  "$nix_store_dir/successor-system/etc/dotfiles/oci-images.json"
manifest=$outside_authorized_manifest
TEST_DOCKER_MANIFEST=$manifest
export TEST_DOCKER_MANIFEST
rewrite_immutable_json "$authorization" \
  '.child.manifest.canonicalPath = $canonical' \
  --arg canonical "$outside_authorized_manifest"
assert_invalid_successor_authorization
manifest=$authorized_manifest
TEST_DOCKER_MANIFEST=$manifest
export TEST_DOCKER_MANIFEST
rm -- "$nix_store_dir/successor-system/etc/dotfiles/oci-images.json"
ln -s "$authorized_manifest" \
  "$nix_store_dir/successor-system/etc/dotfiles/oci-images.json"
restore_immutable_file "$authorization_exact" "$authorization"

rewrite_immutable_json "$authorization" \
  '.child.manifest.sha256 = ("e" * 64)'
assert_invalid_successor_authorization
restore_immutable_file "$authorization_exact" "$authorization"

authorized_candidate_root="$git_common_dir/dotfiles-rebuild/roots/22222222222222222222222222222222/candidate"
rm -- "$authorized_candidate_root"
ln -s "$recovery_target" "$authorized_candidate_root"
assert_invalid_successor_authorization
rm -- "$authorized_candidate_root"
ln -s "$nix_store_dir/successor-system" "$authorized_candidate_root"

# immutable authorization/child のowner-independent file identityを崩せない。
chmod 0600 "$authorization"
assert_invalid_successor_authorization
chmod 0400 "$authorization"
authorization_hardlink=$test_root/authorization.hardlink.json
ln "$authorization" "$authorization_hardlink"
assert_invalid_successor_authorization
rm -- "$authorization_hardlink"
authorization_real=$test_root/authorization.real.json
mv -T -- "$authorization" "$authorization_real"
ln -s "$authorization_real" "$authorization"
assert_invalid_successor_authorization
rm -- "$authorization"
mv -T -- "$authorization_real" "$authorization"

prepared_child=$git_common_dir/dotfiles-rebuild/successor-preparations/11111111111111111111111111111111-22222222222222222222222222222222.json
chmod 0600 "$prepared_child"
assert_invalid_successor_authorization
chmod 0400 "$prepared_child"
prepared_child_hardlink=$test_root/child-prepared.hardlink.json
ln "$prepared_child" "$prepared_child_hardlink"
assert_invalid_successor_authorization
rm -- "$prepared_child_hardlink"
prepared_child_real=$test_root/child-prepared.real.json
mv -T -- "$prepared_child" "$prepared_child_real"
ln -s "$prepared_child_real" "$prepared_child"
assert_invalid_successor_authorization
rm -- "$prepared_child"
mv -T -- "$prepared_child_real" "$prepared_child"

# authorization が無ければ successor manifest は通常のtarget不一致として拒否する。
authorization_absent=$test_root/authorization.absent.json
mv -T -- "$authorization" "$authorization_absent"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: active rebuild target does not match this OCI image manifest' "$stderr_log"

# schema4 transaction はlineageまたはsupersessionのどちらかを必ず持つ。
active_rebuild=$git_common_dir/dotfiles-rebuild/active.json
active_rebuild_exact=$test_root/active-rebuild.exact.json
cp -- "$active_rebuild" "$active_rebuild_exact"
jq '.schemaVersion = 4 | .lineage = null | .supersession = null' \
  "$active_rebuild" > "$active_rebuild.replacement"
chmod 0600 "$active_rebuild.replacement"
mv -T -- "$active_rebuild.replacement" "$active_rebuild"
run_sync
[[ $sync_status -eq 2 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: the active rebuild receipt is invalid' "$stderr_log"
cp -- "$active_rebuild_exact" "$active_rebuild.replacement"
chmod 0600 "$active_rebuild.replacement"
mv -T -- "$active_rebuild.replacement" "$active_rebuild"
mv -T -- "$authorization_absent" "$authorization"

# SOPS enrollment に束縛された rebuild は marker 欠落時も同期を許可しない。
rm -r -- "$git_common_dir/dotfiles-rebuild"
write_active_rebuild_receipt prepared
jq '.sopsEnrollmentTransactionId = "fedcba9876543210fedcba9876543210"' \
  "$git_common_dir/dotfiles-rebuild/active.json" > "$test_root/bound-rebuild.json"
mv -T -- "$test_root/bound-rebuild.json" "$git_common_dir/dotfiles-rebuild/active.json"
chmod 0600 "$git_common_dir/dotfiles-rebuild/active.json"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: SOPS enrollment-bound rebuild blocks OCI image synchronization' "$stderr_log"

write_active_rebuild_receipt prepared
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: active rebuild target does not match this OCI image manifest' "$stderr_log"

rm "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$candidate_target/etc/dotfiles/oci-images.json"
run_sync
[[ $sync_status -eq 0 ]]
grep -Fqx 'OK: image-a exact digest synchronized' \
  <(sed -E 's/ \(sha256:[0-9a-f]{64}\)$//' "$stdout_log")

reset_fixture
rm "$candidate_target/etc/dotfiles/oci-images.json" "$recovery_target/etc/dotfiles/oci-images.json"
ln -s "$unrelated_manifest" "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$recovery_target/etc/dotfiles/oci-images.json"
write_active_rebuild_receipt activation-failed
run_sync
[[ $sync_status -eq 0 ]]

reset_fixture
rm -r -- "$git_common_dir/dotfiles-rebuild"
rm "$candidate_target/etc/dotfiles/oci-images.json" "$recovery_target/etc/dotfiles/oci-images.json"
ln -s "$unrelated_manifest" "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$recovery_target/etc/dotfiles/oci-images.json"
write_active_rebuild_receipt complete
run_sync
[[ $sync_status -eq 0 ]]

reset_fixture
rm -r -- "$git_common_dir/dotfiles-rebuild"
rm "$candidate_target/etc/dotfiles/oci-images.json" "$recovery_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$unrelated_manifest" "$recovery_target/etc/dotfiles/oci-images.json"
write_active_rebuild_receipt complete
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx \
  'FATAL: a complete rebuild receipt only permits recovery target OCI image synchronization' \
  "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-rebuild"

# cancelled/superseded はterminal receiptであり、targetが一致しても新しいOCI stateを
# 作らない。同期可能なterminal routeはcompleteのrecovery targetだけに限定する。
rm "$candidate_target/etc/dotfiles/oci-images.json"
ln -s "$manifest" "$candidate_target/etc/dotfiles/oci-images.json"
write_cancelled_rebuild_receipt
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx \
  'FATAL: a terminal rebuild receipt blocks OCI image synchronization until it is archived' \
  "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-rebuild"

write_authorized_successor_fixture
superseded_parent=$git_common_dir/dotfiles-rebuild/active.json
superseded_child=$git_common_dir/dotfiles-rebuild/successor-preparations/11111111111111111111111111111111-22222222222222222222222222222222.json
superseded_child_id=$(jq -r '.transactionId' "$superseded_child")
superseded_child_archive=$git_common_dir/dotfiles-rebuild/receipts/$superseded_child_id.json
cp -- "$superseded_child" "$superseded_child_archive"
chmod 0600 "$superseded_child_archive"
jq \
  --arg childId "$superseded_child_id" \
  --arg childSource "$(jq -r '.source' "$superseded_child")" \
  --arg childCandidate "$(jq -r '.candidate' "$superseded_child")" \
  --argjson originalReceipt "$(jq -c '.lineage.parentReceipt' "$superseded_child")" \
  --arg createdAt "$(jq -r '.lineage.createdAt' "$superseded_child")" '
    .schemaVersion = 4 |
    .state = "superseded" |
    .supersession = {
      kind: "verification-successor",
      fromState: "verification-failed",
      successorTransactionId: $childId,
      successorSource: $childSource,
      successorCandidate: $childCandidate,
      originalReceipt: $originalReceipt,
      createdAt: $createdAt
    } |
    .lineage = null |
    .updatedAt = $createdAt |
    .finishedAt = $createdAt
  ' "$superseded_parent" > "$superseded_parent.tmp"
mv -T -- "$superseded_parent.tmp" "$superseded_parent"
chmod 0600 "$superseded_parent"
rm -- "$git_common_dir/dotfiles-rebuild/successors/11111111111111111111111111111111.json"
rm -- "$superseded_child"
rm -r -- "$git_common_dir/dotfiles-rebuild/roots/$superseded_child_id"
for superseded_auto in "$nix_gc_auto_roots_dir"/*; do
  [[ -e $superseded_auto || -L $superseded_auto ]] || continue
  rm -- "$superseded_auto"
done
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx \
  'FATAL: a terminal rebuild receipt blocks OCI image synchronization until it is archived' \
  "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-rebuild"

mkdir -m 0700 "$git_common_dir/dotfiles-sops-enroll"
: > "$git_common_dir/dotfiles-sops-enroll/active.json"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: an active SOPS enrollment transaction blocks OCI image synchronization' "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-sops-enroll"

jq '.schemaVersion = 1' "$manifest" > "$test_root/schema-v1-manifest.json"
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$test_root/schema-v1-manifest.json \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log"
schema_v1_status=$?
set -e
[[ $schema_v1_status -eq 2 ]]
grep -Fqx 'FATAL: OCI image manifest does not match schema version 2' "$stderr_log"

printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$test_root/invalid-manifest.json"
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$test_root/invalid-manifest.json \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log"
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]]
grep -Fqx 'FATAL: OCI image manifest does not match schema version 2' "$stderr_log"

jq '(.images[] | select(.id == "image-a").repository) = "example.test/other"' \
  "$manifest" > "$test_root/mismatched-repository.json"
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$test_root/mismatched-repository.json \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log"
mismatched_status=$?
set -e
[[ $mismatched_status -eq 2 ]]
grep -Fqx 'FATAL: OCI image manifest does not match schema version 2' "$stderr_log"

jq --arg image "example.test/a:latest@unexpected@$digest_a" \
  '(.images[] | select(.id == "image-a").image) = $image' \
  "$manifest" > "$test_root/noncanonical-image.json"
set +e
DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$test_root/noncanonical-image.json \
  DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
  DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
  DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
  "$sync_images" > "$stdout_log" 2> "$stderr_log"
noncanonical_status=$?
set -e
[[ $noncanonical_status -eq 2 ]]
grep -Fqx 'FATAL: OCI image manifest does not match schema version 2' "$stderr_log"
