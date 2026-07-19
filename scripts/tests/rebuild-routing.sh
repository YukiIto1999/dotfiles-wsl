#!/usr/bin/env bash
set -euo pipefail

report_test_failure() {
  local status=$?
  if [[ $- == *e* ]]; then
    printf 'rebuild routing test stopped at line %s (status %s)\n' \
      "${BASH_LINENO[0]}" "$status" >&2
  fi
  return "$status"
}
trap report_test_failure ERR

rebuild_source=${1:?rebuild source path is required}
bash_path=${2:?bash path is required}
fakeroot_path=${3:?fakeroot path is required}
operation_lock_source=${4:?operation lock source path is required}
receipt_source=${5:?rebuild receipt source path is required}
attempt_source=${6:?rebuild attempt source path is required}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

repo=$test_root/dotfiles-wsl
fake_bin=$test_root/fake-bin
wrapper_bin=$test_root/run/wrappers/bin
sudo_wrapper=$wrapper_bin/sudo
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
image_sync_template=$test_root/image-sync-template
v3_doctor_fixture=$test_root/doctor-v3
v2_doctor_fixture=$test_root/doctor-v2
rebuild=$test_root/dotfiles-rebuild
boot_id_file=$test_root/boot-id
current_state=$test_root/current-system
booted_state=$test_root/booted-system
profile_state=$test_root/profile-system
system_profile_path=$test_root/nix/var/nix/profiles/system
test_user=$(id -un)
real_readlink=$(command -v readlink)
legacy_nixpkgs_rev=bd0ff2d3eac24699c3664d5966b9ef36f388e2ca
legacy_nixos_rebuild_path=$store_dir/legacy-nixos-rebuild/bin/nixos-rebuild
legacy_helper_fixture=$store_dir/legacy-dotfiles-rebuild/bin/dotfiles-rebuild

mkdir -p \
  "$repo/.git" "$fake_bin" "$wrapper_bin" "$candidate/sw/bin" "$candidate/etc/dotfiles" "$source_path" \
  "$previous/sw/bin" "$previous/etc/dotfiles" "$displaced_profile" "$nix_gc_auto_roots" \
  "$source_path/modules/commands" "${system_profile_path%/*}" "${legacy_helper_fixture%/*}"
printf '%s\n' 'legacy schema 2 rebuild source fixture' > "$source_path/modules/commands/rebuild"
printf '{"nodes":{"nixpkgs":{"locked":{"rev":"%s"}}}}\n' "$legacy_nixpkgs_rev" > "$source_path/flake.lock"
cat > "$legacy_helper_fixture" <<LEGACY_HELPER
#!$bash_path
if [[ \${1:-} == --abort ]]; then
  echo 'unknown option: --abort' >&2
  exit 2
fi
  $legacy_nixos_rebuild_path "\$action" --sudo --no-reexec --store-path "\$target" -L
LEGACY_HELPER
chmod +x "$legacy_helper_fixture"
legacy_source_hash=$(sha256sum "$source_path/modules/commands/rebuild" | cut -d ' ' -f 1)
legacy_helper_hash=$(sha256sum "$legacy_helper_fixture" | cut -d ' ' -f 1)
sed "s|@dotfilesDir@|$repo|g" "$rebuild_source" \
  | sed "s|@nixStoreDir@|$store_dir|g" \
  | sed "s|@nixGcAutoRootDir@|$nix_gc_auto_roots|g" \
  | sed "s|@systemProfilePath@|$system_profile_path|g" \
  | sed "s|@nixosRebuild@|$fake_bin/system-activator|g" \
  | sed "s|@nixosRebuildPath@|$fake_bin/system-activator|g" \
  | sed "s|@sudoCommand@|$sudo_wrapper|g" \
  | sed "s|@awk@|$(command -v awk)|g" \
  | sed "s|@activationLogLimitBytes@|1024|g" \
  | sed "s|@legacySchema2RebuildSourceSha256@|$legacy_source_hash|g" \
  | sed "s|@legacySchema2CandidateHelperSha256@|$legacy_helper_hash|g" \
  | sed "s|@legacySchema2NixpkgsRev@|$legacy_nixpkgs_rev|g" \
  | sed "s|@legacySchema2NixosRebuildPath@|$legacy_nixos_rebuild_path|g" \
  | sed "s|@username@|$test_user|g" \
  | sed "s|@bootIdFile@|$boot_id_file|g" \
  | sed "/@operationLockFunctions@/ { r $operation_lock_source
    d
  }" \
  | sed "/@rebuildReceiptFunctions@/ { r $receipt_source
    d
  }" \
  | sed "/@rebuildAttemptFunctions@/ { r $attempt_source
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

if [[ $name == system-activator && $(command -v sudo) != "$TEST_SUDO_COMMAND" ]]; then
  printf 'unexpected sudo command: %s\n' "$(command -v sudo || true)" >&2
  exit 72
fi

case "${TEST_FAIL_AT:-}:$name:${1:-}:${2:-}" in
  snapshot:nix:build:* | check:nix:flake:check | build:nix:build:* | nvd:nvd:* | helper:dotfiles-wsl-restart-required:*)
    exit 70
    ;;
  activation:system-activator:*:* | activation:nixos-rebuild:*:* | activation:sudo:*:*)
    printf '%s\n' 'fixture activation stdout'
    printf '%s\n' 'fixture activation stderr' >&2
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
    if [[ ${TEST_ACTIVATION_NO_EFFECT:-0} != 1 ]]; then
      case $action in
        switch)
          printf '%s\n' "$target" > "$TEST_CURRENT_STATE"
          printf '%s\n' "$target" > "$TEST_PROFILE_STATE"
          ;;
        boot)
          printf '%s\n' "$target" > "$TEST_PROFILE_STATE"
          ;;
      esac
    fi
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
      "$TEST_SYSTEM_PROFILE_PATH") cat "$TEST_PROFILE_STATE" ;;
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

