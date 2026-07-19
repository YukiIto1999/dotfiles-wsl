#!/usr/bin/env bash
set -euo pipefail

rebuild_source=${1:?rebuild source path is required}
bash_path=${2:?bash path is required}
fakeroot_path=${3:?fakeroot path is required}
operation_lock_source=${4:?operation lock source path is required}
receipt_source=${5:?rebuild receipt source path is required}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

repo=$test_root/dotfiles-wsl
fake_bin=$test_root/fake-bin
call_log=$test_root/calls.log
stdout_log=$test_root/stdout.log
stderr_log=$test_root/stderr.log
sync_count=$test_root/sync-count
store_dir=$test_root/nix/store
nix_gc_auto_roots=$test_root/nix/var/nix/gcroots/auto
source_path=$store_dir/test-dotfiles-source
candidate=$test_root/nix/store/test-system
previous=$store_dir/previous-system
displaced_profile=$store_dir/displaced-profile
json_doctor_template=$test_root/doctor-json-template
v3_doctor_fixture=$test_root/doctor-v3
v2_doctor_fixture=$test_root/doctor-v2
rebuild=$test_root/dotfiles-rebuild
boot_id_file=$test_root/boot-id
current_state=$test_root/current-system
booted_state=$test_root/booted-system
profile_state=$test_root/profile-system
test_user=$(id -un)
real_readlink=$(command -v readlink)

mkdir -p \
  "$repo/.git" "$fake_bin" "$candidate/sw/bin" "$candidate/etc/dotfiles" "$source_path" \
  "$previous/sw/bin" "$previous/etc/dotfiles" "$displaced_profile" "$nix_gc_auto_roots"
sed "s|@dotfilesDir@|$repo|g" "$rebuild_source" \
  | sed "s|@nixStoreDir@|$store_dir|g" \
  | sed "s|@nixGcAutoRootDir@|$nix_gc_auto_roots|g" \
  | sed "s|@nixosRebuild@|$fake_bin/system-activator|g" \
  | sed "s|@username@|$test_user|g" \
  | sed "s|@bootIdFile@|$boot_id_file|g" \
  | sed "/@operationLockFunctions@/ { r $operation_lock_source
    d
  }" \
  | sed "/@rebuildReceiptFunctions@/ { r $receipt_source
    d
  }" > "$rebuild"
chmod +x "$rebuild"
cp -- "$rebuild" "$candidate/sw/bin/dotfiles-rebuild"
chmod +x "$candidate/sw/bin/dotfiles-rebuild"
printf '%s\n' '11111111-1111-1111-1111-111111111111' > "$boot_id_file"
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"

cat > "$fake_bin/command-stub" <<'STUB'
#!@bash@
set -euo pipefail

name=${0##*/}
printf -v call '%s' "$name"
for argument in "$@"; do
  printf -v quoted ' %q' "$argument"
  call+=$quoted
done
printf '%s\n' "$call" >> "$CALL_LOG"

case "${TEST_FAIL_AT:-}:$name:${1:-}:${2:-}" in
  snapshot:nix:build:* | check:nix:flake:check | build:nix:build:* | nvd:nvd:* | helper:dotfiles-wsl-restart-required:*)
    exit 70
    ;;
  activation:system-activator:*:* | activation:nixos-rebuild:*:* | activation:sudo:*:*)
    exit 71
    ;;
esac

sync_should_fail=0
if [[ $name == sync ]]; then
  if [[ -n ${TEST_SYNC_FAIL_EXACT:-} && $* == "$TEST_SYNC_FAIL_EXACT" ]]; then
    sync_should_fail=1
  elif [[ -n ${TEST_SYNC_FAIL_MATCH:-} && $* == *"$TEST_SYNC_FAIL_MATCH"* ]]; then
    sync_should_fail=1
  fi
  if [[ -n ${TEST_RUNTIME_AFTER_APPLY_INTENT:-} && ${1:-} == --data &&
    ${2:-} == */dotfiles-rebuild/active.json && -f ${2:-} &&
    $(jq -r '.state' "$2") == apply-intent && ! -e $TEST_RUNTIME_DRIFT_MARKER ]]; then
    printf '%s\n' "$TEST_RUNTIME_AFTER_APPLY_INTENT" > "$TEST_CURRENT_STATE"
    printf '%s\n' "$TEST_RUNTIME_AFTER_APPLY_INTENT" > "$TEST_PROFILE_STATE"
    : > "$TEST_RUNTIME_DRIFT_MARKER"
  fi
  if [[ -n ${TEST_RUNTIME_AFTER_ROLLBACK_INTENT:-} && ${1:-} == --data &&
    ${2:-} == */dotfiles-rebuild/active.json && -f ${2:-} &&
    $(jq -r '.state' "$2") == rollback-intent && ! -e $TEST_RUNTIME_DRIFT_MARKER ]]; then
    printf '%s\n' "$TEST_RUNTIME_AFTER_ROLLBACK_INTENT" > "$TEST_CURRENT_STATE"
    printf '%s\n' "$TEST_RUNTIME_AFTER_ROLLBACK_INTENT" > "$TEST_PROFILE_STATE"
    : > "$TEST_RUNTIME_DRIFT_MARKER"
  fi
fi
if [[ $sync_should_fail -eq 1 ]]; then
  count=0
  [[ ! -s $TEST_SYNC_COUNT_FILE ]] || count=$(<"$TEST_SYNC_COUNT_FILE")
  (( count += 1 ))
  printf '%s\n' "$count" > "$TEST_SYNC_COUNT_FILE"
  if [[ $count -eq ${TEST_SYNC_FAIL_AFTER:-1} ]]; then
    exit 70
  fi
fi

case $name in
  git)
    if [[ ${1:-} == -C && ${3:-} == rev-parse ]]; then
      printf '%s\n' "$TEST_COMMON_GIT_DIR"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --name-only ]]; then
      printf '%s' "${TEST_CHANGED_PATHS:-}"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --cached ]]; then
      exit "${TEST_STAGED_STATUS:-0}"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --check ]]; then
      exit "${TEST_DIFF_CHECK_STATUS:-0}"
    else
      printf '%s' "${TEST_UNTRACKED:-}"
    fi
    ;;
  nix)
    case "${1:-} ${2:-}" in
      "flake check") ;;
      "build --out-link")
        if [[ ${*: -1} == *'#sourceSnapshot' ]]; then
          ln -sfn -- "$TEST_SOURCE_PATH" "$3"
          printf '%s\n' "$TEST_SOURCE_PATH"
        else
          ln -sfn -- "$TEST_CANDIDATE" "$3"
          printf '%s\n' "$TEST_CANDIDATE"
        fi
        ;;
      *) exit 64 ;;
    esac
    ;;
  nom)
    cat > /dev/null
    ;;
  nvd)
    ;;
  dotfiles-wsl-restart-required)
    if [[ ${1:-} == --default-user ]]; then
      if [[ ${2:-} == "$TEST_CANDIDATE" ]]; then
        printf '%s\n' "$TEST_CANDIDATE_USER"
      else
        printf '%s\n' "$TEST_PREVIOUS_USER"
      fi
    else
      printf '%s\n' "$TEST_EFFECT"
      if [[ -n ${TEST_RUNTIME_AFTER_PLAN:-} ]]; then
        printf '%s\n' "$TEST_RUNTIME_AFTER_PLAN" > "$TEST_CURRENT_STATE"
      fi
    fi
    ;;
  system-activator | nixos-rebuild | sudo)
    action=${1:?}
    while (( $# > 0 )); do
      if [[ $1 == --store-path ]]; then
        target=$2
        break
      fi
      shift
    done
    case $action in
      switch)
        printf '%s\n' "$target" > "$TEST_CURRENT_STATE"
        printf '%s\n' "$target" > "$TEST_PROFILE_STATE"
        ;;
      boot)
        printf '%s\n' "$target" > "$TEST_PROFILE_STATE"
        ;;
    esac
    ;;
  nix-store)
    [[ ${1:-} == --add-root && ${3:-} == --realise ]]
    mkdir -p -- "$(dirname -- "$2")"
    ln -sfn -- "$4" "$2"
    auto_name=$(printf '%s' "$2" | sha256sum | cut -d ' ' -f 1)
    ln -sfn -- "$2" "$TEST_NIX_AUTO_ROOTS_DIR/$auto_name"
    if [[ -n ${TEST_RUNTIME_AFTER_PERSISTENT_ROOT:-} && $2 == */displaced-profile &&
      ! -e $TEST_RUNTIME_DRIFT_MARKER ]]; then
      printf '%s\n' "$TEST_RUNTIME_AFTER_PERSISTENT_ROOT" > "$TEST_CURRENT_STATE"
      printf '%s\n' "$TEST_RUNTIME_AFTER_PERSISTENT_ROOT" > "$TEST_PROFILE_STATE"
      : > "$TEST_RUNTIME_DRIFT_MARKER"
    fi
    ;;
  readlink)
    path=${!#}
    case $path in
      /run/current-system) cat "$TEST_CURRENT_STATE" ;;
      /run/booted-system) cat "$TEST_BOOTED_STATE" ;;
      /nix/var/nix/profiles/system) cat "$TEST_PROFILE_STATE" ;;
      *) "$REAL_READLINK" "$@" ;;
    esac
    ;;
  systemctl)
    printf '%s\n' "$TEST_BOOT_MONOTONIC"
    ;;
  sync)
    ;;
  *)
    exit 64
    ;;
