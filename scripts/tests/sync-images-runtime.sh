#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 SYNC_IMAGES_COMMAND" >&2
  exit 2
fi

sync_images=$1
test_root=$(mktemp -d)
state_root=$test_root/state
git_common_dir=$test_root/git-common
docker_state=$test_root/docker-state.json
docker_log=$test_root/docker.log
manifest=$test_root/oci-images.json
stdout_log=$test_root/stdout.log
stderr_log=$test_root/stderr.log
fake_docker=$test_root/docker
sync_pid=
mkdir -m 0700 "$git_common_dir"

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

jq -n \
  --arg digestA "$digest_a" \
  --arg digestB "$digest_b" \
  --arg imageA "$image_a" \
  --arg imageB "$image_b" '
    {
      schemaVersion: 1,
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
  set +e
  DOTFILES_IMAGE_SYNC_TEST_MANIFEST=$manifest \
    DOTFILES_IMAGE_SYNC_TEST_STATE_ROOT=$state_root \
    DOTFILES_IMAGE_SYNC_TEST_DOCKER=$fake_docker \
    DOTFILES_IMAGE_SYNC_TEST_GIT_COMMON_DIR=$git_common_dir \
    "$sync_images" "$@" > "$stdout_log" 2> "$stderr_log"
  sync_status=$?
  set -e
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
grep -Fqx "FATAL: OCI image sync lock is invalid: $state_root/operation.lock" "$stderr_log"

reset_fixture
mkdir -m 0700 "$state_root" "$state_root/receipts"
: > "$state_root/operation.lock"
chmod 0600 "$state_root/operation.lock"
ln "$state_root/operation.lock" "$state_root/operation.hardlink"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: OCI image sync lock is invalid: $state_root/operation.lock" "$stderr_log"
rm -- "$state_root/operation.hardlink"
chmod 0644 "$state_root/operation.lock"
run_sync --status
[[ $sync_status -eq 2 ]]
grep -Fqx "FATAL: OCI image sync lock is invalid: $state_root/operation.lock" "$stderr_log"

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
mkdir -m 0700 "$git_common_dir/dotfiles-rebuild"
: > "$git_common_dir/dotfiles-rebuild/active.json"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: an active rebuild transaction blocks OCI image synchronization' "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-rebuild"

mkdir -m 0700 "$git_common_dir/dotfiles-sops-enroll"
: > "$git_common_dir/dotfiles-sops-enroll/active.json"
run_sync
[[ $sync_status -eq 1 ]]
[[ ! -e $state_root && ! -L $state_root ]]
grep -Fqx 'FATAL: an active SOPS enrollment transaction blocks OCI image synchronization' "$stderr_log"
rm -r -- "$git_common_dir/dotfiles-sops-enroll"

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
grep -Fqx 'FATAL: OCI image manifest does not match schema version 1' "$stderr_log"

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
grep -Fqx 'FATAL: OCI image manifest does not match schema version 1' "$stderr_log"

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
grep -Fqx 'FATAL: OCI image manifest does not match schema version 1' "$stderr_log"