for command in git nix nom nvd dotfiles-wsl-restart-required nixos-rebuild system-activator nix-store readlink systemctl sync; do
  ln -s command-stub "$fake_bin/$command"
done
ln -s "$fake_bin/command-stub" "$sudo_wrapper"

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
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$candidate/etc/dotfiles/oci-images.json"
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$previous/etc/dotfiles/oci-images.json"

cat > "$image_sync_template" <<'SYNC_IMAGES'
#!@bash@
set -euo pipefail

label=@label@
printf 'dotfiles-sync-images:%s' "$label" >> "$CALL_LOG"
for argument in "$@"; do
  printf ' %q' "$argument" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
[[ $# -eq 1 && $1 == --status ]] || exit 2
exec 8<> "$TEST_COMMON_GIT_DIR/dotfiles-operation.lock"
if flock -n 8; then
  echo "fixture OCI readiness ran without the repository operation lock" >&2
  exit 2
fi
status_variable=TEST_OCI_STATUS_${label^^}
status=${!status_variable:-0}
printf 'OCI readiness fixture %s returned %s\n' "$label" "$status"
exit "$status"
SYNC_IMAGES
for label in candidate previous; do
  target=$candidate
  [[ $label != previous ]] || target=$previous
  sed -e "1s|@bash@|$bash_path|" -e "s|@label@|$label|g" \
    "$image_sync_template" > "$target/sw/bin/dotfiles-sync-images"
  chmod +x "$target/sw/bin/dotfiles-sync-images"
done

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
export TEST_SYSTEM_PROFILE_PATH=$system_profile_path
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
export TEST_OCI_STATUS_CANDIDATE=0
export TEST_OCI_STATUS_PREVIOUS=0
export TEST_ACTIVATION_NO_EFFECT=0
export TEST_SUDO_COMMAND=$sudo_wrapper
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
  export TEST_OCI_STATUS_CANDIDATE=${TEST_OCI_STATUS_CANDIDATE:-0}
  export TEST_OCI_STATUS_PREVIOUS=${TEST_OCI_STATUS_PREVIOUS:-0}
  export TEST_ACTIVATION_NO_EFFECT=${TEST_ACTIVATION_NO_EFFECT:-0}
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
  local readiness_expected=${1:-yes}
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
  if [[ $readiness_expected == yes ]]; then
    require_exact_call "dotfiles-sync-images:candidate --status"
    assert_before "dotfiles-wsl-restart-required --default-user $expected_pipeline_current" \
      'dotfiles-sync-images:candidate --status'
  else
    reject_call 'dotfiles-sync-images:candidate --status'
  fi
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

# candidate の OCI readiness は plan と apply のどちらでも receipt 公開前に検査する。
receipt_root=$repo/.git/dotfiles-rebuild
printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$candidate/etc/dotfiles/oci-images.json"
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F 'candidate target requires OCI image manifest schema version 2' "$stderr_log" > /dev/null
reject_call 'dotfiles-sync-images:candidate --status'
reject_call 'nix-store --add-root'
reject_call 'system-activator'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$candidate/etc/dotfiles/oci-images.json"

export TEST_OCI_STATUS_CANDIDATE=1
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 1 ]]
grep -Fqx 'OCI readiness fixture candidate returned 1' "$stdout_log"
grep -Fqx "Run: $candidate/sw/bin/dotfiles-sync-images" "$stderr_log"
reject_call 'nix-store --add-root'
reject_call 'system-activator'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]

run_rebuild switch '' ''
[[ $rebuild_status -eq 1 ]]
reject_call 'nix-store --add-root'
reject_call 'system-activator'
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]

export TEST_OCI_STATUS_CANDIDATE=2
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -Fqx 'OCI readiness fixture candidate returned 2' "$stdout_log"
grep -F "target OCI readiness check is invalid" "$stderr_log" > /dev/null
reject_call 'nix-store --add-root'

export TEST_OCI_STATUS_CANDIDATE=9
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F "target OCI readiness check is invalid (status 9)" "$stderr_log" > /dev/null
reject_call 'nix-store --add-root'

mv "$candidate/sw/bin/dotfiles-sync-images" "$candidate/sw/bin/dotfiles-sync-images.fixture"
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F "target does not contain an executable OCI image sync helper" "$stderr_log" > /dev/null
reject_call 'nix-store --add-root'
mv "$candidate/sw/bin/dotfiles-sync-images.fixture" "$candidate/sw/bin/dotfiles-sync-images"
chmod -x "$candidate/sw/bin/dotfiles-sync-images"
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F "target does not contain an executable OCI image sync helper" "$stderr_log" > /dev/null
reject_call 'nix-store --add-root'
chmod +x "$candidate/sw/bin/dotfiles-sync-images"
export TEST_OCI_STATUS_CANDIDATE=0
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 0 ]]
require_exact_call 'dotfiles-sync-images:candidate --status'

# active receipt がなくても、recovery state tree の owner/mode/実体性を先に検証する。
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
      .schemaVersion == 3 and .state == "aborted" and
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
if [[ $rebuild_status -ne 0 ]]; then
  printf 'receipt publication recovery returned %s, expected 0\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
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
  .schemaVersion == 3 and
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
  .schemaVersion == 3 and
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