esac
STUB
sed -i "1s|@bash@|$bash_path|" "$fake_bin/command-stub"
chmod +x "$fake_bin/command-stub"

for command in git nix nom nvd dotfiles-wsl-restart-required nixos-rebuild system-activator sudo nix-store readlink systemctl sync; do
  ln -s command-stub "$fake_bin/$command"
done

cat > "$json_doctor_template" <<'DOCTOR'
#!@bash@
set -euo pipefail
printf -v call 'dotfiles-doctor'
for argument in "$@"; do
  printf -v quoted ' %q' "$argument"
  call+=$quoted
done
printf '%s\n' "$call" >> "$CALL_LOG"
[[ $# -eq 2 && $1 == --format && $2 == json ]] || exit 2
doctor_status=${TEST_DOCTOR_STATUS:-0}
report_mode=${TEST_DOCTOR_REPORT:-valid}
if [[ $report_mode == invalid ]]; then
  printf '%s\n' 'not-json'
  exit "$doctor_status"
fi
case $doctor_status in
  0)
    report='{"schemaVersion":1,"manifestSchemaVersion":@manifestSchema@,"outcome":"healthy","summary":{"total":1,"pass":1,"warn":0,"fail":0,"error":0,"blocked":0},"checks":[{"id":"fixture.health","phase":"system","status":"pass","subject":"fixture","expected":"healthy","observed":"healthy","message":"fixture is healthy","durationMs":1}]}'
    ;;
  1)
    report='{"schemaVersion":1,"manifestSchemaVersion":@manifestSchema@,"outcome":"degraded","summary":{"total":2,"pass":0,"warn":0,"fail":1,"error":0,"blocked":1},"checks":[{"id":"systemd.fixture","phase":"system","status":"fail","subject":"fixture.service","expected":"active","observed":"failed","message":"fixture unit failed","durationMs":1},{"id":"mcp.fixture","phase":"active","status":"blocked","subject":"fixture-mcp","expected":"healthy unit","observed":"blocked","message":"fixture MCP probe was blocked","durationMs":0}]}'
    ;;
  2)
    report='{"schemaVersion":1,"manifestSchemaVersion":@manifestSchema@,"outcome":"invalid","summary":{"total":1,"pass":0,"warn":0,"fail":0,"error":1,"blocked":0},"checks":[{"id":"doctor.contract","phase":"foundation","status":"error","subject":"fixture-manifest","expected":"schema v@manifestSchema@","observed":"invalid","message":"fixture manifest is invalid","durationMs":0}]}'
    ;;
  *)
    report='{"schemaVersion":1,"manifestSchemaVersion":@manifestSchema@,"outcome":"degraded","summary":{"total":1,"pass":0,"warn":0,"fail":1,"error":0,"blocked":0},"checks":[{"id":"systemd.fixture","phase":"system","status":"fail","subject":"fixture.service","expected":"active","observed":"failed","message":"fixture unit failed","durationMs":1}]}'
    ;;
esac
case $report_mode in
  valid) printf '%s\n' "$report" ;;
  empty) printf '%s\n' '{"schemaVersion":1,"manifestSchemaVersion":@manifestSchema@,"outcome":"healthy","summary":{"total":0,"pass":0,"warn":0,"fail":0,"error":0,"blocked":0},"checks":[]}' ;;
  manifest-mismatch) printf '%s\n' "${report/\"manifestSchemaVersion\":@manifestSchema@/\"manifestSchemaVersion\":99}" ;;
  summary-mismatch) printf '%s\n' "${report/\"total\":2/\"total\":99}" ;;
  field-missing) printf '%s\n' "${report/\"phase\":\"system\",/}" ;;
  multiple) printf '%s\n%s\n' "$report" "$report" ;;
  *) exit 2 ;;
esac
exit "$doctor_status"
DOCTOR
sed -e "1s|@bash@|$bash_path|" -e 's|@manifestSchema@|4|g' \
  "$json_doctor_template" > "$candidate/sw/bin/dotfiles-doctor"
chmod +x "$candidate/sw/bin/dotfiles-doctor"
sed -e "1s|@bash@|$bash_path|" -e 's|@manifestSchema@|3|g' \
  "$json_doctor_template" > "$v3_doctor_fixture"
chmod +x "$v3_doctor_fixture"
cp -- "$candidate/sw/bin/dotfiles-doctor" "$previous/sw/bin/dotfiles-doctor"
printf '%s\n' '{"schemaVersion":4}' > "$candidate/etc/dotfiles/doctor.json"
printf '%s\n' '{"schemaVersion":4}' > "$previous/etc/dotfiles/doctor.json"

cat > "$v2_doctor_fixture" <<'DOCTOR'
#!@bash@
set -euo pipefail
printf -v call 'dotfiles-doctor'
for argument in "$@"; do
  printf -v quoted ' %q' "$argument"
  call+=$quoted
done
printf '%s\n' "$call" >> "$CALL_LOG"
[[ $# -eq 0 ]] || exit 2
doctor_status=${TEST_DOCTOR_STATUS:-0}
case $doctor_status in
  0) printf '%s\n' 'OK: legacy doctor fixture is healthy' ;;
  1) printf '%s\n' 'FAIL: legacy doctor fixture is degraded' >&2 ;;
  *) printf '%s\n' "FAIL: legacy doctor fixture returned status $doctor_status" >&2 ;;
esac
exit "$doctor_status"
DOCTOR
sed -i "1s|@bash@|$bash_path|" "$v2_doctor_fixture"
chmod +x "$v2_doctor_fixture"