# exit 0 でも runtime が target へ遷移しなければ成功として記録せず、再開時に回収する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
export TEST_BOOT_MONOTONIC=600
export TEST_ACTIVATION_NO_EFFECT=1
run_rebuild switch '' ''
[[ $rebuild_status -eq 2 ]]
grep -F 'activation outcome contradicts its activation boundary' "$stderr_log" > /dev/null
contradictory_receipt=$receipt_root/active.json
contradictory_id=$(jq -r '.transactionId' "$contradictory_receipt")
contradictory_attempt_root=$receipt_root/$(dirname -- \
  "$(jq -r '.activation.attempts[-1].partialLogPath' "$contradictory_receipt")")
jq -e '
  .state == "activating" and
  .activation.status == "pending" and
  .activation.attempts[-1].status == "running" and
  .activation.attempts[-1].log == null and
  .activation.attempts[-1].outcome == null
' "$contradictory_receipt" > /dev/null
[[ -f $contradictory_attempt_root/activation.log &&
  ! -e $contradictory_attempt_root/outcome.json ]]
reject_call 'dotfiles-doctor'

export TEST_ACTIVATION_NO_EFFECT=0
run_rebuild switch '' '' --resume "$contradictory_id"
[[ $rebuild_status -eq 0 ]]
jq -e '
  .state == "complete" and
  (.activation.attempts | length) == 2 and
  .activation.attempts[0].status == "indeterminate" and
  .activation.attempts[1].status == "succeeded"
' "$receipt_root/receipts/$contradictory_id.json" > /dev/null

# activation failure の forward resume は固定 candidate の OCI readiness を再検査する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
export TEST_BOOT_MONOTONIC=600
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")
jq -e --arg previous "$previous" --arg displacedProfile "$displaced_profile" '
  .schemaVersion == 3 and
  .state == "activation-failed" and
  .activation.exitCode == 71 and
  .activationDriver.protocol == "nixos-rebuild-ng-profile-before-activation-v1" and
  (.activationDriver.executable | type == "string" and length > 0) and
  (.activation.attempts | length) == 1 and
  .activation.attempts[0].number == 1 and
  .activation.attempts[0].status == "failed" and
  .activation.attempts[0].exitCode == 71 and
  .activation.attempts[0].finishedAt != null and
  .activation.attempts[0].log.captureExitCode == 0 and
  (.activation.attempts[0].log.sha256 | test("^[0-9a-f]{64}$")) and
  .recoveryTarget == .previous.running and
  .previous.running == $previous and
  .previous.displacedProfile == $displacedProfile
' "$active_receipt" > /dev/null

# aggregate failure は末尾 attempt の failure 証拠と一致しなければならない。
cp -- "$stderr_log" "$test_root/activation-failed.stderr"
receipt_backup=$test_root/activation-failed.aggregate-backup.json
cp -p -- "$active_receipt" "$receipt_backup"
rewrite_receipt "$active_receipt" '
  .activation.attempts[-1].status = "succeeded" |
  .activation.attempts[-1].boundary = "after-profile-commit" |
  .activation.attempts[-1].exitCode = 0
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
mv -T -- "$receipt_backup" "$active_receipt"

# hash を更新しても outcome の投影が receipt と矛盾すれば journal として受理しない。
receipt_backup=$test_root/activation-failed.outcome-receipt-backup.json
cp -p -- "$active_receipt" "$receipt_backup"
outcome_file=$receipt_root/$(jq -r '.activation.attempts[0].outcome.path' "$active_receipt")
outcome_backup=$test_root/activation-failed.outcome-backup.json
cp -p -- "$outcome_file" "$outcome_backup"
rewrite_receipt "$outcome_file" '.exitCode = 0'
outcome_sha=$(sha256sum "$outcome_file" | cut -d ' ' -f 1)
outcome_bytes=$(stat -c '%s' "$outcome_file")
rewrite_receipt "$active_receipt" '
  .activation.attempts[0].outcome.sha256 = $sha |
  .activation.attempts[0].outcome.bytes = $bytes
' --arg sha "$outcome_sha" --argjson bytes "$outcome_bytes"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
mv -T -- "$outcome_backup" "$outcome_file"
mv -T -- "$receipt_backup" "$active_receipt"

# receipt が投影しない runtime/boot も、attempt の action と baseline に対して検証する。
for outcome_semantic_tamper in runtime boot; do
  receipt_backup=$test_root/activation-failed.$outcome_semantic_tamper-receipt-backup.json
  outcome_backup=$test_root/activation-failed.$outcome_semantic_tamper-outcome-backup.json
  cp -p -- "$active_receipt" "$receipt_backup"
  cp -p -- "$outcome_file" "$outcome_backup"
  if [[ $outcome_semantic_tamper == runtime ]]; then
    rewrite_receipt "$outcome_file" '.observedRuntime.current = $candidate' \
      --arg candidate "$candidate"
  else
    rewrite_receipt "$outcome_file" \
      '.observedBootInstance.userspaceTimestampMonotonic = "999"'
  fi
  outcome_sha=$(sha256sum "$outcome_file" | cut -d ' ' -f 1)
  outcome_bytes=$(stat -c '%s' "$outcome_file")
  rewrite_receipt "$active_receipt" '
    .activation.attempts[0].outcome.sha256 = $sha |
    .activation.attempts[0].outcome.bytes = $bytes
  ' --arg sha "$outcome_sha" --argjson bytes "$outcome_bytes"
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
  mv -T -- "$outcome_backup" "$outcome_file"
  mv -T -- "$receipt_backup" "$active_receipt"
done
cp -- "$test_root/activation-failed.stderr" "$stderr_log"

activation_log_relative=$(jq -r '.activation.attempts[0].log.path' "$active_receipt")
activation_log=$receipt_root/$activation_log_relative
[[ -f $activation_log && ! -L $activation_log ]]
[[ $(stat -c '%u|%a|%h' "$activation_log") == "$EUID|400|1" ]]
grep -F 'fixture activation stdout' "$activation_log" > /dev/null
grep -F 'fixture activation stderr' "$activation_log" > /dev/null
[[ $(sha256sum "$activation_log" | cut -d ' ' -f 1) == \
  $(jq -r '.activation.attempts[0].log.sha256' "$active_receipt") ]]
grep -F "Activation log: $activation_log" "$stderr_log" > /dev/null
grep -F "$candidate/sw/bin/dotfiles-rebuild --rollback $transaction_id" "$stderr_log" > /dev/null
[[ -L $receipt_root/roots/$transaction_id/candidate ]]

activation_log_backup=$test_root/activation.log.backup
cp -p -- "$activation_log" "$activation_log_backup"
chmod 0600 "$activation_log"
printf '%s\n' 'tampered activation log' >> "$activation_log"
chmod 0400 "$activation_log"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'activation journal is invalid' "$stderr_log" > /dev/null
mv -T -- "$activation_log_backup" "$activation_log"