export CALL_LOG=$call_log
export TEST_SOURCE_PATH=$source_path
export TEST_CANDIDATE=$candidate
export TEST_COMMON_GIT_DIR=$repo/.git
export TEST_CURRENT_STATE=$current_state
export TEST_BOOTED_STATE=$booted_state
export TEST_PROFILE_STATE=$profile_state
export TEST_NIX_AUTO_ROOTS_DIR=$nix_gc_auto_roots
export TEST_BOOT_MONOTONIC=100
export TEST_USER=$test_user
export TEST_CANDIDATE_USER=$test_user
export TEST_PREVIOUS_USER=$test_user
export TEST_RUNTIME_AFTER_PLAN=
export TEST_RUNTIME_AFTER_PERSISTENT_ROOT=
export TEST_RUNTIME_AFTER_APPLY_INTENT=
export TEST_RUNTIME_AFTER_ROLLBACK_INTENT=
export TEST_RUNTIME_DRIFT_MARKER=$test_root/runtime-drifted
export TEST_SYNC_FAIL_MATCH=
export TEST_SYNC_FAIL_EXACT=
export TEST_SYNC_FAIL_AFTER=1
export TEST_SYNC_COUNT_FILE=$sync_count
export REAL_READLINK=$real_readlink
export WSL_DISTRO_NAME=NixOS

run_rebuild() {
  : > "$call_log"
  : > "$stdout_log"
  : > "$stderr_log"
  : > "$sync_count"
  rm -f -- "$TEST_RUNTIME_DRIFT_MARKER"
  export TEST_EFFECT=$1
  export TEST_UNTRACKED=${2:-}
  export TEST_FAIL_AT=${3:-}
  export TEST_CHANGED_PATHS=${TEST_CHANGED_PATHS:-}
  export TEST_STAGED_STATUS=${TEST_STAGED_STATUS:-0}
  export TEST_DIFF_CHECK_STATUS=${TEST_DIFF_CHECK_STATUS:-0}
  export TEST_DOCTOR_STATUS=${TEST_DOCTOR_STATUS:-0}
  export TEST_RUNTIME_AFTER_PLAN=${TEST_RUNTIME_AFTER_PLAN:-}
  export TEST_RUNTIME_AFTER_PERSISTENT_ROOT=${TEST_RUNTIME_AFTER_PERSISTENT_ROOT:-}
  export TEST_RUNTIME_AFTER_APPLY_INTENT=${TEST_RUNTIME_AFTER_APPLY_INTENT:-}
  export TEST_RUNTIME_AFTER_ROLLBACK_INTENT=${TEST_RUNTIME_AFTER_ROLLBACK_INTENT:-}
  expected_pipeline_current=$(<"$current_state")
  expected_pipeline_booted=$(<"$booted_state")
  shift 3 || true

  set +e
  PATH="$fake_bin:$PATH" bash "$rebuild" "$@" > "$stdout_log" 2> "$stderr_log"
  rebuild_status=$?
  set -e
}

rewrite_receipt() {
  local receipt=$1 filter=$2 temporary
  shift 2
  temporary=$receipt.tmp
  jq "$@" "$filter" "$receipt" > "$temporary"
  mv -T -- "$temporary" "$receipt"
  chmod 0600 "$receipt"
}

require_call() {
  grep -F -- "$1" "$call_log" > /dev/null || {
    printf 'missing call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  }
}

require_exact_call() {
  grep -Fqx -- "$1" "$call_log" || {
    printf 'missing exact call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  }
}

reject_call() {
  if grep -F -- "$1" "$call_log" > /dev/null; then
    printf 'unexpected call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  fi
}

call_line() {
  grep -nF -- "$1" "$call_log" | head -n 1 | cut -d: -f1
}

auto_registration_for() {
  local root=$1 auto_name
  auto_name=$(printf '%s' "$root" | sha256sum | cut -d ' ' -f 1)
  printf '%s/%s\n' "$nix_gc_auto_roots" "$auto_name"
}

assert_before() {
  local earlier later
  earlier=$(call_line "$1")
  later=$(call_line "$2")
  [[ $earlier -lt $later ]] || {
    printf 'call order is invalid: %s must precede %s\n' "$1" "$2" >&2
    exit 1
  }
}

assert_snapshot_pipeline() {
  require_exact_call "git -C $repo rev-parse --path-format=absolute --git-common-dir"
  require_exact_call "git -C $repo ls-files --others --exclude-standard"
  require_call "nix build --out-link "
  require_call " --print-out-paths --no-write-lock-file git+file://$repo#sourceSnapshot"
  require_exact_call "nix flake check --no-write-lock-file --log-format internal-json -v path:$source_path"
  require_exact_call 'nom --json'
  require_call "nix build --out-link "
  require_call " --print-out-paths --no-write-lock-file path:$source_path#nixosConfigurations.nixos.config.system.build.toplevel"
  require_exact_call "nvd diff $expected_pipeline_current $candidate"
  require_exact_call "dotfiles-wsl-restart-required --plan --booted-system $expected_pipeline_booted --current-system $expected_pipeline_current $candidate"

  [[ $(grep -c "^nix build .*git+file://$repo#sourceSnapshot" "$call_log") -eq 1 ]]
  [[ $(grep -c "^nix flake check .*path:$source_path" "$call_log") -eq 1 ]]
  [[ $(grep -c "^nix build .*path:$source_path#nixosConfigurations" "$call_log") -eq 1 ]]

  assert_before "git -C $repo rev-parse" "git -C $repo ls-files"
  assert_before "git -C $repo ls-files" "git+file://$repo#sourceSnapshot"
  assert_before "git+file://$repo#sourceSnapshot" 'nix flake check'
  assert_before 'nix flake check' "path:$source_path#nixosConfigurations"
  assert_before "path:$source_path#nixosConfigurations" 'nvd diff'
  assert_before 'nvd diff' 'dotfiles-wsl-restart-required'
}

assert_apply() {
  local action=$1
  local target=${2:-$candidate}
  require_exact_call "system-activator $action --sudo --no-reexec --store-path $target -L"
  [[ $(grep -c '^system-activator ' "$call_log") -eq 1 ]]
  reject_call 'nixos-rebuild'
  reject_call 'sudo nixos-rebuild'
}

require_instruction() {
  grep -F -- "$1" "$stdout_log" > /dev/null || {
    printf 'missing instruction: %s\n' "$1" >&2
    exit 1
  }
}

require_exact_instruction() {
  grep -Fqx -- "$1" "$stdout_log" || {
    printf 'missing exact instruction: %s\n' "$1" >&2
    exit 1
  }
}

reject_instruction() {
  if grep -F -- "$1" "$stdout_log" > /dev/null; then
    printf 'unexpected instruction: %s\n' "$1" >&2
    exit 1
  fi
}

unset DOTFILES_REBUILD_ALLOW_ROOT
: > "$call_log"
: > "$stdout_log"
: > "$stderr_log"
set +e
PATH="$fake_bin:$PATH" "$fakeroot_path" -- "$bash_path" "$rebuild" \
  > "$stdout_log" 2> "$stderr_log"
root_status=$?
set -e
[[ $root_status -eq 2 ]]
[[ ! -s $call_log ]]
grep -F 'run dotfiles-rebuild as the regular user' "$stderr_log" > /dev/null
export DOTFILES_REBUILD_ALLOW_ROOT=1

lock_target=$test_root/lock-target
printf '%s\n' 'preserve-lock-target' > "$lock_target"
ln -s "$lock_target" "$repo/.git/dotfiles-operation.lock"
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'lock must be a regular file' "$stderr_log" > /dev/null
grep -Fqx 'preserve-lock-target' "$lock_target"
reject_call '#sourceSnapshot'
rm "$repo/.git/dotfiles-operation.lock"

exec 9> "$repo/.git/dotfiles-operation.lock"
chmod 0600 "$repo/.git/dotfiles-operation.lock"
flock -n 9
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'another dotfiles state transition is running' "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'
flock -u 9

marker_dir=$repo/.git/dotfiles-sops-enroll
marker=$marker_dir/active.json
mkdir -m 0700 -- "$marker_dir"
cat > "$marker" <<EOF
{"version":2,"transactionId":"0123456789abcdef0123456789abcdef","hostId":"fixture-nixos",
 "worktree":"$repo","phase":"prepared","oldConfigHash":null,"oldSecretsHash":null,
 "newConfigHash":null,"newSecretsHash":null}
EOF
chmod 0600 "$marker"
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'an enrollment transaction blocks normal rebuild' "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'

mkdir -p -- "$repo/secrets"
printf '%s\n' 'config' > "$repo/secrets/.sops.yaml"
printf '%s\n' 'ciphertext' > "$repo/secrets/secrets.yaml"
config_hash=$(sha256sum "$repo/secrets/.sops.yaml" | cut -d ' ' -f 1)
secrets_hash=$(sha256sum "$repo/secrets/secrets.yaml" | cut -d ' ' -f 1)
jq -n \
  --arg worktree "$repo" \
  --arg configHash "$config_hash" \
  --arg secretsHash "$secrets_hash" '
    {version: 2, transactionId: "0123456789abcdef0123456789abcdef", hostId: "fixture-nixos",
     worktree: $worktree, phase: "generation-pending",
     oldConfigHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
     oldSecretsHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     newConfigHash: $configHash, newSecretsHash: $secretsHash}
  ' > "$marker"
chmod 0600 "$marker"
TEST_CHANGED_PATHS=$'secrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'

export WSL_DISTRO_NAME="Nix'OS Test"
run_rebuild switch-restart '' ''
if [[ $rebuild_status -ne 3 ]]; then
  printf 'initial switch-restart returned %s, expected 3\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
enrollment_rebuild_receipt=$repo/.git/dotfiles-rebuild/active.json
enrollment_rebuild_id=$(jq -r '.transactionId' "$enrollment_rebuild_receipt")
jq -e '
  .sopsEnrollmentTransactionId == "0123456789abcdef0123456789abcdef" and
  .state == "restart-pending"
' "$enrollment_rebuild_receipt" > /dev/null

jq '.transactionId = "ffffffffffffffffffffffffffffffff"' "$marker" > "$marker.tmp"
mv "$marker.tmp" "$marker"
chmod 0600 "$marker"
run_rebuild switch '' '' --resume "$enrollment_rebuild_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'receipt and SOPS enrollment state do not match' "$stderr_log" > /dev/null

jq '.transactionId = "0123456789abcdef0123456789abcdef"' "$marker" > "$marker.tmp"
mv "$marker.tmp" "$marker"
chmod 0600 "$marker"
printf '%s\n' "$candidate" > "$booted_state"
export TEST_BOOT_MONOTONIC=150
run_rebuild switch '' '' --resume "$enrollment_rebuild_id"
[[ $rebuild_status -eq 0 ]]
jq -e '
  .state == "complete" and
  .sopsEnrollmentTransactionId == "0123456789abcdef0123456789abcdef"
' "$repo/.git/dotfiles-rebuild/receipts/$enrollment_rebuild_id.json" > /dev/null

TEST_CHANGED_PATHS=$'README.md\nsecrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'only the prepared SOPS files may differ' "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'

jq '.phase = "generation-checking"' "$marker" > "$marker.tmp"
mv "$marker.tmp" "$marker"
chmod 0600 "$marker"
TEST_CHANGED_PATHS=$'secrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'an enrollment transaction blocks normal rebuild' "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'
unset TEST_CHANGED_PATHS
rm -r -- "$marker_dir"

# forward candidate は schema v4 だけを activation 前に受け入れる。
for invalid_candidate_manifest in schema-3 schema-5 malformed multiple missing; do
  case $invalid_candidate_manifest in
    schema-3) printf '%s\n' '{"schemaVersion":3}' > "$candidate/etc/dotfiles/doctor.json" ;;
    schema-5) printf '%s\n' '{"schemaVersion":5}' > "$candidate/etc/dotfiles/doctor.json" ;;
    malformed) printf '%s\n' 'not-json' > "$candidate/etc/dotfiles/doctor.json" ;;
    multiple) printf '%s\n%s\n' '{"schemaVersion":4}' '{"schemaVersion":4}' > "$candidate/etc/dotfiles/doctor.json" ;;
    missing) rm -- "$candidate/etc/dotfiles/doctor.json" ;;
  esac
  run_rebuild switch '' '' --plan
  [[ $rebuild_status -eq 2 ]]
  grep -F 'candidate does not contain a supported schema version 4 doctor manifest' "$stderr_log" > /dev/null
  reject_call 'system-activator'
  reject_call 'nixos-rebuild'
  reject_call 'dotfiles-doctor'
  printf '%s\n' '{"schemaVersion":4}' > "$candidate/etc/dotfiles/doctor.json"