# runner が receipt 更新前に消えた attempt は、partial log を保存してから新しい attempt へ進む。
activation_attempt_root=${activation_log%/*}
mv -T -- "$activation_log" "$activation_attempt_root/activation.log.partial"
chmod 0600 "$activation_attempt_root/activation.log.partial"
rm -- "$activation_attempt_root/outcome.json"
rewrite_receipt "$active_receipt" '
  .state = "activating" |
  .activation.status = "pending" |
  .activation.exitCode = null |
  .activation.attempts[0].status = "running" |
  .activation.attempts[0].boundary = null |
  .activation.attempts[0].finishedAt = null |
  .activation.attempts[0].exitCode = null |
  .activation.attempts[0].log = null |
  .activation.attempts[0].outcome = null |
  .failureStage = null
'
# WSL 再起動後の retry は transaction 開始時ではなく、その attempt の boot instance に束縛する。
export TEST_BOOT_MONOTONIC=601
run_rebuild switch '' activation --resume "$transaction_id"
if [[ $rebuild_status -ne 4 ]]; then
  printf 'interrupted activation resume returned %s, expected 4\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
assert_apply switch
if ! jq -e '
  .state == "activation-failed" and
  (.activation.attempts | length) == 2 and
  .activation.attempts[0].status == "indeterminate" and
  .activation.attempts[0].boundary == "before-profile-commit" and
  .activation.attempts[0].exitCode == null and
  .activation.attempts[0].log.captureExitCode == 255 and
  .activation.attempts[0].outcome != null and
  .activation.attempts[1].status == "failed" and
  .activation.attempts[1].exitCode == 71 and
  .activation.attempts[1].bootBaseline.userspaceTimestampMonotonic == "601"
' "$active_receipt" > /dev/null; then
  jq '{state, activation, failureStage}' "$active_receipt" >&2
  exit 1
fi

# handler が [-1] を最新と扱うため、attempt ledger の順序も receipt 契約に含める。
receipt_backup=$test_root/activation-failed.order-backup.json
cp -p -- "$active_receipt" "$receipt_backup"
rewrite_receipt "$active_receipt" '.activation.attempts |= reverse'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild receipt is invalid' "$stderr_log" > /dev/null
mv -T -- "$receipt_backup" "$active_receipt"

activation_log_relative=$(jq -r '.activation.attempts[0].log.path' "$active_receipt")
activation_log=$receipt_root/$activation_log_relative
[[ -f $activation_log && ! -e $activation_attempt_root/activation.log.partial ]]
[[ $(stat -c '%u|%a|%h' "$activation_log") == "$EUID|400|1" ]]
grep -F 'fixture activation stderr' "$activation_log" > /dev/null

# outcome と final log が durable なら、receipt 更新前に途切れても終了コードを復元する。
rewrite_receipt "$active_receipt" '
  .state = "activating" |
  .activation.status = "pending" |
  .activation.exitCode = null |
  .activation.attempts[-1].status = "running" |
  .activation.attempts[-1].boundary = null |
  .activation.attempts[-1].finishedAt = null |
  .activation.attempts[-1].exitCode = null |
  .activation.attempts[-1].log = null |
  .activation.attempts[-1].outcome = null |
  .failureStage = null
'
# 改ざん outcome と現在値を一致させても、attempt baseline との矛盾は復元しない。
durable_attempt_root=$receipt_root/$(dirname -- \
  "$(jq -r '.activation.attempts[-1].partialLogPath' "$active_receipt")")
durable_outcome_file=$durable_attempt_root/outcome.json
for durable_semantic_tamper in runtime boot; do
  durable_outcome_backup=$test_root/durable-outcome.$durable_semantic_tamper-backup.json
  cp -p -- "$durable_outcome_file" "$durable_outcome_backup"
  if [[ $durable_semantic_tamper == runtime ]]; then
    rewrite_receipt "$durable_outcome_file" '.observedRuntime.current = $candidate' \
      --arg candidate "$candidate"
    printf '%s\n' "$candidate" > "$current_state"
    printf '%s\n' "$displaced_profile" > "$profile_state"
  else
    rewrite_receipt "$durable_outcome_file" \
      '.observedBootInstance.userspaceTimestampMonotonic = "602"'
    printf '%s\n' "$previous" > "$current_state"
    printf '%s\n' "$displaced_profile" > "$profile_state"
    export TEST_BOOT_MONOTONIC=602
  fi
  run_rebuild switch '' '' --resume "$transaction_id"
  [[ $rebuild_status -eq 2 ]]
  grep -F 'durable activation outcome contradicts its activation boundary' \
    "$stderr_log" > /dev/null
  reject_call 'system-activator'
  jq -e '.state == "activating" and .activation.attempts[-1].status == "running"' \
    "$active_receipt" > /dev/null
  mv -T -- "$durable_outcome_backup" "$durable_outcome_file"
  export TEST_BOOT_MONOTONIC=601
done

printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
run_rebuild switch '' '' --resume "$transaction_id"
if [[ $rebuild_status -ne 2 ]]; then
  printf 'drifted durable outcome resume returned %s, expected 2\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
grep -F 'durable activation outcome no longer matches current runtime' \
  "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'dotfiles-doctor'
jq -e '.state == "activating" and .activation.attempts[-1].status == "running"' \
  "$active_receipt" > /dev/null
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' activation --resume "$transaction_id"
if [[ $rebuild_status -ne 4 ]]; then
  printf 'durable outcome resume returned %s, expected 4\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
assert_apply switch
jq -e '
  .state == "activation-failed" and
  (.activation.attempts | length) == 3 and
  .activation.attempts[1].status == "failed" and
  .activation.attempts[1].boundary == "before-profile-commit" and
  .activation.attempts[1].exitCode == 71 and
  .activation.attempts[1].log.captureExitCode == 0 and
  .activation.attempts[2].status == "failed" and
  .activation.attempts[2].exitCode == 71
' "$active_receipt" > /dev/null

# final log だけが durable な crash window も、結果不明の attempt として閉じて再試行する。
final_only_root=$receipt_root/$(dirname -- "$(jq -r '.activation.attempts[-1].log.path' \
  "$active_receipt")")
rm -- "$final_only_root/outcome.json"
rewrite_receipt "$active_receipt" '
  .state = "activating" |
  .activation.status = "pending" |
  .activation.exitCode = null |
  .activation.attempts[-1].status = "running" |
  .activation.attempts[-1].boundary = null |
  .activation.attempts[-1].finishedAt = null |
  .activation.attempts[-1].exitCode = null |
  .activation.attempts[-1].log = null |
  .activation.attempts[-1].outcome = null |
  .failureStage = null
'
run_rebuild switch '' activation --resume "$transaction_id"
if [[ $rebuild_status -ne 4 ]]; then
  printf 'final-only outcome resume returned %s, expected 4\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
assert_apply switch
jq -e '
  .state == "activation-failed" and
  (.activation.attempts | length) == 4 and
  .activation.attempts[2].status == "indeterminate" and
  .activation.attempts[2].boundary == "before-profile-commit" and
  .activation.attempts[2].exitCode == null and
  .activation.attempts[3].status == "failed" and
  .activation.attempts[3].exitCode == 71
' "$active_receipt" > /dev/null

# active activation retry でも旧 OCI schema を helper 実行前に拒否する。
printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$candidate/etc/dotfiles/oci-images.json"
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'candidate target requires OCI image manifest schema version 2' "$stderr_log" > /dev/null
reject_call 'dotfiles-sync-images:candidate --status'
reject_call 'system-activator'
jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$candidate/etc/dotfiles/oci-images.json"

export TEST_OCI_STATUS_CANDIDATE=1
rm -- "$receipt_root/roots/$transaction_id/candidate"
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 1 ]]
grep -Fqx "Run: $candidate/sw/bin/dotfiles-sync-images" "$stderr_log"
reject_call 'system-activator'
[[ -L $receipt_root/roots/$transaction_id/candidate &&
  $(readlink -f -- "$receipt_root/roots/$transaction_id/candidate") == "$candidate" ]]
jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null
export TEST_OCI_STATUS_CANDIDATE=0
run_rebuild switch '' '' --resume "$transaction_id"
[[ $rebuild_status -eq 0 ]]
require_exact_call 'dotfiles-sync-images:candidate --status'
assert_apply switch

# rollback は schema v4 readiness contract のない legacy generation を通常経路で拒否する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
active_receipt=$receipt_root/active.json
transaction_id=$(jq -r '.transactionId' "$active_receipt")

for legacy_schema in 2 3; do
  if [[ $legacy_schema -eq 2 ]]; then
    cp -- "$v2_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
  else
    cp -- "$v3_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
  fi
  printf '{"schemaVersion":%s}\n' "$legacy_schema" > "$previous/etc/dotfiles/doctor.json"
  run_rebuild switch '' '' --rollback "$transaction_id"
  [[ $rebuild_status -eq 2 ]]
  grep -F 'recovery target requires doctor manifest schema version 4' "$stderr_log" > /dev/null
  reject_call 'dotfiles-sync-images:previous --status'
  reject_call 'system-activator'
  reject_call 'dotfiles-doctor'
  jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null
done

# phase 4 より前に rollback object が記録済みの transaction は、旧 doctor protocol で verification を再開できる。
forward_failure_receipt=$test_root/forward-activation-failed.json
cp -- "$active_receipt" "$forward_failure_receipt"
rewrite_receipt "$forward_failure_receipt" '
  .schemaVersion = 2 |
  del(.activationDriver, .cancellation, .activation.attempts)
'
for legacy_schema in 3 2; do
  cp -- "$forward_failure_receipt" "$active_receipt"
  chmod 0600 "$active_receipt"
  rewrite_receipt "$active_receipt" '
    .rollback = {
      target: .recoveryTarget,
      effect: "switch",
      action: "switch",
      activationBaseline: .activationBaseline,
      bootInstances: {beforeApply: .bootInstances.beforeApply, firstBoot: null},
      activation: {status: "succeeded", exitCode: 0}
    } |
    .state = "rollback-verification-failed" |
    .verification = {status: "failed", exitCode: 1, failedCheckIds: ["fixture.previous"]} |
    .failureStage = "doctor" |
    .finishedAt = null
  '
  printf '%s\n' "$previous" > "$current_state"
  printf '%s\n' "$previous" > "$profile_state"
  printf '%s\n' "$previous" > "$booted_state"
  if [[ $legacy_schema -eq 3 ]]; then
    cp -- "$v3_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
    printf '%s\n' '{"schemaVersion":3}' > "$previous/etc/dotfiles/doctor.json"
    export TEST_DOCTOR_STATUS=0
    run_rebuild switch '' '' --rollback "$transaction_id"
    [[ $rebuild_status -eq 0 ]]
    require_exact_call 'dotfiles-doctor --format json'
  else
    cp -- "$v2_doctor_fixture" "$previous/sw/bin/dotfiles-doctor"
    printf '%s\n' '{"schemaVersion":2}' > "$previous/etc/dotfiles/doctor.json"
    export TEST_DOCTOR_STATUS=1
    run_rebuild switch '' '' --rollback "$transaction_id"
    [[ $rebuild_status -eq 5 ]]
    require_exact_call 'dotfiles-doctor'
    grep -Fqx 'FAIL: legacy doctor fixture is degraded' "$stderr_log"
    jq -e '
      .state == "rollback-verification-failed" and
      .verification.exitCode == 1 and
      .verification.failedCheckIds == ["legacy.doctor"]
    ' "$active_receipt" > /dev/null
    export TEST_DOCTOR_STATUS=0
    run_rebuild switch '' '' --rollback "$transaction_id"
    [[ $rebuild_status -eq 0 ]]
    require_exact_call 'dotfiles-doctor'
    grep -Fqx 'OK: legacy doctor fixture is healthy' "$stdout_log"
  fi
  jq -e '.state == "rolled-back"' "$receipt_root/receipts/$transaction_id.json" > /dev/null
  rm -- "$receipt_root/receipts/$transaction_id.json"
done

cp -- "$forward_failure_receipt" "$active_receipt"
chmod 0600 "$active_receipt"
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' "$previous" > "$booted_state"

cp -- "$candidate/sw/bin/dotfiles-doctor" "$previous/sw/bin/dotfiles-doctor"
printf '%s\n' '{"schemaVersion":4}' > "$previous/etc/dotfiles/doctor.json"

# doctor schema v4 だけでは phase 4 の pull=never / active repair capability を証明しない。
printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$previous/etc/dotfiles/oci-images.json"
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'recovery target requires OCI image manifest schema version 2' "$stderr_log" > /dev/null
reject_call 'dotfiles-sync-images:previous --status'
reject_call 'system-activator'
jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$previous/etc/dotfiles/oci-images.json"

export TEST_OCI_STATUS_PREVIOUS=1
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 1 ]]
grep -Fqx "Run: $previous/sw/bin/dotfiles-sync-images" "$stderr_log"
reject_call 'system-activator'
jq -e '.state == "activation-failed" and .rollback == null' "$active_receipt" > /dev/null

export TEST_OCI_STATUS_PREVIOUS=0
run_rebuild switch '' activation --rollback "$transaction_id"
[[ $rebuild_status -eq 4 ]]
require_exact_call 'dotfiles-sync-images:previous --status'
jq -e '.state == "rollback-activation-failed" and .rollback != null' "$active_receipt" > /dev/null

# rollback activation resume も固定 recovery target を再検査する。
printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$previous/etc/dotfiles/oci-images.json"
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'recovery target requires OCI image manifest schema version 2' "$stderr_log" > /dev/null
reject_call 'dotfiles-sync-images:previous --status'
reject_call 'system-activator'
jq -e '.state == "rollback-activation-failed" and .rollback != null' "$active_receipt" > /dev/null
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$previous/etc/dotfiles/oci-images.json"

export TEST_OCI_STATUS_PREVIOUS=1
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 1 ]]
reject_call 'system-activator'
jq -e '.state == "rollback-activation-failed"' "$active_receipt" > /dev/null

export TEST_OCI_STATUS_PREVIOUS=0
export TEST_DOCTOR_STATUS=1
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 5 ]]
assert_apply switch "$previous"
require_exact_call 'dotfiles-doctor --format json'
jq -e '
  .state == "rollback-verification-failed" and
  .verification.exitCode == 1 and
  .verification.failedCheckIds == ["systemd.fixture"] and
  .failureStage == "doctor"
' "$active_receipt" > /dev/null

# verification-only retry は OCI readiness を再検査せず doctor に委ねる。
export TEST_OCI_STATUS_PREVIOUS=1
export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --rollback "$transaction_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'dotfiles-sync-images:previous --status'
require_exact_call 'dotfiles-doctor --format json'
rolled_back_receipt=$receipt_root/receipts/$transaction_id.json
jq -e '.state == "rolled-back"' "$rolled_back_receipt" > /dev/null
[[ ! -e $receipt_root/roots/$transaction_id && ! -L $receipt_root/roots/$transaction_id ]]
export TEST_OCI_STATUS_PREVIOUS=0

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
  .schemaVersion = 2 |
  del(.activationDriver, .cancellation) |
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

# profile commit より前に失敗した attempt は、runtime と boot instance が baseline のままなら閉じられる。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
printf '%s\n' '11111111-1111-1111-1111-111111111111' > "$boot_id_file"
export TEST_BOOT_MONOTONIC=600
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
cancel_receipt=$receipt_root/active.json
cancel_id=$(jq -r '.transactionId' "$cancel_receipt")
cancel_log_relative=$(jq -r '.activation.attempts[-1].log.path' "$cancel_receipt")
run_rebuild switch '' '' --abort "$cancel_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'system-activator'
reject_call 'dotfiles-doctor'
[[ ! -e $cancel_receipt && ! -L $cancel_receipt ]]
[[ ! -e $receipt_root/roots/$cancel_id && ! -L $receipt_root/roots/$cancel_id ]]
[[ -f $receipt_root/$cancel_log_relative ]]
jq -e '
  .schemaVersion == 3 and
  .state == "cancelled" and
  .cancellation.kind == "manual-zero-effect" and
  .cancellation.boundary == "before-profile-commit" and
  .cancellation.driverContract == "nixos-rebuild-ng-profile-before-activation-v1" and
  .cancellation.expectedRuntime == .cancellation.observedRuntime and
  .cancellation.expectedBootInstance == .cancellation.observedBootInstance and
  .activation.status == "failed" and
  .activation.attempts[-1].boundary == "before-profile-commit" and
  .verification.status == "pending" and
  .rollback == null and .abort == null and .failureStage == null and
  .finishedAt != null
' "$receipt_root/receipts/$cancel_id.json" > /dev/null

# 配備済み schema v2 driver は source と helper の allowlist が一致する場合だけ v3 へ移行して閉じる。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
legacy_cancel_receipt=$receipt_root/active.json
legacy_cancel_id=$(jq -r '.transactionId' "$legacy_cancel_receipt")
rewrite_receipt "$legacy_cancel_receipt" '
  .schemaVersion = 2 |
  del(.activationDriver, .activation.attempts, .cancellation, .migration)
'
rm -- "$candidate/sw/bin/dotfiles-rebuild"
ln -s -- "$legacy_helper_fixture" "$candidate/sw/bin/dotfiles-rebuild"
# 配備前 helper では閉じられず、flake package の新 runner が migration を担う。
set +e
"$candidate/sw/bin/dotfiles-rebuild" --abort "$legacy_cancel_id" \
  > "$stdout_log" 2> "$stderr_log"
legacy_helper_status=$?
set -e
if [[ $legacy_helper_status -ne 2 ]]; then
  printf 'legacy helper abort returned %s, expected 2\n' "$legacy_helper_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
grep -F 'unknown option: --abort' "$stderr_log" > /dev/null
[[ -f $legacy_cancel_receipt ]]

# 同じ内容でも Nix store 外へ解決する helper symlink は監査対象にしない。
outside_legacy_helper=$test_root/legacy-helper-outside-store
cp -- "$legacy_helper_fixture" "$outside_legacy_helper"
rm -- "$candidate/sw/bin/dotfiles-rebuild"
ln -s -- "$outside_legacy_helper" "$candidate/sw/bin/dotfiles-rebuild"
legacy_cancel_sha=$(sha256sum "$legacy_cancel_receipt" | cut -d ' ' -f 1)
run_rebuild switch '' '' --abort "$legacy_cancel_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'schema 2 helper does not resolve to a Nix store file' "$stderr_log" > /dev/null
[[ $(sha256sum "$legacy_cancel_receipt" | cut -d ' ' -f 1) == "$legacy_cancel_sha" ]]
[[ ! -e $receipt_root/migrations/$legacy_cancel_id/schema-2.json ]]
rm -- "$candidate/sw/bin/dotfiles-rebuild"
ln -s -- "$legacy_helper_fixture" "$candidate/sw/bin/dotfiles-rebuild"

# 安全性を証明できない場合、旧 helper が読める schema v2 receipt を一切変更しない。
legacy_cancel_sha=$(sha256sum "$legacy_cancel_receipt" | cut -d ' ' -f 1)
export TEST_BOOT_MONOTONIC=601
run_rebuild switch '' '' --abort "$legacy_cancel_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'boot instance differs from the activation baseline; cancellation is unsafe' \
  "$stderr_log" > /dev/null
[[ $(sha256sum "$legacy_cancel_receipt" | cut -d ' ' -f 1) == "$legacy_cancel_sha" ]]
jq -e '.schemaVersion == 2' "$legacy_cancel_receipt" > /dev/null
[[ ! -e $receipt_root/migrations/$legacy_cancel_id/schema-2.json ]]

export TEST_BOOT_MONOTONIC=600
run_rebuild switch '' '' --abort "$legacy_cancel_id"
[[ $rebuild_status -eq 0 ]]
[[ ! -e $legacy_cancel_receipt && ! -L $legacy_cancel_receipt ]]
legacy_cancel_archive=$receipt_root/receipts/$legacy_cancel_id.json
jq -e --arg sourceHash "$legacy_source_hash" --arg helperHash "$legacy_helper_hash" '
  .schemaVersion == 3 and .state == "cancelled" and
  .migration.fromSchema == 2 and
  .migration.classification == "before-profile-commit" and
  .migration.sourceTemplateSha256 == $sourceHash and
  .migration.candidateHelperSha256 == $helperHash and
  .migration.receipt.path == ("migrations/" + .transactionId + "/schema-2.json") and
  .activation.attempts == [] and
  .cancellation.fromState == "activation-failed"
' "$legacy_cancel_archive" > /dev/null
legacy_receipt_artifact=$receipt_root/$(jq -r '.migration.receipt.path' "$legacy_cancel_archive")
[[ -f $legacy_receipt_artifact && ! -L $legacy_receipt_artifact ]]
[[ $(stat -c '%u|%a|%h' "$legacy_receipt_artifact") == "$EUID|400|1" ]]
[[ $(sha256sum "$legacy_receipt_artifact" | cut -d ' ' -f 1) == \
  $(jq -r '.migration.receipt.sha256' "$legacy_cancel_archive") ]]
rm -- "$candidate/sw/bin/dotfiles-rebuild"
cp -- "$rebuild" "$candidate/sw/bin/dotfiles-rebuild"
chmod +x "$candidate/sw/bin/dotfiles-rebuild"

# rollback protocol を持たない recovery target には、実行不能な rollback を案内しない。
mv -- "$previous/etc/dotfiles/doctor.json" "$test_root/previous-doctor.json"
mv -- "$previous/etc/dotfiles/oci-images.json" "$test_root/previous-oci-images.json"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
guidance_receipt=$receipt_root/active.json
guidance_id=$(jq -r '.transactionId' "$guidance_receipt")
if grep -F -- '--rollback' "$stderr_log" > /dev/null; then
  echo 'incompatible recovery target was advertised for rollback' >&2
  exit 1
fi
grep -F 'Rollback unavailable: recovery target lacks the required doctor or OCI protocol.' \
  "$stderr_log" > /dev/null
grep -F "$candidate/sw/bin/dotfiles-rebuild --abort $guidance_id" "$stderr_log" > /dev/null
mv -- "$test_root/previous-doctor.json" "$previous/etc/dotfiles/doctor.json"
mv -- "$test_root/previous-oci-images.json" "$previous/etc/dotfiles/oci-images.json"
run_rebuild switch '' '' --abort "$guidance_id"
[[ $rebuild_status -eq 0 ]]

# profile commit 後でも outcome がなければ成功を推定せず、activator を再実行する。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
post_commit_receipt=$receipt_root/active.json
post_commit_id=$(jq -r '.transactionId' "$post_commit_receipt")
post_commit_log=$receipt_root/$(jq -r '.activation.attempts[-1].log.path' \
  "$post_commit_receipt")
post_commit_root=${post_commit_log%/*}
mv -T -- "$post_commit_log" "$post_commit_root/activation.log.partial"
# finalize の chmod 後、rename 前で停止した durable transitional state。
chmod 0400 "$post_commit_root/activation.log.partial"
rm -- "$post_commit_root/outcome.json"
rewrite_receipt "$post_commit_receipt" '
  .state = "activating" |
  .activation.status = "pending" |
  .activation.exitCode = null |
  .activation.attempts[-1].status = "running" |
  .activation.attempts[-1].boundary = null |
  .activation.attempts[-1].finishedAt = null |
  .activation.attempts[-1].exitCode = null |
  .activation.attempts[-1].log = null |
  .activation.attempts[-1].outcome = null |
  .failureStage = null
'
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
run_rebuild switch '' activation --resume "$post_commit_id"
if [[ $rebuild_status -ne 4 ]]; then
  printf 'post-profile indeterminate resume returned %s, expected 4\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  sed 's/^/  call: /' "$call_log" >&2
  exit 1
fi
assert_apply switch
jq -e '
  .state == "activation-failed" and
  (.activation.attempts | length) == 2 and
  .activation.attempts[0].status == "indeterminate" and
  .activation.attempts[0].boundary == "after-profile-commit" and
  .activation.attempts[1].status == "failed" and
  .activation.attempts[1].exitCode == 71
' "$post_commit_receipt" > /dev/null
run_rebuild switch '' '' --rollback "$post_commit_id"
if [[ $rebuild_status -ne 0 ]]; then
  printf 'post-profile rollback returned %s, expected 0\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
jq -e '.state == "rolled-back"' "$receipt_root/receipts/$post_commit_id.json" > /dev/null

# 成功 outcome が durable なら、target を再 activation せず verification へ進む。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$displaced_profile" > "$profile_state"
run_rebuild switch '' activation
[[ $rebuild_status -eq 4 ]]
durable_success_receipt=$receipt_root/active.json
durable_success_id=$(jq -r '.transactionId' "$durable_success_receipt")
durable_success_log=$receipt_root/$(jq -r '.activation.attempts[-1].log.path' \
  "$durable_success_receipt")
durable_success_root=${durable_success_log%/*}
jq --arg candidate "$candidate" --arg booted "$previous" '
  .exitCode = 0 |
  .boundary = "after-profile-commit" |
  .observedRuntime = {current: $candidate, booted: $booted, profile: $candidate}
' "$durable_success_root/outcome.json" > "$durable_success_root/outcome.json.tmp"
mv -T -- "$durable_success_root/outcome.json.tmp" "$durable_success_root/outcome.json"
chmod 0600 "$durable_success_root/outcome.json"
rewrite_receipt "$durable_success_receipt" '
  .state = "activating" |
  .activation.status = "pending" |
  .activation.exitCode = null |
  .activation.attempts[-1].status = "running" |
  .activation.attempts[-1].boundary = null |
  .activation.attempts[-1].finishedAt = null |
  .activation.attempts[-1].exitCode = null |
  .activation.attempts[-1].log = null |
  .activation.attempts[-1].outcome = null |
  .failureStage = null
'
printf '%s\n' "$candidate" > "$current_state"
printf '%s\n' "$candidate" > "$profile_state"
run_rebuild switch '' '' --resume "$durable_success_id"
if [[ $rebuild_status -ne 0 ]]; then
  printf 'durable successful outcome resume returned %s, expected 0\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
reject_call 'system-activator'
require_call 'dotfiles-doctor'
jq -e '
  .state == "complete" and
  .activation.status == "succeeded" and
  .activation.exitCode == 0 and
  .activation.attempts[-1].status == "succeeded" and
  .activation.attempts[-1].boundary == "after-profile-commit" and
  .activation.attempts[-1].exitCode == 0 and
  .verification.status == "succeeded"
' "$receipt_root/receipts/$durable_success_id.json" > /dev/null

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
assert_snapshot_pipeline no
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