done

# active receipt がなくても、recovery state tree の owner/mode/実体性を先に検証する。
receipt_root=$repo/.git/dotfiles-rebuild
for state_directory in "$receipt_root" "$receipt_root/receipts" "$receipt_root/roots"; do
  chmod 0755 "$state_directory"
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'rebuild receipt storage is invalid' "$stderr_log" > /dev/null
  chmod 0700 "$state_directory"
done

for state_directory in receipts roots; do
  mv "$receipt_root/$state_directory" "$receipt_root/$state_directory.real"
  ln -s "$receipt_root/$state_directory.real" "$receipt_root/$state_directory"
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'rebuild receipt storage is invalid' "$stderr_log" > /dev/null
  rm "$receipt_root/$state_directory"
  mv "$receipt_root/$state_directory.real" "$receipt_root/$state_directory"
done

mv "$receipt_root" "$receipt_root.real"
ln -s "$receipt_root.real" "$receipt_root"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'rebuild receipt storage is invalid' "$stderr_log" > /dev/null
rm "$receipt_root"
mv "$receipt_root.real" "$receipt_root"

# effect の計算中に runtime generation が変わった場合、異なる snapshot を receipt に混ぜない。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
export TEST_RUNTIME_AFTER_PLAN=$displaced_profile
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'runtime generation changed while planning the rebuild' "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'nixos-rebuild'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
export TEST_RUNTIME_AFTER_PLAN=

# persistent root の作成中に外部 activation が割り込んだら、receipt を公開せず停止する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
export TEST_RUNTIME_AFTER_PERSISTENT_ROOT=$displaced_profile
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'runtime generation changed before publishing the rebuild receipt' "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'nixos-rebuild'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
[[ -z $(find "$receipt_root/roots" -mindepth 1 -maxdepth 1 -print -quit) ]]
export TEST_RUNTIME_AFTER_PERSISTENT_ROOT=

# apply-intent の永続化後に drift しても、activation せず terminal abort を監査用に残す。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
export TEST_RUNTIME_AFTER_APPLY_INTENT=$displaced_profile
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'runtime generation changed' "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'nixos-rebuild'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
mapfile -t aborted_receipts < <(
  jq -er --arg previous "$previous" --arg displaced "$displaced_profile" '
    select(
      .schemaVersion == 2 and .state == "aborted" and
      .failureStage == "runtime-drift" and .abort.direction == "forward" and
      .abort.point == "activation-handoff" and
      .recoveryTarget == $previous and
      .abort.expected.current == $previous and
      .abort.expected.profile == $previous and
      .abort.observed.current == $displaced and
      .abort.observed.profile == $displaced and
      .finishedAt != null
    ) | input_filename
  ' "$receipt_root"/receipts/*.json
)
[[ ${#aborted_receipts[@]} -eq 1 ]]
aborted_id=$(jq -r '.transactionId' "${aborted_receipts[0]}")
[[ ! -e $receipt_root/roots/$aborted_id && ! -L $receipt_root/roots/$aborted_id ]]
cp -- "${aborted_receipts[0]}" "$receipt_root/active.json"
chmod 0600 "$receipt_root/active.json"
rewrite_receipt "$receipt_root/active.json" '.abort.observed = .abort.expected'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rm -- "$receipt_root/active.json"
mkdir -m 0700 -- "$receipt_root/roots/$aborted_id"
ln -s -- "$previous" "$receipt_root/roots/$aborted_id/recovery-target"
export TEST_RUNTIME_AFTER_APPLY_INTENT=

# activation failure の再開時に別 generation へ変わっていれば、baseline を更新して上書きしない。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
[[ ! -e $receipt_root/roots/$aborted_id && ! -L $receipt_root/roots/$aborted_id ]]
drift_resume_receipt=$receipt_root/active.json
drift_resume_id=$(jq -r '.transactionId' "$drift_resume_receipt")
printf '%s\n' "$displaced_profile" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' '' --resume "$drift_resume_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'runtime generation changed at activation handoff' "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'nixos-rebuild'
jq -e --arg previous "$previous" --arg displaced "$displaced_profile" '
  .state == "aborted" and .abort.direction == "forward" and
  .abort.expected.current == $previous and .abort.expected.profile == $previous and
  .abort.observed.current == $displaced and .abort.observed.profile == $displaced
' "$receipt_root/receipts/$drift_resume_id.json" > /dev/null

# rollback intent の永続化後に drift した場合も、古い recovery target を自動適用しない。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
drift_rollback_receipt=$receipt_root/active.json
drift_rollback_id=$(jq -r '.transactionId' "$drift_rollback_receipt")
export TEST_RUNTIME_AFTER_ROLLBACK_INTENT=$displaced_profile
run_rebuild switch '' '' --rollback "$drift_rollback_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'runtime generation changed' "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'nixos-rebuild'
jq -e --arg previous "$previous" --arg displaced "$displaced_profile" '
  .state == "aborted" and .abort.direction == "rollback" and
  .abort.point == "intent-publication" and
  .rollback.target == $previous and
  .abort.expected.current == $previous and .abort.expected.profile == $previous and
  .abort.observed.current == $displaced and .abort.observed.profile == $displaced
' "$receipt_root/receipts/$drift_rollback_id.json" > /dev/null
export TEST_RUNTIME_AFTER_ROLLBACK_INTENT=

# plan も default user migration を適用可能な変更として提示しない。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
state_before_plan=$(find "$receipt_root" -printf '%P|%y|%m\n' | sort)
export TEST_CANDIDATE_USER=other-user
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F 'candidate WSL default user other-user does not match configured user' "$stderr_log" > /dev/null
reject_call 'systemctl'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
[[ $(find "$receipt_root" -printf '%P|%y|%m\n' | sort) == "$state_before_plan" ]]
export TEST_CANDIDATE_USER=$test_user

export TEST_PREVIOUS_USER=other-user
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F 'previous WSL default user other-user does not match configured user' "$stderr_log" > /dev/null
reject_call 'systemctl'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
[[ $(find "$receipt_root" -printf '%P|%y|%m\n' | sort) == "$state_before_plan" ]]
export TEST_PREVIOUS_USER=$test_user

# 通常 rebuild は WSL default user の migration を引き受けない。
export TEST_CANDIDATE_USER=other-user
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'candidate WSL default user other-user does not match configured user' "$stderr_log" > /dev/null
reject_call 'nixos-rebuild'
export TEST_CANDIDATE_USER=$test_user

export TEST_PREVIOUS_USER=other-user
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'previous WSL default user other-user does not match configured user' "$stderr_log" > /dev/null
reject_call 'nixos-rebuild'
export TEST_PREVIOUS_USER=$test_user

# receipt 更新の永続化に失敗したら、activation や restart 指示へ進まない。
export TEST_SYNC_FAIL_MATCH='/.active.'
export TEST_SYNC_FAIL_AFTER=2
run_rebuild switch-restart '' ''
[[ $rebuild_status -eq 1 ]]
reject_call 'nixos-rebuild'
reject_instruction 'wsl.exe --terminate'
sync_failure_receipt=$repo/.git/dotfiles-rebuild/active.json
sync_failure_id=$(jq -r '.transactionId' "$sync_failure_receipt")
export TEST_SYNC_FAIL_MATCH=
export TEST_SYNC_FAIL_AFTER=1
run_rebuild switch '' '' --resume "$sync_failure_id"
[[ $rebuild_status -eq 3 ]]
printf '%s\n' "$candidate" > "$booted_state"
export TEST_BOOT_MONOTONIC=151
run_rebuild switch '' '' --resume "$sync_failure_id"
[[ $rebuild_status -eq 0 ]]
rm -- "$repo/.git/dotfiles-rebuild/receipts/$sync_failure_id.json"

# active.json 公開後の file sync 失敗では receipt と roots を保持し、適用前に停止する。
export TEST_SYNC_FAIL_MATCH='/active.json'
run_rebuild switch '' ''
[[ $rebuild_status -eq 1 ]]
reject_call 'nixos-rebuild'
reject_call 'dotfiles-doctor'
reject_instruction 'wsl.exe --terminate'
publication_failure_receipt=$repo/.git/dotfiles-rebuild/active.json
publication_failure_id=$(jq -r '.transactionId' "$publication_failure_receipt")
[[ -f $publication_failure_receipt && ! -L $publication_failure_receipt ]]
[[ -d $repo/.git/dotfiles-rebuild/roots/$publication_failure_id ]]
export TEST_SYNC_FAIL_MATCH=
run_rebuild switch '' '' --resume "$publication_failure_id"
[[ $rebuild_status -eq 0 ]]
rm -- "$repo/.git/dotfiles-rebuild/receipts/$publication_failure_id.json"

# profile が current と不一致でも、rollback 対象は実行中 closure に固定する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' ''
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
assert_apply switch
require_call 'dotfiles-doctor'
reject_instruction 'wsl -t NixOS'

receipt_root=$repo/.git/dotfiles-rebuild
mapfile -t completed_receipts < <(
  find "$receipt_root/receipts" -maxdepth 1 -type f -name '*.json' -print \
    | while IFS= read -r receipt; do
      jq -e '.state == "complete" and .sopsEnrollmentTransactionId == null' "$receipt" > /dev/null &&
        printf '%s\n' "$receipt"
    done
)
[[ ${#completed_receipts[@]} -eq 1 ]]
jq -e --arg displacedProfile "$displaced_profile" '
  .schemaVersion == 2 and
  .state == "complete" and
  .previous.running == .recoveryTarget and
  .previous.running != .previous.displacedProfile and
  .previous.displacedProfile == $displacedProfile and
  .activation.status == "succeeded" and
  .verification.status == "succeeded"
' "${completed_receipts[0]}" > /dev/null
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]

# terminal receipt は成功 status と finishedAt を同時に満たす必要がある。
cp -- "${completed_receipts[0]}" "$receipt_root/active.json"
chmod 0600 "$receipt_root/active.json"
rewrite_receipt "$receipt_root/active.json" '.failureStage = "tampered-terminal"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$receipt_root/active.json" '.failureStage = null'

rewrite_receipt "$receipt_root/active.json" '
  .abort = {
    direction: "forward",
    point: "activation-handoff",
    expected: .activationBaseline,
    observed: .activationBaseline
  }
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$receipt_root/active.json" '.abort = null'

rewrite_receipt "$receipt_root/active.json" '
  .activation = {status: "pending", exitCode: null} |
  .verification = {status: "pending", exitCode: null} |
  .finishedAt = null
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rm -- "$receipt_root/active.json"

# archive 前に残った正規の complete receipt は rollback transaction へ戻せる。
complete_rollback_id=$(jq -r '.transactionId' "${completed_receipts[0]}")
cp -- "${completed_receipts[0]}" "$receipt_root/active.json"
chmod 0600 "$receipt_root/active.json"
rm -- "${completed_receipts[0]}"
run_rebuild switch '' '' --rollback "$complete_rollback_id"
[[ $rebuild_status -eq 0 ]]
assert_apply switch "$previous"
require_call 'dotfiles-doctor'
jq -e '
  .state == "rolled-back" and
  .rollback.activation.status == "succeeded" and
  .verification.status == "succeeded" and
  .finishedAt != null
' "$receipt_root/receipts/$complete_rollback_id.json" > /dev/null

run_rebuild switch-restart '' ''
[[ $rebuild_status -eq 3 ]]
assert_snapshot_pipeline
assert_apply switch
reject_call 'dotfiles-doctor'
active_receipt=$receipt_root/active.json
jq -e '
  .schemaVersion == 2 and
  .state == "restart-pending" and
  .effect == "switch-restart" and
  .activation.status == "succeeded" and
  .verification.status == "pending"
' "$active_receipt" > /dev/null
transaction_id=$(jq -r '.transactionId' "$active_receipt")
require_instruction "--resume '$transaction_id'"
require_instruction "wsl.exe --terminate 'Nix''OS Test'"
require_call "sync --data $active_receipt"
require_call "sync $receipt_root"
require_call "sync $receipt_root/roots/$transaction_id"

# 旧receiptのfield欠落は受理するが、明示的nullは壊れた新contractとして拒否する。
rewrite_receipt "$active_receipt" '.verification.failedCheckIds = null'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" 'del(.verification.failedCheckIds)'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# effect/action と state/rollback の不整合は、不正 receipt として status 2 で拒否する。
rewrite_receipt "$active_receipt" '.action = "boot"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.action = "switch"'

rewrite_receipt "$active_receipt" '.state = "rollback-intent"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.state = "restart-pending"'

rewrite_receipt "$active_receipt" '
  .transactionUser = "other-user" |
  .candidateDefaultUser = "other-user" |
  .previousDefaultUser = "other-user"
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '
  .transactionUser = $configured |
  .candidateDefaultUser = $configured |
  .previousDefaultUser = $configured
' --arg configured "$test_user"

rewrite_receipt "$active_receipt" '.bootInstances.firstBoot = .bootInstances.beforeApply'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.bootInstances.firstBoot = null'

rewrite_receipt "$active_receipt" '.state = "first-boot-observed"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.state = "restart-pending"'

rewrite_receipt "$active_receipt" '.finishedAt = .updatedAt'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.finishedAt = null'

# state と activation/verification result が矛盾する receipt は監査・再開対象にしない。
rewrite_receipt "$active_receipt" '.state = "prepared"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.state = "restart-pending"'

rewrite_receipt "$active_receipt" '
  .state = "verification-failed" |
  .verification = {status: "succeeded", exitCode: 0} |
  .failureStage = "doctor"
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '
  .state = "restart-pending" |
  .verification = {status: "pending", exitCode: null} |
  .failureStage = null
'

# user-facing root だけが残った状態でも、resume は Nix 側の indirect registration を再作成する。
export TEST_SYNC_FAIL_EXACT=$nix_gc_auto_roots
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 1 ]]
require_exact_call "sync $nix_gc_auto_roots"
reject_call 'nixos-rebuild'
export TEST_SYNC_FAIL_EXACT=

for root_label in source candidate recovery-target previous-booted displaced-profile; do
  registration=$(auto_registration_for "$receipt_root/roots/$transaction_id/$root_label")
  rm "$registration"
  [[ -L $receipt_root/roots/$transaction_id/$root_label ]]
done
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 3 ]]
for root_label in source candidate recovery-target previous-booted displaced-profile; do
  root=$receipt_root/roots/$transaction_id/$root_label
  registration=$(auto_registration_for "$root")
  [[ -L $registration && $(readlink -- "$registration") == "$root" ]]
  require_exact_call "nix-store --add-root $root --realise $(readlink -f -- "$root")"
done

run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F "active rebuild transaction $transaction_id" "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'

# field 順序が違っても同じ boot instance と判定する。
rewrite_receipt "$active_receipt" '
  .bootInstances.beforeApply = {
    userspaceTimestampMonotonic: .bootInstances.beforeApply.userspaceTimestampMonotonic,
    kernelBootId: .bootInstances.beforeApply.kernelBootId
  }
'
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 3 ]]
jq -e '.state == "restart-pending"' "$active_receipt" > /dev/null
printf '%s\n' "$candidate" > "$booted_state"
export TEST_BOOT_MONOTONIC=200
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call '#sourceSnapshot'
require_call 'dotfiles-doctor'
[[ ! -e $active_receipt && ! -L $active_receipt ]]
jq -e '
  .state == "complete" and
  .verification.status == "succeeded"
' "$receipt_root/receipts/$transaction_id.json" > /dev/null
require_call "sync $receipt_root/receipts"
require_call "sync $receipt_root/roots"
export WSL_DISTRO_NAME=NixOS

run_rebuild boot-restart '' ''
[[ $rebuild_status -eq 3 ]]
assert_snapshot_pipeline
assert_apply boot
reject_call 'dotfiles-doctor'
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
require_instruction "wsl.exe --terminate 'NixOS'"
require_instruction "--resume '$transaction_id'"
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
printf '%s\n' "$candidate" > "$booted_state"
export TEST_BOOT_MONOTONIC=300
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
require_call 'dotfiles-doctor'

run_rebuild boot-two-stage '' ''
[[ $rebuild_status -eq 3 ]]
assert_snapshot_pipeline
assert_apply boot
reject_call 'dotfiles-doctor'
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
require_instruction "--first-boot '$transaction_id'"
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
printf '%s\n' "$candidate" > "$booted_state"
export TEST_BOOT_MONOTONIC=400

run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 3 ]]
jq -e '.state == "restart-pending" and .bootInstances.firstBoot == null' "$active_receipt" > /dev/null

run_rebuild switch '' '' --first-boot "$transaction_id"
[[ $rebuild_status -eq 3 ]]
jq -e '
  .state == "first-boot-observed" and
  .bootInstances.firstBoot.userspaceTimestampMonotonic == "400"
' "$active_receipt" > /dev/null
forward_first_boot=$(jq -c '.bootInstances.firstBoot' "$active_receipt")
rewrite_receipt "$active_receipt" '.bootInstances.firstBoot = .bootInstances.beforeApply'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.bootInstances.firstBoot = $firstBoot' \
  --argjson firstBoot "$forward_first_boot"

run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 3 ]]
jq -e '.state == "first-boot-observed"' "$active_receipt" > /dev/null

# userspace timestamp が同じでも kernel boot ID が変われば別 instance である。
printf '%s\n' '22222222-2222-2222-2222-222222222222' > "$boot_id_file"
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
require_call 'dotfiles-doctor'
boot_two_stage_receipt=$receipt_root/receipts/$transaction_id.json
cp -- "$boot_two_stage_receipt" "$active_receipt"
chmod 0600 "$active_receipt"
rewrite_receipt "$active_receipt" '.bootInstances.firstBoot = null'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rm -- "$active_receipt"

# activation failure はstatus 4でcandidateとrecovery targetを保持し、同じclassifierでrollbackする。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
  cp -- "$v2_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
  printf '%s\n' '{"schemaVersion":5}' > "$previous/etc/dotfiles/doctor.json"
export TEST_BOOT_MONOTONIC=600
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
jq -e --arg previous "$previous" --arg displacedProfile "$displaced_profile" '
  .state == "activation-failed" and
  .activation.exitCode == 71 and
  .recoveryTarget == .previous.running and
  .previous.running == $previous and
  .previous.displacedProfile == $displacedProfile
' "$active_receipt" > /dev/null
  grep -F "$candidate/sw/bin/dotfiles-rebuild --rollback $transaction_id" "$stderr_log" > /dev/null
  [[ -L $receipt_root/roots/$transaction_id/candidate ]]

  run_rebuild switch '' '' --rollback "$transaction_id"
  [[ $rebuild_status -eq 2 ]]
  grep -F 'recovery target does not contain a supported doctor manifest' "$stderr_log" > /dev/null
  reject_call 'system-activator'
  reject_call 'nixos-rebuild'
  reject_call 'dotfiles-doctor'
  jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null

  printf '%s\n' '{"schemaVersion":2}' > "$previous/etc/dotfiles/doctor.json"

export TEST_DOCTOR_STATUS=1
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 5 ]]
assert_apply switch "$previous"
reject_call "nixos-rebuild switch --sudo --no-reexec --store-path $displaced_profile"
require_exact_call 'dotfiles-doctor'
grep -Fqx 'FAIL: legacy doctor fixture is degraded' "$stderr_log"
jq -e '
  .state == "rollback-verification-failed" and
  .verification.exitCode == 1 and
  .verification.failedCheckIds == ["legacy.doctor"] and
  .failureStage == "doctor"
' "$active_receipt" > /dev/null

export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'nixos-rebuild'
require_exact_call 'dotfiles-doctor'
grep -Fqx 'OK: legacy doctor fixture is healthy' "$stdout_log"
rolled_back_receipt=$receipt_root/receipts/$transaction_id.json
jq -e '.state == "rolled-back"' "$rolled_back_receipt" > /dev/null
  [[ ! -e $receipt_root/roots/$transaction_id && ! -L $receipt_root/roots/$transaction_id ]]
  cp -- "$v3_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
  printf '%s\n' '{"schemaVersion":3}' > "$previous/etc/dotfiles/doctor.json"

cp -- "$rolled_back_receipt" "$active_receipt"
chmod 0600 "$active_receipt"
rewrite_receipt "$active_receipt" '.failureStage = "tampered-terminal"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.failureStage = null'

rewrite_receipt "$active_receipt" '
  .rollback.activation = {status: "pending", exitCode: null} |
  .verification = {status: "pending", exitCode: null} |
  .finishedAt = null
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rm -- "$active_receipt"

# rollback の二段階 restart は --rollback 再実行でも既存の観測点を保持して続行する。
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")

run_rebuild boot-two-stage '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 3 ]]
assert_apply boot "$previous"
jq -e '
  .state == "rollback-restart-pending" and
  .rollback.effect == "boot-two-stage" and
  .rollback.action == "boot"
' "$active_receipt" > /dev/null

rewrite_receipt "$active_receipt" '
  .rollback.bootInstances.firstBoot = .rollback.bootInstances.beforeApply
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.rollback.bootInstances.firstBoot = null'

rewrite_receipt "$active_receipt" '.state = "rollback-first-boot-observed"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.state = "rollback-restart-pending"'

export TEST_BOOT_MONOTONIC=700
run_rebuild switch '' '' --first-boot "$transaction_id"
[[ $rebuild_status -eq 3 ]]
jq -e '.state == "rollback-first-boot-observed"' "$active_receipt" > /dev/null
rollback_before=$(jq -c '.rollback.bootInstances.beforeApply' "$active_receipt")
rollback_first=$(jq -c '.rollback.bootInstances.firstBoot' "$active_receipt")

rewrite_receipt "$active_receipt" '
  .rollback.bootInstances.firstBoot = .rollback.bootInstances.beforeApply
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.rollback.bootInstances.firstBoot = $firstBoot' \
  --argjson firstBoot "$rollback_first"

rewrite_receipt "$active_receipt" '.rollback.action = "switch"'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rewrite_receipt "$active_receipt" '.rollback.action = "boot"'

run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 3 ]]
reject_call 'nixos-rebuild'
[[ $(jq -c '.rollback.bootInstances.beforeApply' "$active_receipt") == "$rollback_before" ]]
[[ $(jq -c '.rollback.bootInstances.firstBoot' "$active_receipt") == "$rollback_first" ]]
[[ $(jq -r '.state' "$active_receipt") == rollback-first-boot-observed ]]

printf '%s\n' '33333333-3333-3333-3333-333333333333' > "$boot_id_file"
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'nixos-rebuild'
require_call 'dotfiles-doctor'
jq -e '
  .state == "rolled-back" and
  .rollback.effect == "boot-two-stage" and
  .rollback.bootInstances.firstBoot != null
' "$receipt_root/receipts/$transaction_id.json" > /dev/null
rollback_two_stage_receipt=$receipt_root/receipts/$transaction_id.json
cp -- "$rollback_two_stage_receipt" "$active_receipt"
chmod 0600 "$active_receipt"
rewrite_receipt "$active_receipt" '.rollback.bootInstances.firstBoot = null'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
rm -- "$active_receipt"

# apply-intent直後に停止しても、実状態がcandidateならactivationを再実行せず検証へ進む。
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
jq '
  .state = "apply-intent" |
  .activation = {status: "pending", exitCode: null} |
  .failureStage = null
' "$active_receipt" > "$active_receipt.tmp"
mv "$active_receipt.tmp" "$active_receipt"
chmod 0600 "$active_receipt"
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'nixos-rebuild'
require_call 'dotfiles-doctor'

# target と外部 generation が混在する resume は、片側が target でも上書きせず abort する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
mixed_forward_id=$(jq -r '.transactionId' "$receipt_root/active.json")
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' '' --resume "$mixed_forward_id"
[[ $rebuild_status -eq 2 ]]
reject_call 'system-activator'
jq -e --arg candidate "$candidate" --arg displaced "$displaced_profile" '
  .state == "aborted" and .abort.direction == "forward" and
  .abort.expected.current == .abort.expected.profile and
  .abort.observed.current == $candidate and .abort.observed.profile == $displaced
' "$receipt_root/receipts/$mixed_forward_id.json" > /dev/null

printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
mixed_rollback_id=$(jq -r '.transactionId' "$receipt_root/active.json")
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
run_rebuild switch '' activation --rollback "$mixed_rollback_id"
[[ $rebuild_status -eq 4 ]]
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' '' --rollback "$mixed_rollback_id"
[[ $rebuild_status -eq 2 ]]
reject_call 'system-activator'
jq -e --arg previous "$previous" --arg displaced "$displaced_profile" '
  .state == "aborted" and .abort.direction == "rollback" and
  .abort.observed.current == $previous and .abort.observed.profile == $displaced
' "$receipt_root/receipts/$mixed_rollback_id.json" > /dev/null

printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$profile_state"
run_rebuild boot-restart '' activation
[[ $rebuild_status -eq 4 ]]
mixed_boot_id=$(jq -r '.transactionId' "$receipt_root/active.json")
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild boot-restart '' '' --resume "$mixed_boot_id"
[[ $rebuild_status -eq 2 ]]
reject_call 'system-activator'
jq -e --arg candidate "$candidate" --arg displaced "$displaced_profile" '
  .state == "aborted" and .abort.direction == "forward" and
  .abort.observed.current == $candidate and .abort.observed.profile == $displaced
' "$receipt_root/receipts/$mixed_boot_id.json" > /dev/null

# doctor failure はactivation failureと混同せずstatus 5で残し、同じcandidateの再検証だけを行う。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
export TEST_DOCTOR_STATUS=1
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
require_exact_call 'dotfiles-doctor --format json'
grep -Fqx 'FAIL: fixture unit failed' "$stderr_log"
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
jq -e '
  .state == "verification-failed" and
  .activation.status == "succeeded" and
  .verification.exitCode == 1 and
  .verification.failedCheckIds == ["systemd.fixture"] and
  .failureStage == "doctor"
' "$active_receipt" > /dev/null
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]
jq -e '.state == "verification-failed"' "$stdout_log" > /dev/null

export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'nixos-rebuild'
require_call 'dotfiles-doctor'
jq -e '
  .state == "complete" and .verification.failedCheckIds == []
' "$receipt_root/receipts/$transaction_id.json" > /dev/null

# report は target manifest と同じ schema version を宣言しなければならない。
export TEST_DOCTOR_REPORT=manifest-mismatch
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
manifest_mismatch_receipt=$receipt_root/active.json
manifest_mismatch_id=$(jq -r '.transactionId' "$manifest_mismatch_receipt")
jq -e '
  .state == "verification-failed" and
  .verification.exitCode == 2 and
  .verification.failedCheckIds == ["doctor.report"] and
  .failureStage == "doctor"
' "$manifest_mismatch_receipt" > /dev/null
export TEST_DOCTOR_REPORT=valid
run_rebuild switch '' '' --resume "$manifest_mismatch_id"
[[ $rebuild_status -eq 0 ]]

# doctor 自身の contract error はruntime driftとは別の outcome/ID のまま保存する。
export TEST_DOCTOR_STATUS=2
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
contract_report_receipt=$receipt_root/active.json
contract_report_id=$(jq -r '.transactionId' "$contract_report_receipt")
jq -e '
  .state == "verification-failed" and
  .verification.exitCode == 2 and
  .verification.failedCheckIds == ["doctor.contract"] and
  .failureStage == "doctor"
' "$contract_report_receipt" > /dev/null
export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --resume "$contract_report_id"
[[ $rebuild_status -eq 0 ]]

# 未定義の doctor status は report の診断を信用せず、raw status と contract failure を残す。
export TEST_DOCTOR_STATUS=9
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
unknown_status_receipt=$receipt_root/active.json
unknown_status_id=$(jq -r '.transactionId' "$unknown_status_receipt")
jq -e '
  .state == "verification-failed" and
  .verification.exitCode == 9 and
  .verification.failedCheckIds == ["doctor.report"] and
  .failureStage == "doctor"
' "$unknown_status_receipt" > /dev/null
export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --resume "$unknown_status_id"
[[ $rebuild_status -eq 0 ]]

for report_mode in summary-mismatch field-missing multiple; do
  export TEST_DOCTOR_STATUS=1
  export TEST_DOCTOR_REPORT=$report_mode
  run_rebuild switch '' ''
  [[ $rebuild_status -eq 5 ]]
  malformed_report_receipt=$receipt_root/active.json
  malformed_report_id=$(jq -r '.transactionId' "$malformed_report_receipt")
  jq -e '
    .state == "verification-failed" and
    .verification.exitCode == 1 and
    .verification.failedCheckIds == ["doctor.report"] and
    .failureStage == "doctor"
  ' "$malformed_report_receipt" > /dev/null
  export TEST_DOCTOR_STATUS=0
  export TEST_DOCTOR_REPORT=valid
  run_rebuild switch '' '' --resume "$malformed_report_id"
  [[ $rebuild_status -eq 0 ]]
done

# 空のhealthy reportはdoctorが0でも収束証拠にならない。report errorをstatus 2へ正規化する。
export TEST_DOCTOR_STATUS=0
export TEST_DOCTOR_REPORT=empty
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
empty_report_receipt=$receipt_root/active.json
empty_report_id=$(jq -r '.transactionId' "$empty_report_receipt")
jq -e '
  .state == "verification-failed" and
  .verification.exitCode == 2 and
  .verification.failedCheckIds == ["doctor.report"] and
  .failureStage == "doctor"
' "$empty_report_receipt" > /dev/null
export TEST_DOCTOR_REPORT=valid
run_rebuild switch '' '' --resume "$empty_report_id"
[[ $rebuild_status -eq 0 ]]

# doctor が非0でも report protocol を破った場合は、構造化不能を専用 check ID で残す。
export TEST_DOCTOR_STATUS=1
export TEST_DOCTOR_REPORT=invalid
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
invalid_report_receipt=$receipt_root/active.json
invalid_report_id=$(jq -r '.transactionId' "$invalid_report_receipt")
jq -e '
  .state == "verification-failed" and
  .verification.exitCode == 1 and
  .verification.failedCheckIds == ["doctor.report"] and
  .failureStage == "doctor"
' "$invalid_report_receipt" > /dev/null
export TEST_DOCTOR_STATUS=0
export TEST_DOCTOR_REPORT=valid
run_rebuild switch '' '' --resume "$invalid_report_id"
[[ $rebuild_status -eq 0 ]]

# archive rename 後の receipts directory sync 失敗は archive と roots を保持し、次回 apply で回収する。
export TEST_SYNC_FAIL_EXACT=$receipt_root/receipts
run_rebuild switch '' ''
[[ $rebuild_status -eq 1 ]]
require_call 'dotfiles-doctor'
require_exact_call "sync $receipt_root/receipts"
require_exact_call "sync $receipt_root"
receipts_barrier_line=$(grep -nFx "sync $receipt_root/receipts" "$call_log" | tail -n 1 | cut -d: -f1)
state_root_barrier_line=$(grep -nFx "sync $receipt_root" "$call_log" | tail -n 1 | cut -d: -f1)
[[ $state_root_barrier_line -gt $receipts_barrier_line ]]
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
mapfile -t retained_roots < <(find "$receipt_root/roots" -mindepth 1 -maxdepth 1 -type d -print)
[[ ${#retained_roots[@]} -eq 1 ]]
archive_failure_id=${retained_roots[0]##*/}
archive_failure_receipt=$receipt_root/receipts/$archive_failure_id.json
jq -e '
  .state == "complete" and
  .activation.status == "succeeded" and
  .verification.status == "succeeded" and
  .finishedAt != null
' "$archive_failure_receipt" > /dev/null
export TEST_SYNC_FAIL_EXACT=
run_rebuild switch '' ''
[[ $rebuild_status -eq 0 ]]
[[ ! -e ${retained_roots[0]} && ! -L ${retained_roots[0]} ]]
require_call 'dotfiles-doctor'

receipt_symlink_target=$test_root/receipt-symlink-target
printf '%s\n' 'preserve-receipt-target' > "$receipt_symlink_target"
ln -s "$receipt_symlink_target" "$receipt_root/active.json"
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
grep -Fqx 'preserve-receipt-target' "$receipt_symlink_target"
reject_call '#sourceSnapshot'
rm "$receipt_root/active.json"

run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]
jq -e '.state == "idle"' "$stdout_log" > /dev/null

run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'
reject_call 'dotfiles-doctor'

export TEST_BOOT_MONOTONIC=0
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'failed to identify the running systemd manager instance' "$stderr_log" > /dev/null
reject_call 'nixos-rebuild'
export TEST_BOOT_MONOTONIC=600

printf '%s\n' 'not-a-uuid' > "$boot_id_file"
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'failed to identify the running systemd manager instance' "$stderr_log" > /dev/null
reject_call 'nixos-rebuild'
printf '%s\n' '11111111-1111-1111-1111-111111111111' > "$boot_id_file"

run_rebuild invalid '' ''
[[ $rebuild_status -eq 2 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'
reject_call 'dotfiles-doctor'

run_rebuild switch $'untracked-file\n' ''
[[ $rebuild_status -ne 0 ]]
require_call "git -C $repo ls-files --others --exclude-standard"
reject_call '#sourceSnapshot'
reject_call 'nix flake check'
reject_call 'nixos-rebuild'

for failure in snapshot check build nvd helper; do
  run_rebuild switch '' "$failure"
  [[ $rebuild_status -ne 0 ]]
  reject_call 'nixos-rebuild'
  reject_call 'dotfiles-doctor'
done
