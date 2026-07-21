#!/usr/bin/env bash
set -Eeuo pipefail

report_test_failure() {
  local status=$?
  if [[ $- == *e* && ${BASH_SUBSHELL:-0} -eq 0 ]]; then
    printf 'rebuild routing test stopped at line %s (status %s)\n' \
      "${BASH_LINENO[0]}" "$status" >&2
  fi
  return "$status"
}
trap report_test_failure ERR

rebuild_source=${1:?rebuild source path is required}
bash_path=${2:?bash path is required}
fakeroot_path=${3:?fakeroot path is required}
atomic_file_source=${4:?atomic file source path is required}
operation_lock_source=${5:?operation lock source path is required}
receipt_source=${6:?rebuild receipt source path is required}
attempt_source=${7:?rebuild attempt source path is required}
probe_mode=${8:-full}
gc_probe=0
[[ $probe_mode == gc-erasure-integration || $probe_mode == gc-erasure-mutant ]] && gc_probe=1
controller_probe=0
[[ $probe_mode == authorized-controller ]] && controller_probe=1
test_root=$(mktemp -d)
trap 'chmod -R u+w -- "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

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
real_rm=$(command -v rm)
real_mv=$(command -v mv)
real_stat=$(command -v stat)
legacy_nixpkgs_rev=bd0ff2d3eac24699c3664d5966b9ef36f388e2ca
legacy_nixos_rebuild_path=$store_dir/legacy-nixos-rebuild/bin/nixos-rebuild
legacy_helper_fixture=$store_dir/legacy-dotfiles-rebuild/bin/dotfiles-rebuild

mkdir -p \
  "$repo/.git" "$fake_bin" "$wrapper_bin" "$candidate/sw/bin" "$candidate/etc/dotfiles" "$source_path" \
  "$previous/sw/bin" "$previous/etc/dotfiles" "$displaced_profile" "$nix_gc_auto_roots" \
  "$source_path/modules/commands" "${system_profile_path%/*}" "${legacy_helper_fixture%/*}"
chmod 0555 "$nix_gc_auto_roots"
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
  | sed "/@atomicFileFunctions@/ { r $atomic_file_source
    d
  }" \
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
    if [[ ${TEST_KILL_DURING_NIX_ROOT_KIND:-} == direct-temp &&
      ${2##*/} == "${TEST_KILL_DURING_NIX_ROOT_LABEL:-}" ]]; then
      ln -sfn -- "$4" "$2.tmp-123-456"
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    ln -sfn -- "$4" "$2"
    if [[ ${TEST_KILL_DURING_NIX_ROOT_KIND:-} == direct-only &&
      ${2##*/} == "${TEST_KILL_DURING_NIX_ROOT_LABEL:-}" ]]; then
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    auto_name=$(printf '%s' "$2" | sha256sum | cut -d ' ' -f 1 | tr e z | cut -c 1-32)
    chmod 0755 "$TEST_NIX_AUTO_ROOTS_DIR"
    if [[ ${TEST_KILL_DURING_NIX_ROOT_KIND:-} == auto-temp &&
      ${2##*/} == "${TEST_KILL_DURING_NIX_ROOT_LABEL:-}" ]]; then
      ln -sfn -- "$2" "$TEST_NIX_AUTO_ROOTS_DIR/$auto_name.tmp-789-1011"
      chmod 0555 "$TEST_NIX_AUTO_ROOTS_DIR"
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    ln -sfn -- "$2" "$TEST_NIX_AUTO_ROOTS_DIR/$auto_name"
    chmod 0555 "$TEST_NIX_AUTO_ROOTS_DIR"
    if [[ -n ${TEST_KILL_AFTER_NIX_ROOT_LABEL:-} &&
      ${2##*/} == "$TEST_KILL_AFTER_NIX_ROOT_LABEL" ]]; then
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    if [[ -n ${TEST_RUNTIME_AFTER_PERSISTENT_ROOT:-} && $2 == */displaced-profile &&
      ! -e $TEST_RUNTIME_DRIFT_MARKER ]]; then
      printf '%s\n' "$TEST_RUNTIME_AFTER_PERSISTENT_ROOT" > "$TEST_CURRENT_STATE"
      printf '%s\n' "$TEST_RUNTIME_AFTER_PERSISTENT_ROOT" > "$TEST_PROFILE_STATE"
      : > "$TEST_RUNTIME_DRIFT_MARKER"
    fi
    if [[ ${TEST_TAMPER_LINEAGE_AFTER_ROOT:-0} == 1 && $2 == */displaced-profile ]]; then
      lineage_artifact=$(find "$TEST_COMMON_GIT_DIR/dotfiles-rebuild/lineage" \
        -type f -name verification-failed.json -print -quit)
      chmod 0600 "$lineage_artifact"
      printf '\n' >> "$lineage_artifact"
      chmod 0400 "$lineage_artifact"
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
  rm)
    for argument in "$@"; do
      if [[ -n ${TEST_KILL_RM_TARGET:-} && $argument == "$TEST_KILL_RM_TARGET" ]]; then
        kill -KILL "${TEST_REBUILD_PID:-$PPID}"
        exit 137
      fi
      if [[ -n ${TEST_KILL_AFTER_RM_TARGET:-} &&
        $argument == "$TEST_KILL_AFTER_RM_TARGET" ]]; then
        "$REAL_RM" "$@"
        kill -KILL "${TEST_REBUILD_PID:-$PPID}"
        exit 137
      fi
    done
    exec "$REAL_RM" "$@"
    ;;
  mv)
    source_path=${@: -2:1}
    destination=${!#}
    case ${TEST_KILL_BEFORE_MV_KIND:-}:$source_path in
      preparation:*/.preparation.* | preparation:*/.successor-preparation-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
      authorization:*/.authorization.* | authorization:*/.successor-authorization-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
      erasure:*/.erasure.* | erasure:*/.successor-erasure-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
      lineage:*/.successor-lineage-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
      handoff:*/.successor-handoff-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
      archive:*/.successor-archive-*)
        kill -KILL "${TEST_REBUILD_PID:-$PPID}" "$PPID" 2>/dev/null || true
        exit 137
        ;;
    esac
    if [[ -n ${TEST_KILL_AFTER_MV_TARGET:-} &&
      $destination == "$TEST_KILL_AFTER_MV_TARGET" ]]; then
      "$REAL_MV" "$@"
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    if [[ -n ${TEST_KILL_AFTER_MV_MATCH:-} &&
      $destination == *"$TEST_KILL_AFTER_MV_MATCH"* ]]; then
      "$REAL_MV" "$@"
      kill -KILL "${TEST_REBUILD_PID:-$PPID}"
      exit 137
    fi
    exec "$REAL_MV" "$@"
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

for command in git nix nom nvd dotfiles-wsl-restart-required nixos-rebuild system-activator nix-store readlink systemctl sync rm mv; do
  ln -s command-stub "$fake_bin/$command"
done
ln -s "$fake_bin/command-stub" "$sudo_wrapper"

cat > "$fake_bin/stat" <<'STAT_STUB'
#!@bash@
set -euo pipefail
target=${!#}
if [[ -n ${TEST_STAT_UID_TARGET:-} && $target == "$TEST_STAT_UID_TARGET" &&
  $* == *"%u|%g|%a|%h"* ]]; then
  metadata=$($REAL_STAT "$@")
  IFS='|' read -r _ gid mode links <<< "$metadata"
  printf '%s|%s|%s|%s\n' 65534 "$gid" "$mode" "$links"
  exit 0
fi
if [[ -n ${TEST_STAT_GID_TARGET:-} && $target == "$TEST_STAT_GID_TARGET" &&
  $* == *"%u|%g|%a|%h"* ]]; then
  metadata=$($REAL_STAT "$@")
  IFS='|' read -r uid _ mode links <<< "$metadata"
  printf '%s|%s|%s|%s\n' "$uid" 65534 "$mode" "$links"
  exit 0
fi
exec "$REAL_STAT" "$@"
STAT_STUB
sed -i "1s|@bash@|$bash_path|" "$fake_bin/stat"
chmod +x "$fake_bin/stat"

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
if [[ ${TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS:-0} == 1 &&
  -n ${TEST_AUTHORIZED_CHILD:-} ]]; then
  chmod 0600 "$TEST_AUTHORIZED_CHILD"
  printf '\n' >> "$TEST_AUTHORIZED_CHILD"
  chmod 0400 "$TEST_AUTHORIZED_CHILD"
fi
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
export TEST_TAMPER_LINEAGE_AFTER_ROOT=0
export TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS=0
export TEST_AUTHORIZED_CHILD=
export TEST_SUDO_COMMAND=$sudo_wrapper
export REAL_READLINK=$real_readlink
export REAL_RM=$real_rm
export REAL_MV=$real_mv
export REAL_STAT=$real_stat
export TEST_STAT_UID_TARGET=
export TEST_STAT_GID_TARGET=
export TEST_KILL_RM_TARGET=
export TEST_KILL_AFTER_RM_TARGET=
export TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_DURING_NIX_ROOT_KIND=
export TEST_KILL_DURING_NIX_ROOT_LABEL=
export TEST_KILL_AFTER_MV_MATCH=
export TEST_KILL_AFTER_NIX_ROOT_LABEL=
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
  export TEST_TAMPER_LINEAGE_AFTER_ROOT=${TEST_TAMPER_LINEAGE_AFTER_ROOT:-0}
  export TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS=${TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS:-0}
  export TEST_AUTHORIZED_CHILD=${TEST_AUTHORIZED_CHILD:-}
  export TEST_RUNTIME_AFTER_PLAN=${TEST_RUNTIME_AFTER_PLAN:-}
  export TEST_RUNTIME_AFTER_PERSISTENT_ROOT=${TEST_RUNTIME_AFTER_PERSISTENT_ROOT:-}
  export TEST_RUNTIME_AFTER_APPLY_INTENT=${TEST_RUNTIME_AFTER_APPLY_INTENT:-}
  export TEST_RUNTIME_AFTER_ROLLBACK_INTENT=${TEST_RUNTIME_AFTER_ROLLBACK_INTENT:-}
  expected_pipeline_current=$(<"$current_state")
  expected_pipeline_booted=$(<"$booted_state")
  shift 3 || true

  set +e
  PATH="$fake_bin:$PATH" "$bash_path" -c \
    'export TEST_REBUILD_PID=$$; exec "$@"' rebuild-launch \
    "$bash_path" "$rebuild" "$@" > "$stdout_log" 2> "$stderr_log"
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
  if [[ $1 == dotfiles-doctor ]]; then
    grep -E '^dotfiles-doctor( |$)' "$call_log" > /dev/null || {
      printf 'missing call: %s\n' "$1" >&2
      sed 's/^/  /' "$call_log" >&2
      exit 1
    }
    return
  fi
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
  if [[ $1 == dotfiles-doctor ]]; then
    if grep -E '^dotfiles-doctor( |$)' "$call_log" > /dev/null; then
      printf 'unexpected call: %s\n' "$1" >&2
      sed 's/^/  /' "$call_log" >&2
      exit 1
    fi
    return
  fi
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
  auto_name=$(printf '%s' "$root" | sha256sum | cut -d ' ' -f 1 | tr e z | cut -c 1-32)
  printf '%s/%s\n' "$nix_gc_auto_roots" "$auto_name"
}

protocol_tree_fingerprint() {
  local directory
  for directory in active.json lineage roots successor-preparations successors \
    successor-erasures successor-garbage; do
    [[ -e $receipt_root/$directory || -L $receipt_root/$directory ]] || continue
    find "$receipt_root/$directory" -printf '%p|%y|%u|%g|%m|%s|%l\n'
    find "$receipt_root/$directory" -type f -exec sha256sum -- {} +
  done | sort
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

# successor erasure の persistent root record は、child/label/desired target へ
# 一意に束縛される。record 自身が別 root を指す余地を残さない。
# shellcheck disable=SC1090 # fixture へ渡された production receipt library を直接検証する。
source "$receipt_source"
contract_state_root=$test_root/contract-state
contract_child_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
contract_desired_roots=$(jq -cn --arg stateRoot "$contract_state_root" --arg child "$contract_child_id" '
  {
    source: ($stateRoot + "/roots/" + $child + "/source"),
    candidate: ($stateRoot + "/roots/" + $child + "/candidate"),
    "recovery-target": ($stateRoot + "/roots/" + $child + "/recovery-target"),
    "previous-booted": ($stateRoot + "/roots/" + $child + "/previous-booted"),
    "displaced-profile": ($stateRoot + "/roots/" + $child + "/displaced-profile")
  }
')
contract_root_record=$(jq -cn \
  --arg path "$contract_state_root/roots/$contract_child_id/source" \
  --arg target "$(jq -r '.source' <<< "$contract_desired_roots")" \
  --arg metadata "$EUID|$(id -g)|777|1" \
  '{path: $path, target: $target, metadata: $metadata}')
dotfiles_rebuild_validate_erasure_root_record \
  "$contract_state_root" "$contract_child_id" source \
  "$contract_desired_roots" "$contract_root_record" "$EUID" "$(id -g)"
set +e
dotfiles_rebuild_validate_erasure_root_record \
  "$contract_state_root" "$contract_child_id" source "$contract_desired_roots" \
  "$(jq -c '.unexpected = true' <<< "$contract_root_record")" "$EUID" "$(id -g)"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]
set +e
dotfiles_rebuild_validate_erasure_root_record \
  "$contract_state_root" "$contract_child_id" source "$contract_desired_roots" \
  "$(jq -c '.path = "'"$contract_state_root"'/roots/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/source"' \
    <<< "$contract_root_record")" "$EUID" "$(id -g)"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]
set +e
dotfiles_rebuild_validate_erasure_root_record \
  "$contract_state_root" "$contract_child_id" source "$contract_desired_roots" \
  "$(jq -c '.target = "'"$store_dir"'/forged"' <<< "$contract_root_record")" \
  "$EUID" "$(id -g)"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]

# lineage artifact は receipt 内容だけでなく、owner-independent な file identity
# （GID、mode、link countを含む）も満たす必要がある。
contract_lineage_artifact=$test_root/contract-lineage.json
printf '%s\n' '{}' > "$contract_lineage_artifact"
chmod 0400 "$contract_lineage_artifact"
PATH="$fake_bin:$PATH" dotfiles_rebuild_validate_lineage_artifact_file \
  "$contract_lineage_artifact" "$EUID" "$(id -g)"
TEST_STAT_GID_TARGET=$contract_lineage_artifact
export TEST_STAT_GID_TARGET
set +e
PATH="$fake_bin:$PATH" dotfiles_rebuild_validate_lineage_artifact_file \
  "$contract_lineage_artifact" "$EUID" "$(id -g)"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]
TEST_STAT_GID_TARGET=
export TEST_STAT_GID_TARGET

# scanner は各protocol artifactを同じ parent -> child graphとして扱う。
# 同じedgeの重複表現は許すが、childの逆引きは一意でcycleを持たない。
contract_parent_id=11111111111111111111111111111111
contract_active_child_id=22222222222222222222222222222222
contract_grandchild_id=33333333333333333333333333333333
dotfiles_rebuild_validate_successor_edge_graph \
  "$contract_active_child_id" "$contract_parent_id" \
  "$contract_parent_id:$contract_active_child_id" \
  "$contract_parent_id:$contract_active_child_id"
set +e
dotfiles_rebuild_validate_successor_edge_graph \
  "$contract_active_child_id" "$contract_parent_id" \
  "$contract_parent_id:$contract_grandchild_id" \
  "$contract_active_child_id:$contract_grandchild_id"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]
set +e
dotfiles_rebuild_validate_successor_edge_graph \
  "$contract_active_child_id" "$contract_parent_id" \
  "$contract_parent_id:$contract_active_child_id" \
  "$contract_active_child_id:$contract_parent_id"
contract_status=$?
set -e
[[ $contract_status -eq 1 ]]

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

# active receipt の中断tempをstatus/planは変更せずstatus 2で報告し、通常apply
# だけが全候補のidentity検証後に回収する。
active_publication_root=$repo/.git/dotfiles-rebuild
mkdir -m 0700 -- "$active_publication_root" "$active_publication_root/receipts" \
  "$active_publication_root/roots"
active_publication_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
active_publication_temp=$active_publication_root/.active-create-$active_publication_id.abcdef
printf '%s' '{"transactionId":' > "$active_publication_temp"
chmod 0600 "$active_publication_temp"
active_publication_before=$(find "$active_publication_root" \
  -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active receipt publication is incomplete' "$stderr_log" > /dev/null
[[ $(find "$active_publication_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == \
  "$active_publication_before" ]]
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 2 ]]
grep -F 'active receipt publication is incomplete' "$stderr_log" > /dev/null
[[ $(find "$active_publication_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == \
  "$active_publication_before" ]]
run_rebuild switch '' snapshot
if [[ $rebuild_status -ne 70 ]]; then
  printf 'active publication cleanup probe returned %s, expected 70\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  exit 1
fi
[[ ! -e $active_publication_temp && ! -L $active_publication_temp ]]

active_publication_temp=$active_publication_root/.active-create-$active_publication_id.abcdef
jq -n --arg id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '{transactionId: $id}' \
  > "$active_publication_temp"
chmod 0600 "$active_publication_temp"
active_publication_before=$(find "$active_publication_temp" -maxdepth 0 \
  -printf '%p|%y|%u|%g|%m|%h|%s|%l\n')
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active receipt publication temp state is invalid' "$stderr_log" > /dev/null
[[ $(find "$active_publication_temp" -maxdepth 0 \
  -printf '%p|%y|%u|%g|%m|%h|%s|%l\n') == "$active_publication_before" ]]
rm -- "$active_publication_temp"
rm -r -- "$active_publication_root"
[[ $probe_mode != active-publication-integration ]] || exit 0

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
export TEST_SYNC_FAIL_MATCH='/.active-'
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

[[ $probe_mode != active-sync-failure ]] || exit 0

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
  chmod 0755 "$nix_gc_auto_roots"
  rm "$registration"
  chmod 0555 "$nix_gc_auto_roots"
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
grep -F "  nix run $repo#dotfiles-rebuild -- --forward-recover $transaction_id" \
  "$stderr_log" > /dev/null
if grep -F "  $candidate/sw/bin/dotfiles-rebuild --forward-recover $transaction_id" \
  "$stderr_log" > /dev/null; then
  echo 'doctor failure delegated successor creation to the unrepaired candidate controller' >&2
  exit 1
fi
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

# active receipt がないとき、successors/ に正当な entry は一つも存在しない。
# status / plan / apply は entry の種類や名前にかかわらず、状態を変えずに拒否する。
mkdir -p "$receipt_root/successors"
chmod 0700 "$receipt_root/successors"
idle_successor_id=77777777777777777777777777777777
idle_successor_child_id=88888888888888888888888888888888
for idle_successor_kind in unknown symlink fifo canonical hidden; do
  case $idle_successor_kind in
    unknown)
      idle_successor_entry=$receipt_root/successors/.unknown
      : > "$idle_successor_entry"
      ;;
    symlink)
      idle_successor_entry=$receipt_root/successors/orphan-symlink
      ln -s -- "$test_root/missing-idle-successor" "$idle_successor_entry"
      ;;
    fifo)
      idle_successor_entry=$receipt_root/successors/orphan-fifo
      mkfifo -- "$idle_successor_entry"
      ;;
    canonical)
      idle_successor_entry=$receipt_root/successors/$idle_successor_id
      mkdir -m 0700 -- "$idle_successor_entry"
      ;;
    hidden)
      idle_successor_entry=$receipt_root/successors/.garbage-$idle_successor_id-$idle_successor_child_id
      mkdir -m 0700 -- "$idle_successor_entry"
      ;;
  esac
  idle_successor_before=$(find "$receipt_root/successors" \
    -printf '%p|%y|%m|%s|%l\n' | sort)
  for idle_mode in status plan apply; do
    case $idle_mode in
      status) run_rebuild switch '' '' --status ;;
      plan) run_rebuild switch '' '' --plan ;;
      apply) run_rebuild switch '' '' ;;
    esac
    [[ $rebuild_status -eq 2 ]]
    grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
    [[ $(find "$receipt_root/successors" \
      -printf '%p|%y|%m|%s|%l\n' | sort) == "$idle_successor_before" ]]
    reject_call '#sourceSnapshot'
    reject_call 'nix flake check'
    reject_call 'nixos-rebuild'
  done
  if [[ -d $idle_successor_entry && ! -L $idle_successor_entry ]]; then
    rmdir -- "$idle_successor_entry"
  else
    rm -- "$idle_successor_entry"
  fi
done

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

# doctor 自体の欠陥で配備済み candidate を検証できない場合、新しい immutable candidate へ
# 明示的な successor transaction を作る。元 transaction の --resume 意味は変更しない。
printf '%s\n' "$previous" > "$current_state"
printf '%s\n' "$previous" > "$booted_state"
printf '%s\n' "$previous" > "$profile_state"
export TEST_CANDIDATE=$candidate
export TEST_DOCTOR_STATUS=1
export TEST_DOCTOR_REPORT=valid
run_rebuild switch '' ''
[[ $rebuild_status -eq 5 ]]
parent_receipt=$receipt_root/active.json
parent_id=$(jq -r '.transactionId' "$parent_receipt")
parent_exact=$test_root/parent-exact.json
cp -- "$parent_receipt" "$parent_exact"
parent_sha=$(sha256sum "$parent_exact" | cut -d ' ' -f 1)
grep -F -- "--forward-recover $parent_id" "$stderr_log" > /dev/null

if [[ $gc_probe -eq 1 ]]; then
  successor=$store_dir/successor-system
  mkdir -p "$successor/sw/bin" "$successor/etc/dotfiles"
  cp -- "$rebuild" "$successor/sw/bin/dotfiles-rebuild"
  cp -- "$candidate/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-doctor"
  cp -- "$candidate/sw/bin/dotfiles-sync-images" "$successor/sw/bin/dotfiles-sync-images"
  chmod +x "$successor/sw/bin/dotfiles-rebuild" \
    "$successor/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-sync-images"
  printf '%s\n' '{"schemaVersion":4}' > "$successor/etc/dotfiles/doctor.json"
  printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$successor/etc/dotfiles/oci-images.json"
  export TEST_CANDIDATE=$successor
elif [[ $controller_probe -eq 1 ]]; then
  successor=$store_dir/successor-system
  mkdir -p "$successor/sw/bin" "$successor/etc/dotfiles"
  cp -- "$rebuild" "$successor/sw/bin/dotfiles-rebuild"
  cp -- "$candidate/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-doctor"
  cp -- "$candidate/sw/bin/dotfiles-sync-images" "$successor/sw/bin/dotfiles-sync-images"
  sed -i '2i\
[[ -z ${TEST_AUTHORIZED_CONTROLLER_MARKER:-} ]] || printf "%s\\n" "$0" >> "$TEST_AUTHORIZED_CONTROLLER_MARKER"' \
    "$successor/sw/bin/dotfiles-rebuild"
  chmod +x "$successor/sw/bin/dotfiles-rebuild" \
    "$successor/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-sync-images"
  printf '%s\n' '{"schemaVersion":4}' > "$successor/etc/dotfiles/doctor.json"
  printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$successor/etc/dotfiles/oci-images.json"
  export TEST_CANDIDATE=$successor
else
# successor state は authorization.json の有無だけで判定しない。壊れた symlink や
# 書きかけの directory があれば、status も recovery 操作も read-only に失敗する。
mkdir -p "$receipt_root/successors"
chmod 0700 "$receipt_root/successors"
ln -s -- "$test_root/missing-successor" "$receipt_root/successors/$parent_id"
dangling_successor_before=$(find "$receipt_root/successors" \
  -printf '%p|%y|%m|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$receipt_root/successors" -printf '%p|%y|%m|%s|%l\n' | sort) == \
  "$dangling_successor_before" ]]
run_rebuild switch '' '' --resume "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$receipt_root/successors" -printf '%p|%y|%m|%s|%l\n' | sort) == \
  "$dangling_successor_before" ]]
rm -- "$receipt_root/successors/$parent_id"

unknown_successor_id=66666666666666666666666666666666
mkdir -m 0700 -- "$receipt_root/successors/$unknown_successor_id"
unknown_successor_before=$(find "$receipt_root/successors" \
  -printf '%p|%y|%m|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$receipt_root/successors" -printf '%p|%y|%m|%s|%l\n' | sort) == \
  "$unknown_successor_before" ]]
rm -r -- "$receipt_root/successors/$unknown_successor_id"

# SOPS enrollment に束縛された transaction は独立して引き継がない。
rewrite_receipt "$parent_receipt" \
  '.sopsEnrollmentTransactionId = "0123456789abcdef0123456789abcdef"'
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'SOPS enrollment-bound transaction cannot be forward-recovered' "$stderr_log" > /dev/null
reject_call '#sourceSnapshot'
rewrite_receipt "$parent_receipt" '.sopsEnrollmentTransactionId = null'
cp -- "$parent_receipt" "$parent_exact"
parent_sha=$(sha256sum "$parent_exact" | cut -d ' ' -f 1)

successor=$store_dir/successor-system
mkdir -p "$successor/sw/bin" "$successor/etc/dotfiles"
cp -- "$rebuild" "$successor/sw/bin/dotfiles-rebuild"
cp -- "$candidate/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-doctor"
cp -- "$candidate/sw/bin/dotfiles-sync-images" "$successor/sw/bin/dotfiles-sync-images"
sed -i '2i\
[[ -z ${TEST_AUTHORIZED_CONTROLLER_MARKER:-} ]] || printf "%s\\n" "$0" >> "$TEST_AUTHORIZED_CONTROLLER_MARKER"' \
  "$successor/sw/bin/dotfiles-rebuild"
chmod +x "$successor/sw/bin/dotfiles-rebuild" \
  "$successor/sw/bin/dotfiles-doctor" "$successor/sw/bin/dotfiles-sync-images"
printf '%s\n' '{"schemaVersion":4}' > "$successor/etc/dotfiles/doctor.json"
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$successor/etc/dotfiles/oci-images.json"
export TEST_CANDIDATE=$successor

# OCI capability が不正なcandidateは、child/auth/rootsを永続化する前に拒否する。
successor_manifest=$successor/etc/dotfiles/oci-images.json
successor_manifest_exact=$test_root/successor-oci-images.exact.json
cp -- "$successor_manifest" "$successor_manifest_exact"
capability_state_before=$(find "$receipt_root" -printf '%p|%y|%m|%s|%l\n' | sort)
printf '%s\n' '{"schemaVersion":1,"images":[]}' > "$successor_manifest"
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'candidate target requires OCI image manifest schema version 2' "$stderr_log" > /dev/null
[[ $(find "$receipt_root" -printf '%p|%y|%m|%s|%l\n' | sort) == "$capability_state_before" ]]
cp -- "$successor_manifest_exact" "$successor_manifest"

chmod -x "$successor/sw/bin/dotfiles-sync-images"
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'target does not contain an executable OCI image sync helper' \
  "$stderr_log" > /dev/null
[[ $(find "$receipt_root" -printf '%p|%y|%m|%s|%l\n' | sort) == "$capability_state_before" ]]
chmod +x "$successor/sw/bin/dotfiles-sync-images"

successor_publish_temp() {
  local kind=$1
  find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name ".successor-$kind-$parent_id-*.*" -type f -print -quit
}

assert_publish_temp_is_observed_read_only() {
  local kind=$1 temporary before metadata
  temporary=$(successor_publish_temp "$kind")
  [[ -n $temporary ]]
  metadata=$(stat -c '%u|%g|%a|%h' "$temporary")
  [[ $metadata == "$EUID|$(id -g)|400|1" ||
    $metadata == "$EUID|$(id -g)|600|1" ]]
  before=$(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -printf '%p|%y|%u|%g|%m|%s|%l\n' | sort)
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication is incomplete' "$stderr_log" > /dev/null
  [[ $(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -printf '%p|%y|%u|%g|%m|%s|%l\n' | sort) == "$before" ]]
  run_rebuild switch '' '' --plan
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication is incomplete' "$stderr_log" > /dev/null
  [[ $(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -printf '%p|%y|%u|%g|%m|%s|%l\n' | sort) == "$before" ]]
}

assert_no_publish_temps() {
  [[ -z $(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -print -quit) ]]
}

# rename前にkillされても一時fileはauthority directoryを汚さない。status/planは
# 観測だけを行い、次のforward/cancel effectがidentity検証後に回収する。
publish_temp_child_id=99999999999999999999999999999999
valid_partial_temp=$receipt_root/.successor-preparation-$parent_id-$publish_temp_child_id.abcdef
printf '%s\n' 'partial' > "$valid_partial_temp"
chmod 0600 "$valid_partial_temp"
assert_publish_temp_is_observed_read_only preparation

assert_invalid_publish_temp_rejected() {
  local entry=$1 before
  before=$(find "$entry" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%s|%l\n')
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication temp state is invalid' "$stderr_log" > /dev/null
  [[ $(find "$entry" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%s|%l\n') == "$before" ]]
  run_rebuild switch '' '' --plan
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication temp state is invalid' "$stderr_log" > /dev/null
  [[ $(find "$entry" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%s|%l\n') == "$before" ]]
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication temp state is invalid' "$stderr_log" > /dev/null
  reject_call '#sourceSnapshot'
  [[ $(find "$entry" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%s|%l\n') == "$before" ]]
}

invalid_publish_temp=$receipt_root/.successor-unknown-$parent_id-$publish_temp_child_id.abcdef
printf '%s\n' 'unknown' > "$invalid_publish_temp"
chmod 0400 "$invalid_publish_temp"
assert_invalid_publish_temp_rejected "$invalid_publish_temp"
rm -- "$invalid_publish_temp"

invalid_publish_target=$test_root/invalid-publish-target
printf '%s\n' 'symlink' > "$invalid_publish_target"
invalid_publish_temp=$receipt_root/.successor-authorization-$parent_id-$publish_temp_child_id.abcdef
ln -s -- "$invalid_publish_target" "$invalid_publish_temp"
assert_invalid_publish_temp_rejected "$invalid_publish_temp"
rm -- "$invalid_publish_temp"

for invalid_publish_identity in uid gid mode links; do
  invalid_publish_temp=$receipt_root/.successor-erasure-$parent_id-$publish_temp_child_id.abcdef
  printf '%s\n' "$invalid_publish_identity" > "$invalid_publish_temp"
  chmod 0400 "$invalid_publish_temp"
  case $invalid_publish_identity in
    uid)
      TEST_STAT_UID_TARGET=$invalid_publish_temp
      export TEST_STAT_UID_TARGET
      ;;
    gid)
      TEST_STAT_GID_TARGET=$invalid_publish_temp
      export TEST_STAT_GID_TARGET
      ;;
    mode) chmod 0644 "$invalid_publish_temp" ;;
    links) ln "$invalid_publish_temp" "$test_root/invalid-publish-hardlink" ;;
  esac
  assert_invalid_publish_temp_rejected "$invalid_publish_temp"
  TEST_STAT_UID_TARGET=
  TEST_STAT_GID_TARGET=
  export TEST_STAT_UID_TARGET TEST_STAT_GID_TARGET
  [[ ! -e $test_root/invalid-publish-hardlink ]] || rm -- "$test_root/invalid-publish-hardlink"
  rm -- "$invalid_publish_temp"
done

export TEST_OCI_STATUS_CANDIDATE=1
TEST_KILL_BEFORE_MV_KIND=preparation
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
[[ ! -e $valid_partial_temp && ! -L $valid_partial_temp ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only preparation
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 1 ]]
assert_no_publish_temps
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
if [[ $rebuild_status -ne 0 ]]; then
  printf 'cancel after preparation-temp recovery returned %s, expected 0\n' \
    "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  sed 's/^/  /' "$call_log" >&2
  find "$receipt_root" -mindepth 1 -maxdepth 1 \
    \( -name '.successor-*' -o -name 'successor-*' -o -name 'lineage' -o -name 'roots' \) \
    -printf '  %p|%y|%u|%g|%m|%s|%l\n' | sort >&2
  exit 1
fi

TEST_KILL_BEFORE_MV_KIND=lineage
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only lineage
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 0 ]]
assert_no_publish_temps

TEST_KILL_BEFORE_MV_KIND=authorization
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only authorization
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 1 ]]
assert_no_publish_temps

TEST_KILL_BEFORE_MV_KIND=erasure
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only erasure
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 0 ]]
assert_no_publish_temps
export TEST_OCI_STATUS_CANDIDATE=0

# candidate helper は見かけ上 executable でも、store 外のmutable targetへ解決する
# symlinkなら、parent lineage/child/authを作る前に拒否する。
for helper_name in dotfiles-rebuild dotfiles-doctor dotfiles-sync-images; do
  helper_path_under_test=$successor/sw/bin/$helper_name
  helper_fixture=$successor/sw/bin/$helper_name.fixture
  external_helper=$test_root/external-$helper_name
  mv -T -- "$helper_path_under_test" "$helper_fixture"
  cp -- "$helper_fixture" "$external_helper"
  chmod +x "$external_helper"
  ln -s -- "$external_helper" "$helper_path_under_test"
  helper_state_before=$(find "$receipt_root" -printf '%p|%y|%m|%s|%l\n' | sort)
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 2 ]]
  [[ $(find "$receipt_root" -printf '%p|%y|%m|%s|%l\n' | sort) == \
    "$helper_state_before" ]]
  rm -- "$helper_path_under_test"
  mv -T -- "$helper_fixture" "$helper_path_under_test"
done

# preparation公開直後のkillは、lineage/rootsを推測で補わず準備receiptだけを残す。
TEST_KILL_AFTER_MV_MATCH="successor-preparations/$parent_id-"
export TEST_KILL_AFTER_MV_MATCH
run_rebuild switch '' '' --forward-recover "$parent_id"
if [[ $rebuild_status -ne 137 ]]; then
  printf 'preparation publication kill returned %s, expected 137\n' "$rebuild_status" >&2
  sed 's/^/  /' "$stderr_log" >&2
  sed 's/^/  /' "$call_log" >&2
  exit 1
fi
TEST_KILL_AFTER_MV_MATCH=
export TEST_KILL_AFTER_MV_MATCH
partial_preparation=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
  -name "$parent_id-*.json" -type f -print -quit)
[[ -n $partial_preparation && ! -e $receipt_root/lineage/$parent_id ]]
partial_preparation_exact=$test_root/partial-preparation-exact.json
cp -- "$partial_preparation" "$partial_preparation_exact"
forged_partial_id=55555555555555555555555555555555
jq --arg childId "$forged_partial_id" '.transactionId = $childId' \
  "$partial_preparation" > "$partial_preparation.replacement"
chmod 0400 "$partial_preparation.replacement"
mv -T -- "$partial_preparation.replacement" "$partial_preparation"
partial_before=$(find "$receipt_root/successor-preparations" \
  -printf '%p|%y|%m|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$receipt_root/successor-preparations" \
  -printf '%p|%y|%m|%s|%l\n' | sort) == "$partial_before" ]]
cp -- "$partial_preparation_exact" "$partial_preparation.replacement"
chmod 0400 "$partial_preparation.replacement"
mv -T -- "$partial_preparation.replacement" "$partial_preparation"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# forward-owned partial cleanupはreason=discard-partialを先に公開する。公開直後のkillは
# 次のforwardだけでrun/retireしてから新edgeへ進む。
partial_child_id=$(jq -r '.transactionId' "$partial_preparation")
discard_erasure=$receipt_root/successor-erasures/$parent_id-$partial_child_id.json
TEST_KILL_AFTER_MV_TARGET=$discard_erasure
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ $(jq -r '.reason' "$discard_erasure") == discard-partial ]]
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# parent lineage artifact公開直後のkillも、同じpartial edgeとして次のforwardで
# erasure cleanupされる。
TEST_KILL_AFTER_MV_TARGET=$receipt_root/lineage/$parent_id/verification-failed.json
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ -f $receipt_root/lineage/$parent_id/verification-failed.json ]]
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# 明示cancelは既存discard-partialも同じzero-effect終端へrun/retireできる。
partial_preparation=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
  -name "$parent_id-*.json" -type f -print -quit)
partial_child_id=$(jq -r '.transactionId' "$partial_preparation")
discard_erasure=$receipt_root/successor-erasures/$parent_id-$partial_child_id.json
TEST_KILL_AFTER_MV_TARGET=$discard_erasure
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ $(jq -r '.reason' "$discard_erasure") == discard-partial ]]
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 0 ]]
[[ ! -e $discard_erasure && ! -e $partial_preparation ]]
fi

if [[ $gc_probe -eq 1 ]]; then
# Nix makeSymlink() の二つのkill境界を、immutable erasureへ記録してから回収する。
# direct tempはuser-ownedなのでcleanupし、daemon auto tempは同一symlinkのまま残す。
for partial_kind in direct-temp direct-temp-dangling direct-only auto-temp; do
  TEST_KILL_DURING_NIX_ROOT_KIND=${partial_kind%-dangling}
  TEST_KILL_DURING_NIX_ROOT_LABEL=source
  export TEST_KILL_DURING_NIX_ROOT_KIND TEST_KILL_DURING_NIX_ROOT_LABEL
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 137 ]]
  TEST_KILL_DURING_NIX_ROOT_KIND=
  TEST_KILL_DURING_NIX_ROOT_LABEL=
  export TEST_KILL_DURING_NIX_ROOT_KIND TEST_KILL_DURING_NIX_ROOT_LABEL

  partial_preparation=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
    -name "$parent_id-*.json" -type f -print -quit)
  partial_child_id=$(jq -r '.transactionId' "$partial_preparation")
  partial_roots=$receipt_root/roots/$partial_child_id
  direct_temp=$partial_roots/source.tmp-123-456
  auto_temp=$(auto_registration_for "$partial_roots/source").tmp-789-1011
  case $partial_kind in
    direct-temp | direct-temp-dangling)
      [[ -L $direct_temp && ! -e $partial_roots/source ]]
      ;;
    direct-only) [[ -L $partial_roots/source && ! -e $auto_temp ]] ;;
    auto-temp) [[ -L $partial_roots/source && -L $auto_temp ]] ;;
  esac
  detached_store_target=
  if [[ $partial_kind == direct-temp-dangling ]]; then
    partial_store_target=$(readlink -- "$direct_temp")
    detached_store_target=$test_root/detached-${partial_store_target##*/}
    mv -T -- "$partial_store_target" "$detached_store_target"
    [[ -L $direct_temp && ! -e $direct_temp ]]
  fi
  partial_before_status=$(protocol_tree_fingerprint)
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 0 ]]
  [[ $(protocol_tree_fingerprint) == "$partial_before_status" ]]

  discard_erasure=$receipt_root/successor-erasures/$parent_id-$partial_child_id.json
  TEST_KILL_AFTER_MV_TARGET=$discard_erasure
  export TEST_KILL_AFTER_MV_TARGET
  run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
  [[ $rebuild_status -eq 137 ]]
  TEST_KILL_AFTER_MV_TARGET=
  export TEST_KILL_AFTER_MV_TARGET
  if [[ $probe_mode == gc-erasure-mutant ]]; then
    jq -e '
      .schemaVersion == 1 and
      (has("observedRootTemps") | not) and
      (has("observedAutoRootTemps") | not)
    ' "$discard_erasure" >/dev/null
  else
    jq -e --arg kind "$partial_kind" '
      .schemaVersion == 2 and
      (if ($kind == "direct-temp" or $kind == "direct-temp-dangling") then
         (.observedRootTemps | length) == 1 and
         (.observedRoots | length) == 0 and
         (.observedAutoRootTemps | length) == 0
       elif $kind == "direct-only" then
         (.observedRootTemps | length) == 0 and
         (.observedRoots | length) == 1 and
         (.observedAutoRoots | length) == 0 and
         (.observedAutoRootTemps | length) == 0
       else
         (.observedRootTemps | length) == 0 and
         (.observedAutoRootTemps | length) == 1
       end)
    ' "$discard_erasure" >/dev/null
  fi
  if [[ $partial_kind == auto-temp ]]; then
    auto_temp_before=$(find "$auto_temp" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%l\n')
  fi
  run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
  [[ $rebuild_status -eq 0 ]]
  [[ ! -e $discard_erasure && ! -L $discard_erasure &&
    ! -e $partial_preparation && ! -L $partial_preparation &&
    ! -e $partial_roots && ! -L $partial_roots ]]
  if [[ $partial_kind == auto-temp ]]; then
    [[ $(find "$auto_temp" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%l\n') == \
      "$auto_temp_before" ]]
    chmod 0755 "$nix_gc_auto_roots"
    rm -- "$auto_temp"
    chmod 0555 "$nix_gc_auto_roots"
  fi
  if [[ -n $detached_store_target ]]; then
    mv -T -- "$detached_store_target" "$partial_store_target"
  fi
done
exit 0
fi

if [[ $controller_probe -eq 1 ]]; then
  export TEST_OCI_STATUS_CANDIDATE=1
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 1 ]]
  authorization=$receipt_root/successors/$parent_id.json
  prepared_child=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
    -name "$parent_id-*.json" -type f -print -quit)
  [[ -f $authorization && ! -L $authorization && -f $prepared_child && ! -L $prepared_child ]]
  authorized_child_id=$(jq -r '.child.transactionId' "$authorization")
  grep -F "  $successor/sw/bin/dotfiles-sync-images" "$stderr_log" > /dev/null
  grep -F "  $successor/sw/bin/dotfiles-rebuild --forward-recover $parent_id" \
    "$stderr_log" > /dev/null

  mutable_controller_marker=$test_root/mutable-controller-effect
  authorized_controller_marker=$test_root/authorized-controller-effect
  sed -i '/^resume_authorized_forward_recovery() {/a\
  [[ -z ${TEST_MUTABLE_CONTROLLER_MARKER:-} ]] || printf "%s\\n" resume-authorized >> "$TEST_MUTABLE_CONTROLLER_MARKER"' \
    "$rebuild"
  sed -i '/^cancel_forward_recovery() {/a\
  [[ -z ${TEST_MUTABLE_CONTROLLER_MARKER:-} ]] || printf "%s\\n" cancel-authorized >> "$TEST_MUTABLE_CONTROLLER_MARKER"' \
    "$rebuild"
  export TEST_MUTABLE_CONTROLLER_MARKER=$mutable_controller_marker
  export TEST_AUTHORIZED_CONTROLLER_MARKER=$authorized_controller_marker
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 1 ]]
  [[ ! -e $mutable_controller_marker ]]
  [[ $(wc -l < "$authorized_controller_marker") -eq 1 &&
    $(<"$authorized_controller_marker") == "$successor/sw/bin/dotfiles-rebuild" ]]
  : > "$authorized_controller_marker"
  run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
  [[ $rebuild_status -eq 0 ]]
  [[ ! -e $mutable_controller_marker ]]
  [[ $(wc -l < "$authorized_controller_marker") -eq 1 &&
    $(<"$authorized_controller_marker") == "$successor/sw/bin/dotfiles-rebuild" ]]
  [[ ! -e $authorization && ! -e $prepared_child &&
    ! -e $receipt_root/roots/$authorized_child_id ]]
  exit 0
fi

# 5本のpersistent/auto rootは各作成境界でkillし、存在するauthenticated subsetだけを
# erasureへ記録して再開する。
for partial_root_label in source candidate recovery-target previous-booted displaced-profile; do
  TEST_KILL_AFTER_NIX_ROOT_LABEL=$partial_root_label
  export TEST_KILL_AFTER_NIX_ROOT_LABEL
  run_rebuild switch '' '' --forward-recover "$parent_id"
  [[ $rebuild_status -eq 137 ]]
  TEST_KILL_AFTER_NIX_ROOT_LABEL=
  export TEST_KILL_AFTER_NIX_ROOT_LABEL
  partial_preparation=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
    -name "$parent_id-*.json" -type f -print -quit)
  partial_child_id=$(jq -r '.transactionId' "$partial_preparation")
  [[ -L $receipt_root/roots/$partial_child_id/$partial_root_label ]]
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 0 ]]
done

# readiness が未収束でも immutable child を先に認可し、parent active bytes を保持する。
export TEST_OCI_STATUS_CANDIDATE=1
parent_before_authorization_sha=$(sha256sum "$parent_receipt" | cut -d ' ' -f 1)
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 1 ]]
require_call '#sourceSnapshot'
[[ $(sha256sum "$parent_receipt" | cut -d ' ' -f 1) == "$parent_before_authorization_sha" ]]
authorization=$receipt_root/successors/$parent_id.json
prepared_child=$(find "$receipt_root/successor-preparations" -maxdepth 1 \
  -name "$parent_id-*.json" -type f -print -quit)
[[ -n $prepared_child && -f $prepared_child && ! -L $prepared_child ]]
[[ -f $authorization && ! -L $authorization ]]
[[ $(stat -c '%u|%g|%a|%h' "$authorization") == "$EUID|$(id -g)|400|1" ]]
[[ $(stat -c '%u|%g|%a|%h' "$prepared_child") == "$EUID|$(id -g)|400|1" ]]
[[ $(jq -r '.schemaVersion' "$authorization") -eq 2 ]]
[[ $(jq -r '.lineage.protocolVersion' "$prepared_child") -eq 2 ]]
authorized_child_id=$(jq -r '.child.transactionId' "$authorization")
[[ $(jq -r '.transactionId' "$prepared_child") == "$authorized_child_id" ]]
[[ -d $receipt_root/roots/$authorized_child_id && ! -L $receipt_root/roots/$authorized_child_id ]]
state_before_status=$(find "$prepared_child" "$authorization" "$receipt_root/roots/$authorized_child_id" \
  -printf '%p|%y|%m|%s\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]
[[ $(find "$prepared_child" "$authorization" "$receipt_root/roots/$authorized_child_id" \
  -printf '%p|%y|%m|%s\n' | sort) == "$state_before_status" ]]

ln -s -- "$successor" "$receipt_root/roots/$authorized_child_id/unexpected"
invalid_roots_before=$(find "$prepared_child" "$authorization" "$receipt_root/roots/$authorized_child_id" \
  -printf '%p|%y|%m|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$prepared_child" "$authorization" "$receipt_root/roots/$authorized_child_id" \
  -printf '%p|%y|%m|%s|%l\n' | sort) == "$invalid_roots_before" ]]
rm -- "$receipt_root/roots/$authorized_child_id/unexpected"
chmod 0755 "$receipt_root/roots/$authorized_child_id"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
chmod 0700 "$receipt_root/roots/$authorized_child_id"

# pending authorization 中は parent の既存 recovery 操作でbytesを更新できない。
run_rebuild switch '' '' --resume "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'pending forward recovery blocks parent recovery operations' "$stderr_log" > /dev/null
[[ $(sha256sum "$parent_receipt" | cut -d ' ' -f 1) == "$parent_before_authorization_sha" ]]

# 同じforward-recoverは保存済みchildを再利用し、checkoutを再buildしない。
mutable_controller_marker=$test_root/mutable-controller-effect
authorized_controller_marker=$test_root/authorized-controller-effect
sed -i '/^resume_authorized_forward_recovery() {/a\
  [[ -z ${TEST_MUTABLE_CONTROLLER_MARKER:-} ]] || printf "%s\\n" resume-authorized >> "$TEST_MUTABLE_CONTROLLER_MARKER"' \
  "$rebuild"
sed -i '/^cancel_forward_recovery() {/a\
  [[ -z ${TEST_MUTABLE_CONTROLLER_MARKER:-} ]] || printf "%s\\n" cancel-authorized >> "$TEST_MUTABLE_CONTROLLER_MARKER"' \
  "$rebuild"
export TEST_MUTABLE_CONTROLLER_MARKER=$mutable_controller_marker
export TEST_AUTHORIZED_CONTROLLER_MARKER=$authorized_controller_marker
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 1 ]]
reject_call '#sourceSnapshot'
reject_call 'nix flake check'
reject_call 'nvd diff'
[[ $(jq -r '.child.transactionId' "$authorization") == "$authorized_child_id" ]]
[[ ! -e $mutable_controller_marker ]]
grep -Fqx "$successor/sw/bin/dotfiles-rebuild" "$authorized_controller_marker"

# auth read後に child bytes が変わっても、authorized hash/bytes と異なるactiveを公開しない。
prepared_child_exact=$test_root/prepared-child-exact.json
cp -- "$prepared_child" "$prepared_child_exact"
chmod 0400 "$prepared_child_exact"
export TEST_AUTHORIZED_CHILD=$prepared_child
export TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS=1
export TEST_OCI_STATUS_CANDIDATE=0
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'authorized successor evidence changed during readiness' "$stderr_log" > /dev/null
[[ $(sha256sum "$parent_receipt" | cut -d ' ' -f 1) == "$parent_before_authorization_sha" ]]
[[ -f $authorization && ! -L $authorization ]]
cp -- "$prepared_child_exact" "$prepared_child.tmp"
chmod 0400 "$prepared_child.tmp"
mv -T -- "$prepared_child.tmp" "$prepared_child"
export TEST_TAMPER_AUTHORIZED_CHILD_AT_READINESS=0
export TEST_AUTHORIZED_CHILD=
export TEST_OCI_STATUS_CANDIDATE=1

# auth file identity mismatch はdurability failureではなくinvalid inputとしてstatus 2にする。
chmod 0600 "$authorization"
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
if ! grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null; then
  sed 's/^/authorization-mode stderr: /' "$stderr_log" >&2
  exit 1
fi
chmod 0400 "$authorization"

# authorization はhelperのcanonical path/hash/bytesも固定し、readiness前に再検証する。
authorized_helper=$successor/sw/bin/dotfiles-rebuild
authorized_helper_exact=$test_root/authorized-helper-exact
cp -- "$authorized_helper" "$authorized_helper_exact"
chmod u+w "$authorized_helper"
printf '\n' >> "$authorized_helper"
chmod a-w,+x "$authorized_helper"
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
if ! grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null; then
  sed 's/^/authorization-helper stderr: /' "$stderr_log" >&2
  exit 1
fi
cp -- "$authorized_helper_exact" "$authorized_helper.tmp"
chmod +x "$authorized_helper.tmp"
mv -T -- "$authorized_helper.tmp" "$authorized_helper"

# schema 2 authorization は child execution contract と root key集合を完全一致で束縛する。
authorization_exact=$test_root/authorization-exact.json
cp -- "$authorization" "$authorization_exact"
chmod 0400 "$authorization_exact"

# 同じparentに二つ目のpreparation edgeが見えた時点で、内容を選ばず拒否する。
competing_child_id=44444444444444444444444444444444
competing_preparation=$receipt_root/successor-preparations/$parent_id-$competing_child_id.json
cp -- "$prepared_child" "$competing_preparation"
chmod 0400 "$competing_preparation"
competing_before=$(find "$receipt_root/successor-preparations" \
  -printf '%p|%y|%m|%s|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(find "$receipt_root/successor-preparations" \
  -printf '%p|%y|%m|%s|%l\n' | sort) == "$competing_before" ]]
rm -- "$competing_preparation"

replace_protocol_json() {
  local target=$1 filter=$2 temporary
  shift 2
  temporary=$target.replacement
  jq "$@" "$filter" "$target" > "$temporary"
  chmod 0400 "$temporary"
  mv -T -- "$temporary" "$target"
}

restore_protocol_file() {
  local source=$1 target=$2 temporary
  temporary=$target.replacement
  cp -- "$source" "$temporary"
  chmod 0400 "$temporary"
  mv -T -- "$temporary" "$target"
}

assert_protocol_rejected_read_only() {
  local before
  before=$(find "$receipt_root/successor-preparations" "$receipt_root/successors" \
    "$receipt_root/successor-erasures" "$receipt_root/successor-garbage" \
    -printf '%p|%y|%m|%s|%l\n' 2>/dev/null | sort)
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
  [[ $(find "$receipt_root/successor-preparations" "$receipt_root/successors" \
    "$receipt_root/successor-erasures" "$receipt_root/successor-garbage" \
    -printf '%p|%y|%m|%s|%l\n' 2>/dev/null | sort) == "$before" ]]
}

for execution_role in syncImages doctor; do
  for execution_field in logicalPath sha256 bytes; do
    case $execution_field in
      logicalPath)
        replacement_filter='.child.helpers[$role].logicalPath = (.child.candidate + "/sw/bin/forged")'
        ;;
      sha256)
        replacement_filter='.child.helpers[$role].sha256 = ("f" * 64)'
        ;;
      bytes)
        replacement_filter='.child.helpers[$role].bytes += 1'
        ;;
    esac
    replace_protocol_json "$authorization" "$replacement_filter" --arg role "$execution_role"
    assert_protocol_rejected_read_only
    restore_protocol_file "$authorization_exact" "$authorization"
  done
done

replace_protocol_json "$authorization" '.roots.unexpected = .roots.candidate'
assert_protocol_rejected_read_only
restore_protocol_file "$authorization_exact" "$authorization"

# ownerだけでなくgroup identityもprotocol file identityの一部である。
TEST_STAT_GID_TARGET=$authorization
export TEST_STAT_GID_TARGET
assert_protocol_rejected_read_only
TEST_STAT_GID_TARGET=
export TEST_STAT_GID_TARGET

# status/planはsuccessor treeを一切回収せず、観測だけを行う。
protocol_before_plan=$(protocol_tree_fingerprint)
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 1 ]]
[[ $(protocol_tree_fingerprint) == "$protocol_before_plan" ]]

# erasure公開でlive authorizationは即時失効する。公開直後にkillしてもstatusは
# write-once recordから中間状態を認証し、同じcancelでのみ前進できる。
erasure_file=$receipt_root/successor-erasures/$parent_id-$authorized_child_id.json
TEST_KILL_AFTER_MV_TARGET=$erasure_file
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ -f $erasure_file && -f $authorization && -f $prepared_child ]]
erasure_authorized_controller_count=$(wc -l < "$authorized_controller_marker")

assert_erasure_observable() {
  local before
  before=$(protocol_tree_fingerprint)
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 0 ]]
  [[ $(protocol_tree_fingerprint) == "$before" ]]
}

assert_erasure_observable
protocol_before_plan=$(protocol_tree_fingerprint)
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 1 ]]
[[ $(protocol_tree_fingerprint) == "$protocol_before_plan" ]]
protocol_before_forward=$(protocol_tree_fingerprint)
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F 'erasing forward recovery blocks a new successor' "$stderr_log" > /dev/null
[[ $(protocol_tree_fingerprint) == "$protocol_before_forward" ]]
[[ $(wc -l < "$authorized_controller_marker") -eq \
  $erasure_authorized_controller_count ]]
reject_call '#sourceSnapshot'

# keepRoots=trueはchild handoff専用で、5 persistent rootsと5 auto rootsが欠けた
# cancellation erasureへ書き換えても受理しない。
erasure_exact=$test_root/erasure-exact.json
cp -- "$erasure_file" "$erasure_exact"
chmod 0400 "$erasure_exact"

assert_successor_erasure_rejected() {
  local status
  set +e
  dotfiles_rebuild_validate_successor_erasure \
    "$receipt_root" "$erasure_file" "$parent_receipt" "$EUID" "$(id -g)" \
    "$repo" "$store_dir" "$nix_gc_auto_roots" "$test_user" > /dev/null
  status=$?
  set -e
  [[ $status -eq 1 ]]
}

# observedRoots のrecordはerasure filenameのchildとdesiredRootsへ厳密に束縛する。
# persistent symlinkとrecordを同時に別targetへ揃えても、自己整合だけでは認可しない。
replace_protocol_json "$erasure_file" \
  '.observedRoots.source.path = $path' \
  --arg path "$receipt_root/roots/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/source"
assert_successor_erasure_rejected
restore_protocol_file "$erasure_exact" "$erasure_file"

erasure_source_root=$receipt_root/roots/$authorized_child_id/source
erasure_source_target=$(readlink -- "$erasure_source_root")
forged_erasure_source=$store_dir/forged-erasure-source
mkdir -p -- "$forged_erasure_source"
rm -- "$erasure_source_root"
ln -s -- "$forged_erasure_source" "$erasure_source_root"
replace_protocol_json "$erasure_file" \
  '.observedRoots.source.target = $target' \
  --arg target "$forged_erasure_source"
assert_successor_erasure_rejected
restore_protocol_file "$erasure_exact" "$erasure_file"
rm -- "$erasure_source_root"
ln -s -- "$erasure_source_target" "$erasure_source_root"

replace_protocol_json "$erasure_file" \
  '.keepRoots = true | .observedRoots |= del(.source)'
assert_protocol_rejected_read_only
restore_protocol_file "$erasure_exact" "$erasure_file"

# authorization unlink 後。
TEST_KILL_AFTER_RM_TARGET=$authorization
export TEST_KILL_AFTER_RM_TARGET
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_RM_TARGET=
export TEST_KILL_AFTER_RM_TARGET
[[ ! -e $authorization && ! -L $authorization ]]
[[ $(wc -l < "$authorized_controller_marker") -eq \
  $erasure_authorized_controller_count ]]
grep -Fqx cancel-authorized "$mutable_controller_marker"
assert_erasure_observable

# erasureのauto-root capabilityはGC auto-root直下の1 symlinkだけを指し、
# literal targetはchild persistent rootそのものでなければならない。
prepared_child_detached=$test_root/prepared-child-detached.json
mv -T -- "$prepared_child" "$prepared_child_detached"
erasure_auto_root=$(jq -r '.observedAutoRoots[0].path' "$erasure_file")
erasure_auto_literal=$(jq -r '.observedAutoRoots[0].literalTarget' "$erasure_file")
external_auto_root=$test_root/external-auto-root
chmod 0755 "$nix_gc_auto_roots"
rm -- "$erasure_auto_root"
chmod 0555 "$nix_gc_auto_roots"
ln -s -- "$erasure_auto_literal" "$external_auto_root"
external_auto_metadata=$(stat -c '%u|%g|%a|%h' "$external_auto_root")
replace_protocol_json "$erasure_file" \
  '.observedAutoRoots[0].path = $path | .observedAutoRoots[0].metadata = $metadata' \
  --arg path "$external_auto_root" --arg metadata "$external_auto_metadata"
auto_capability_before=$(protocol_tree_fingerprint)
external_auto_before=$(find "$external_auto_root" -printf '%p|%y|%u|%g|%m|%l\n')
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$external_auto_root" -printf '%p|%y|%u|%g|%m|%l\n') == \
  "$external_auto_before" ]]
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$external_auto_root" -printf '%p|%y|%u|%g|%m|%l\n') == \
  "$external_auto_before" ]]
restore_protocol_file "$erasure_exact" "$erasure_file"
rm -- "$external_auto_root"
chmod 0755 "$nix_gc_auto_roots"
ln -s -- "$erasure_auto_literal" "$erasure_auto_root"
chmod 0555 "$nix_gc_auto_roots"

outside_auto_literal=$test_root/outside-auto-literal
printf '%s\n' preserve-outside-auto-target > "$outside_auto_literal"
chmod 0755 "$nix_gc_auto_roots"
rm -- "$erasure_auto_root"
ln -s -- "$outside_auto_literal" "$erasure_auto_root"
chmod 0555 "$nix_gc_auto_roots"
outside_auto_metadata=$(stat -c '%u|%g|%a|%h' "$erasure_auto_root")
replace_protocol_json "$erasure_file" \
  '.observedAutoRoots[0].literalTarget = $literal | .observedAutoRoots[0].metadata = $metadata' \
  --arg literal "$outside_auto_literal" --arg metadata "$outside_auto_metadata"
auto_capability_before=$(protocol_tree_fingerprint)
auto_root_before=$(find "$erasure_auto_root" -printf '%p|%y|%u|%g|%m|%l\n')
outside_target_before=$(sha256sum "$outside_auto_literal")
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$erasure_auto_root" -printf '%p|%y|%u|%g|%m|%l\n') == \
  "$auto_root_before" ]]
[[ $(sha256sum "$outside_auto_literal") == "$outside_target_before" ]]
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$erasure_auto_root" -printf '%p|%y|%u|%g|%m|%l\n') == \
  "$auto_root_before" ]]
[[ $(sha256sum "$outside_auto_literal") == "$outside_target_before" ]]
restore_protocol_file "$erasure_exact" "$erasure_file"
chmod 0755 "$nix_gc_auto_roots"
rm -- "$erasure_auto_root"
ln -s -- "$erasure_auto_literal" "$erasure_auto_root"
chmod 0555 "$nix_gc_auto_roots"

# auto-root directory自体がsymlinkなら、その配下に見えるpathも外部capabilityである。
auto_roots_detached=$test_root/auto-roots-detached
chmod 0755 "$nix_gc_auto_roots"
mv -T -- "$nix_gc_auto_roots" "$auto_roots_detached"
chmod 0555 "$auto_roots_detached"
ln -s -- "$auto_roots_detached" "$nix_gc_auto_roots"
auto_capability_before=$(protocol_tree_fingerprint)
external_auto_dir_before=$(find "$auto_roots_detached" \
  -printf '%p|%y|%u|%g|%m|%l\n' | sort)
detached_auto_entries_before=$(find "$auto_roots_detached" -mindepth 1 -maxdepth 1 \
  -printf '%f|%y|%l\n' | sort)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$auto_roots_detached" -printf '%p|%y|%u|%g|%m|%l\n' | sort) == \
  "$external_auto_dir_before" ]]
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 2 ]]
[[ $(protocol_tree_fingerprint) == "$auto_capability_before" ]]
[[ $(find "$auto_roots_detached" -printf '%p|%y|%u|%g|%m|%l\n' | sort) == \
  "$external_auto_dir_before" ]]
rm -- "$nix_gc_auto_roots"
chmod 0755 "$auto_roots_detached"
mkdir -m 0755 -- "$nix_gc_auto_roots"
for detached_auto_root in "$auto_roots_detached"/*; do
  [[ -e $detached_auto_root || -L $detached_auto_root ]] || continue
  mv -T -- "$detached_auto_root" "$nix_gc_auto_roots/${detached_auto_root##*/}"
done
rmdir -- "$auto_roots_detached"
chmod 0555 "$nix_gc_auto_roots"
[[ $(find "$nix_gc_auto_roots" -mindepth 1 -maxdepth 1 \
  -printf '%f|%y|%l\n' | sort) == "$detached_auto_entries_before" ]]
[[ $(stat -c '%a' "$nix_gc_auto_roots") == 555 ]]
mv -T -- "$prepared_child_detached" "$prepared_child"
assert_erasure_observable

garbage_edge=$receipt_root/successor-garbage/$parent_id-$authorized_child_id
garbage_lineage=$garbage_edge/lineage
garbage_roots=$garbage_edge/roots

# lineage rename 後。
TEST_KILL_AFTER_MV_TARGET=$garbage_lineage
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ -d $garbage_lineage && ! -e $receipt_root/lineage/$parent_id ]]
assert_erasure_observable

# persistent roots rename 後。
TEST_KILL_AFTER_MV_TARGET=$garbage_roots
export TEST_KILL_AFTER_MV_TARGET
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_MV_TARGET=
export TEST_KILL_AFTER_MV_TARGET
[[ -d $garbage_roots && ! -e $receipt_root/roots/$authorized_child_id ]]
assert_erasure_observable

# garbage edgeはlineage/roots以外を一切許可しない。実体種別にかかわらず
# statusは無変更で拒否し、cleanup engineも未知entryを削除対象として採用しない。
for garbage_unknown_kind in regular symlink fifo; do
  garbage_unknown=$garbage_edge/unexpected
  case $garbage_unknown_kind in
    regular) : > "$garbage_unknown" ;;
    symlink) ln -s -- "$test_root/missing-garbage" "$garbage_unknown" ;;
    fifo) mkfifo -- "$garbage_unknown" ;;
  esac
  garbage_unknown_before=$(protocol_tree_fingerprint)
  run_rebuild switch '' '' --status
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
  [[ $(protocol_tree_fingerprint) == "$garbage_unknown_before" ]]
  set +e
  PATH="$fake_bin:$PATH" "$bash_path" -c '
    source "$1"
    dotfiles_rebuild_cleanup_successor_v2 \
      "$2" "$3" "$4" cancel-requested 0 run "$5" "$6" "$7" "$8" "$9" "$10" "$11"
  ' cleanup-engine "$receipt_source" "$receipt_root" "$parent_id" \
    "$authorized_child_id" "$parent_receipt" "$EUID" "$(id -g)" "$repo" \
    "$store_dir" "$nix_gc_auto_roots" "$test_user"
  cleanup_status=$?
  set -e
  [[ $cleanup_status -eq 1 ]]
  [[ $(protocol_tree_fingerprint) == "$garbage_unknown_before" ]]
  rm -- "$garbage_unknown"
done

# GC auto rootsはNix daemonの所有物であり、rebuild cleanupの削除対象ではない。
# user-owned persistent rootsを消した後も、同じmetadata/literalのdangling linkとして残す。
[[ $(stat -c '%a' "$nix_gc_auto_roots") == 555 ]]
daemon_auto_roots_before=$(find "$nix_gc_auto_roots" \
  -mindepth 1 -maxdepth 1 -printf '%p|%y|%u|%g|%m|%l\n' | sort)

# preserved parent artifact unlink後。
garbage_parent_artifact=$garbage_lineage/verification-failed.json
TEST_KILL_AFTER_RM_TARGET=$garbage_parent_artifact
export TEST_KILL_AFTER_RM_TARGET
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_AFTER_RM_TARGET=
export TEST_KILL_AFTER_RM_TARGET
[[ ! -e $garbage_parent_artifact && ! -L $garbage_parent_artifact ]]
assert_erasure_observable

# 各persistent root symlink unlink後。
  erased_root_labels=(source candidate recovery-target previous-booted displaced-profile)
  [[ ${#erased_root_labels[@]} -eq 5 ]]
for erased_root_label in "${erased_root_labels[@]}"; do
  erased_root=$garbage_roots/$erased_root_label
  TEST_KILL_AFTER_RM_TARGET=$erased_root
  export TEST_KILL_AFTER_RM_TARGET
  run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
  [[ $rebuild_status -eq 137 ]]
  TEST_KILL_AFTER_RM_TARGET=
  export TEST_KILL_AFTER_RM_TARGET
  [[ ! -e $erased_root && ! -L $erased_root ]]
  assert_erasure_observable
done

[[ $(find "$nix_gc_auto_roots" -mindepth 1 -maxdepth 1 \
  -printf '%p|%y|%u|%g|%m|%l\n' | sort) == "$daemon_auto_roots_before" ]]
while IFS= read -r auto_record; do
  daemon_auto_root=$(jq -r '.path' <<< "$auto_record")
  daemon_auto_literal=$(jq -r '.literalTarget' <<< "$auto_record")
  [[ -L $daemon_auto_root && ! -e $daemon_auto_literal ]]
  [[ $(readlink -- "$daemon_auto_root") == "$daemon_auto_literal" ]]
  [[ $(stat -c '%u|%g|%a|%h' -- "$daemon_auto_root") == \
    "$(jq -r '.metadata' <<< "$auto_record")" ]]
done < <(jq -c '.observedAutoRoots[]' "$erasure_file")

# false-erasureのownerはactive parentだけである。activeなし、または無関係な
# active receiptでは、cleanup途中のrecordもread-onlyに拒否する。
parent_receipt_detached=$test_root/parent-receipt-detached.json
mv -T -- "$parent_receipt" "$parent_receipt_detached"
erasure_only_before=$(protocol_tree_fingerprint)
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery protocol state is invalid' "$stderr_log" > /dev/null
[[ $(protocol_tree_fingerprint) == "$erasure_only_before" ]]
mv -T -- "$parent_receipt_detached" "$parent_receipt"
erasure_only_before=$(protocol_tree_fingerprint)

unrelated_active=$(find "$receipt_root/receipts" -maxdepth 1 -type f -name '*.json' \
  -print | while IFS= read -r receipt; do
    [[ $(jq -r '.transactionId' "$receipt") != "$parent_id" ]] && {
      printf '%s\n' "$receipt"
      break
    }
  done)
[[ -n $unrelated_active ]]
set +e
"$bash_path" -c '
  source "$1"
  dotfiles_rebuild_validate_successor_protocol_state \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
' erasure-owner-scan "$receipt_source" "$receipt_root" "$unrelated_active" \
  "$EUID" "$(id -g)" "$repo" "$store_dir" "$nix_gc_auto_roots" "$test_user"
unrelated_erasure_status=$?
set -e
[[ $unrelated_erasure_status -eq 1 ]]
[[ $(protocol_tree_fingerprint) == "$erasure_only_before" ]]

# consumed erasureはschema 4 childと、そのchildが直接参照するparentの組だけを
# ownerとして受理する。child IDまたはdirect parentの片方だけが違っても拒否する。
for owner_case in correct wrong-child wrong-parent; do
  owner_active_id=$authorized_child_id
  owner_direct_parent=$parent_id
  owner_expected_status=0
  case $owner_case in
    wrong-child)
      owner_active_id=$parent_id
      owner_expected_status=1
      ;;
    wrong-parent)
      owner_direct_parent=$authorized_child_id
      owner_expected_status=1
      ;;
  esac
  set +e
  "$bash_path" -c '
    source "$1"
    dotfiles_rebuild_validate_successor_erasure_owner \
      consumed-handoff "$2" "$3" 4 "$4" "$5"
  ' erasure-owner-contract "$receipt_source" "$parent_id" "$authorized_child_id" \
    "$owner_active_id" "$owner_direct_parent"
  owner_contract_status=$?
  set -e
  [[ $owner_contract_status -eq $owner_expected_status ]]
  [[ $(protocol_tree_fingerprint) == "$erasure_only_before" ]]
done

# 明示cancelはcleanupとerasure retireを一つの操作で完了し、parent recoveryを
# 直後から許可する。daemon-owned auto rootsは同じdangling linkのまま残る。
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 0 ]]
[[ $(sha256sum "$parent_receipt" | cut -d ' ' -f 1) == "$parent_before_authorization_sha" ]]
[[ ! -e $prepared_child && ! -L $prepared_child ]]
[[ ! -e $garbage_edge && ! -L $garbage_edge ]]
[[ ! -e $erasure_file && ! -L $erasure_file ]]
[[ $(find "$nix_gc_auto_roots" -mindepth 1 -maxdepth 1 \
  -printf '%p|%y|%u|%g|%m|%l\n' | sort) == "$daemon_auto_roots_before" ]]
run_rebuild switch '' '' --resume "$parent_id"
[[ $rebuild_status -eq 5 ]]
! grep -F 'pending forward recovery blocks parent recovery operations' "$stderr_log" > /dev/null
cp -- "$parent_exact" "$parent_receipt"
chmod 0600 "$parent_receipt"

# child activeへのhandoff後はkeep-roots erasureを経由してparent archiveを先に
# durable化し、auth/preparation/erasureをすべて閉じてから通常resumeへ入る。
export TEST_OCI_STATUS_CANDIDATE=0
export TEST_DOCTOR_STATUS=1
TEST_KILL_BEFORE_MV_KIND=handoff
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only handoff
[[ $(jq -r '.transactionId' "$parent_receipt") == "$parent_id" ]]
run_rebuild switch '' '' --cancel-forward-recover "$parent_id"
[[ $rebuild_status -eq 0 ]]
assert_no_publish_temps

TEST_KILL_BEFORE_MV_KIND=erasure
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --forward-recover "$parent_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
child_receipt=$receipt_root/active.json
child_id=$(jq -r '.transactionId' "$child_receipt")
[[ $child_id != "$parent_id" && $child_id != "$authorized_child_id" ]]
handoff_erasure_temp=$(find "$receipt_root" -mindepth 1 -maxdepth 1 \
  -name ".successor-erasure-$parent_id-$child_id.*" -type f -print -quit)
[[ -n $handoff_erasure_temp &&
  $(stat -c '%u|%g|%a|%h' "$handoff_erasure_temp") == "$EUID|$(id -g)|400|1" ]]
handoff_temp_before=$(find "$handoff_erasure_temp" -maxdepth 0 \
  -printf '%p|%y|%u|%g|%m|%s|%l\n')
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'forward recovery publication is incomplete' "$stderr_log" > /dev/null
[[ $(find "$handoff_erasure_temp" -maxdepth 0 \
  -printf '%p|%y|%u|%g|%m|%s|%l\n') == "$handoff_temp_before" ]]
for invalid_handoff_temp_relation in unrelated-parent wrong-child; do
  case $invalid_handoff_temp_relation in
    unrelated-parent)
      invalid_handoff_temp=$receipt_root/.successor-erasure-77777777777777777777777777777777-$child_id.abcdef
      ;;
    wrong-child)
      invalid_handoff_temp=$receipt_root/.successor-erasure-$parent_id-77777777777777777777777777777777.abcdef
      ;;
  esac
  printf '%s\n' "$invalid_handoff_temp_relation" > "$invalid_handoff_temp"
  chmod 0400 "$invalid_handoff_temp"
  handoff_temps_before=$(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -printf '%p|%y|%u|%g|%m|%s|%l\n' | sort)
  run_rebuild switch '' '' --resume "$child_id"
  [[ $rebuild_status -eq 2 ]]
  grep -F 'forward recovery publication temp state is invalid' "$stderr_log" > /dev/null
  [[ $(find "$receipt_root" -mindepth 1 -maxdepth 1 \
    -name '.successor-*' -printf '%p|%y|%u|%g|%m|%s|%l\n' | sort) == \
    "$handoff_temps_before" ]]
  rm -- "$invalid_handoff_temp"
done
TEST_KILL_BEFORE_MV_KIND=archive
export TEST_KILL_BEFORE_MV_KIND
run_rebuild switch '' '' --resume "$child_id"
[[ $rebuild_status -eq 137 ]]
TEST_KILL_BEFORE_MV_KIND=
export TEST_KILL_BEFORE_MV_KIND
assert_publish_temp_is_observed_read_only archive
authorized_controller_count=$(wc -l < "$authorized_controller_marker")
run_rebuild switch '' '' --resume "$child_id"
[[ $rebuild_status -eq 5 ]]
[[ $(wc -l < "$authorized_controller_marker") -eq $((authorized_controller_count + 1)) &&
  $(tail -n 1 "$authorized_controller_marker") == "$successor/sw/bin/dotfiles-rebuild" ]]
[[ ! -e $handoff_erasure_temp && ! -L $handoff_erasure_temp ]]
assert_no_publish_temps
jq -e --arg parent "$parent_id" --arg candidate "$candidate" '
  .schemaVersion == 4 and .state == "verification-failed" and
  .lineage.kind == "verification-successor" and
  .lineage.protocolVersion == 2 and
  .lineage.parentTransactionId == $parent and
  .previous.running == $candidate and .recoveryTarget == $candidate and
  .activationBaseline.current == $candidate and
  .activationBaseline.profile == $candidate and
  .verification.status == "failed" and .failureStage == "doctor"
' "$child_receipt" > /dev/null
parent_artifact=$receipt_root/$(jq -r '.lineage.parentReceipt.path' "$child_receipt")
[[ -f $parent_artifact && ! -L $parent_artifact ]]
[[ $(stat -c '%u|%g|%a|%h' "$parent_artifact") == "$EUID|$(id -g)|400|1" ]]
[[ $(sha256sum "$parent_artifact" | cut -d ' ' -f 1) == "$parent_sha" ]]
cmp -s -- "$parent_exact" "$parent_artifact"
TEST_STAT_GID_TARGET=$parent_artifact
export TEST_STAT_GID_TARGET
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
TEST_STAT_GID_TARGET=
export TEST_STAT_GID_TARGET
parent_archive=$receipt_root/receipts/$parent_id.json
jq -e \
  --arg child "$child_id" \
  --arg source "$source_path" \
  --arg candidate "$successor" \
  --arg path "lineage/$parent_id/verification-failed.json" '
    .schemaVersion == 4 and .state == "superseded" and
    .activation.status == "succeeded" and
    .verification.status == "failed" and .failureStage == "doctor" and
    .supersession.kind == "verification-successor" and
    .supersession.fromState == "verification-failed" and
    .supersession.successorTransactionId == $child and
    .supersession.successorSource == $source and
    .supersession.successorCandidate == $candidate and
    .supersession.originalReceipt.path == $path and
    .finishedAt != null
  ' "$parent_archive" > /dev/null
[[ ! -e $receipt_root/successors/$parent_id.json ]]
[[ -z $(find "$receipt_root/successor-preparations" -maxdepth 1 \
  -name "$parent_id-*.json" -print -quit) ]]
[[ -z $(find "$receipt_root/successor-erasures" -maxdepth 1 \
  -name "$parent_id-*.json" -print -quit) ]]
[[ ! -e $receipt_root/roots/$parent_id && ! -L $receipt_root/roots/$parent_id ]]

# handoff前のparent名義tempをchild resumeが回収した後は、そのchild自身が次の
# successor parentとして新しいedgeを開始できる。
post_handoff_successor=$store_dir/post-handoff-successor
mkdir -p "$post_handoff_successor/sw/bin" "$post_handoff_successor/etc/dotfiles"
cp -- "$successor/sw/bin/dotfiles-rebuild" "$post_handoff_successor/sw/bin/dotfiles-rebuild"
cp -- "$successor/sw/bin/dotfiles-doctor" "$post_handoff_successor/sw/bin/dotfiles-doctor"
cp -- "$successor/sw/bin/dotfiles-sync-images" "$post_handoff_successor/sw/bin/dotfiles-sync-images"
chmod +x "$post_handoff_successor/sw/bin/dotfiles-rebuild" \
  "$post_handoff_successor/sw/bin/dotfiles-doctor" \
  "$post_handoff_successor/sw/bin/dotfiles-sync-images"
cp -- "$successor/etc/dotfiles/doctor.json" "$post_handoff_successor/etc/dotfiles/doctor.json"
cp -- "$successor/etc/dotfiles/oci-images.json" \
  "$post_handoff_successor/etc/dotfiles/oci-images.json"
export TEST_CANDIDATE=$post_handoff_successor
export TEST_OCI_STATUS_CANDIDATE=1
authorized_controller_count=$(wc -l < "$authorized_controller_marker")
TEST_MUTABLE_CONTROLLER_MARKER=
export TEST_MUTABLE_CONTROLLER_MARKER
run_rebuild switch '' '' --forward-recover "$child_id"
[[ $rebuild_status -eq 1 ]]
require_call '#sourceSnapshot'
[[ $(wc -l < "$authorized_controller_marker") -eq $authorized_controller_count ]]
[[ -f $receipt_root/successors/$child_id.json ]]
rm -f -- "$mutable_controller_marker"
export TEST_MUTABLE_CONTROLLER_MARKER=$mutable_controller_marker
run_rebuild switch '' '' --cancel-forward-recover "$child_id"
[[ $rebuild_status -eq 0 ]]
[[ ! -e $mutable_controller_marker ]]
[[ $(wc -l < "$authorized_controller_marker") -eq $((authorized_controller_count + 1)) &&
  $(tail -n 1 "$authorized_controller_marker") == \
    "$post_handoff_successor/sw/bin/dotfiles-rebuild" ]]
export TEST_CANDIDATE=$successor
export TEST_OCI_STATUS_CANDIDATE=0

# auth/preparation/erasureが消えた後も、active child自身のexecution contractが
# status/reboot後の実行契約である。metadata改変はstatus 2で拒否する。
child_receipt_exact=$test_root/child-receipt-exact.json
cp -- "$child_receipt" "$child_receipt_exact"
rewrite_receipt "$child_receipt" \
  '.lineage.execution.helpers.doctor.sha256 = ("e" * 64)'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
cp -- "$child_receipt_exact" "$child_receipt"
chmod 0600 "$child_receipt"

# supersession metadata はsuperseded receipt自身ではなく実在child receiptへ束縛する。
child_binding_archive=$receipt_root/receipts/$child_id.json
mv -T -- "$child_receipt" "$child_binding_archive"
cp -- "$parent_archive" "$child_receipt"
chmod 0600 "$child_receipt"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# successor 探索では、親に無関係な receipt も内容を読む前に安全性を検証する。
# symlink を lineage がない receipt として読み飛ばしてはならない。
unrelated_receipt_symlink=$receipt_root/receipts/unrelated-symlink.json
ln -s -- "$parent_archive" "$unrelated_receipt_symlink"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
rm -- "$unrelated_receipt_symlink"

# parent projection 内の時刻を一括改変して自己整合させても、実 child の作成時刻と
# 一致しない supersession は拒否する。
rewrite_receipt "$child_receipt" '
  .supersession.createdAt = "2999-01-01T00:00:00Z" |
  .updatedAt = .supersession.createdAt |
  .finishedAt = .supersession.createdAt
'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
cp -- "$parent_archive" "$child_receipt"
chmod 0600 "$child_receipt"

rewrite_receipt "$child_receipt" \
  '.supersession.successorCandidate = .source'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
rm -- "$child_receipt"
mv -T -- "$child_binding_archive" "$child_receipt"
chmod 0600 "$child_receipt"

# superseded receipt の形だけ正しい改変も、保存した verification-failed bytes との差分として拒否する。
child_receipt_backup=$test_root/child-active.json
cp -- "$child_receipt" "$child_receipt_backup"
cp -- "$parent_archive" "$child_receipt"
rewrite_receipt "$child_receipt" \
  '.previous.displacedProfile = .supersession.successorCandidate'
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
mv -T -- "$child_receipt_backup" "$child_receipt"
chmod 0600 "$child_receipt"

# parent ID を child helper に渡しても child candidate の意味へ読み替えない。
run_rebuild switch '' '' --resume "$parent_id"
[[ $rebuild_status -eq 2 ]]
grep -F "active rebuild transaction does not match $parent_id" "$stderr_log" > /dev/null
reject_call 'system-activator'
reject_call 'dotfiles-doctor'

# active child 自身だけでなく、recursive lineage parent の実 attempt artifact も
# statusで再検証し、receipt metadataだけが整合した破損を許可しない。
parent_intent=$receipt_root/$(jq -r '.activation.attempts[-1].intent.path' "$parent_artifact")
parent_intent_exact=$test_root/parent-intent-exact.json
cp -- "$parent_intent" "$parent_intent_exact"
parent_intent_mode=$(stat -c '%a' "$parent_intent")
chmod 0600 "$parent_intent"
printf '\n' >> "$parent_intent"
chmod "$parent_intent_mode" "$parent_intent"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
cp -- "$parent_intent_exact" "$parent_intent.tmp"
chmod "$parent_intent_mode" "$parent_intent.tmp"
mv -T -- "$parent_intent.tmp" "$parent_intent"

# lineage artifact の byte binding を status でも検証するが、破損を修復はしない。
chmod 0600 "$parent_artifact"
printf '\n' >> "$parent_artifact"
chmod 0400 "$parent_artifact"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 2 ]]
grep -F 'active rebuild activation journal is invalid' "$stderr_log" > /dev/null
cp -- "$parent_exact" "$parent_artifact.tmp"
chmod 0400 "$parent_artifact.tmp"
mv -T -- "$parent_artifact.tmp" "$parent_artifact"

export TEST_DOCTOR_STATUS=0
run_rebuild switch '' '' --resume "$child_id"
[[ $rebuild_status -eq 0 ]]
reject_call 'system-activator'
require_call 'dotfiles-doctor'
jq -e --arg parent "$parent_id" '
  .schemaVersion == 4 and .state == "complete" and
  .lineage.parentTransactionId == $parent and
  .verification.status == "succeeded"
' "$receipt_root/receipts/$child_id.json" > /dev/null
[[ ! -e $receipt_root/active.json && ! -L $receipt_root/active.json ]]

# schema4 verification-failed childも新しいimmutable grandchildへ連鎖できる。
chain_parent_exact=$test_root/chain-parent-verification-failed.json
mv -T -- "$receipt_root/receipts/$child_id.json" "$receipt_root/active.json"
rewrite_receipt "$receipt_root/active.json" '
  .state = "verification-failed" |
  .verification = {
    status: "failed",
    exitCode: 1,
    failedCheckIds: ["systemd.fixture"]
  } |
  .failureStage = "doctor" |
  .updatedAt = "2026-07-20T12:00:00Z" |
  .finishedAt = null
'
cp -- "$receipt_root/active.json" "$chain_parent_exact"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]
grandchild=$store_dir/grandchild-system
mkdir -p "$grandchild/sw/bin" "$grandchild/etc/dotfiles"
cp -- "$rebuild" "$grandchild/sw/bin/dotfiles-rebuild"
cp -- "$successor/sw/bin/dotfiles-doctor" "$grandchild/sw/bin/dotfiles-doctor"
cp -- "$successor/sw/bin/dotfiles-sync-images" "$grandchild/sw/bin/dotfiles-sync-images"
chmod +x "$grandchild/sw/bin/dotfiles-rebuild" \
  "$grandchild/sw/bin/dotfiles-doctor" "$grandchild/sw/bin/dotfiles-sync-images"
printf '%s\n' '{"schemaVersion":4}' > "$grandchild/etc/dotfiles/doctor.json"
printf '%s\n' '{"schemaVersion":2,"images":[]}' > "$grandchild/etc/dotfiles/oci-images.json"
export TEST_CANDIDATE=$grandchild
export TEST_DOCTOR_STATUS=1
run_rebuild switch '' '' --forward-recover "$child_id"
[[ $rebuild_status -eq 5 ]]
grep -F "  nix run $repo#dotfiles-rebuild -- --forward-recover" "$stderr_log" > /dev/null
if grep -F "  $grandchild/sw/bin/dotfiles-rebuild --forward-recover" "$stderr_log" > /dev/null; then
  echo 'successor doctor failure delegated repair to the unrepaired successor controller' >&2
  exit 1
fi
grandchild_receipt=$receipt_root/active.json
grandchild_id=$(jq -r '.transactionId' "$grandchild_receipt")
[[ $grandchild_id != "$child_id" && $grandchild_id != "$parent_id" ]]
jq -e --arg parent "$child_id" --arg recovery "$successor" '
  .schemaVersion == 4 and .state == "verification-failed" and
  .lineage.parentTransactionId == $parent and
  .recoveryTarget == $recovery and
  .verification.status == "failed" and .failureStage == "doctor"
' "$grandchild_receipt" > /dev/null
chain_parent_artifact=$receipt_root/$(jq -r '.lineage.parentReceipt.path' "$grandchild_receipt")
cmp -s -- "$chain_parent_exact" "$chain_parent_artifact"
jq -e --arg ancestor "$parent_id" '
  .schemaVersion == 4 and .state == "verification-failed" and
  .lineage.parentTransactionId == $ancestor and .supersession == null
' "$chain_parent_artifact" > /dev/null
jq -e --arg ancestor "$parent_id" --arg successorId "$grandchild_id" '
  .schemaVersion == 4 and .state == "superseded" and
  .lineage.parentTransactionId == $ancestor and
  .supersession.successorTransactionId == $successorId
' "$receipt_root/receipts/$child_id.json" > /dev/null
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]

# superseded parent は、同じparent artifactを指すchildが複数あれば一意に解決できない。
# shellcheck disable=SC1090 # fixture へ渡された production receipt library を直接検証する。
source "$attempt_source"
# shellcheck disable=SC1090 # fixture へ渡された production receipt library を直接検証する。
source "$receipt_source"
chain_superseded=$(cat "$receipt_root/receipts/$child_id.json")
dotfiles_rebuild_verify_successor_binding \
  "$receipt_root" "$chain_superseded" "$EUID" "$repo" "$store_dir" "$test_user"
branch_child_id=44444444444444444444444444444444
branch_child=$receipt_root/receipts/$branch_child_id.json
jq --arg branchId "$branch_child_id" '
  .transactionId = $branchId |
  .state = "prepared" |
  .activation = {status: "pending", exitCode: null, attempts: []} |
  .verification = {status: "pending", exitCode: null, failedCheckIds: []} |
  .failureStage = null |
  .updatedAt = .startedAt |
  .finishedAt = null
' "$grandchild_receipt" > "$branch_child"
chmod 0600 "$branch_child"
dotfiles_rebuild_validate_receipt_file \
  "$branch_child" "$EUID" "$repo" "$store_dir" "$test_user"
set +e
dotfiles_rebuild_verify_successor_binding \
  "$receipt_root" "$chain_superseded" "$EUID" "$repo" "$store_dir" "$test_user"
branch_status=$?
set -e
[[ $branch_status -eq 1 ]]
rm -- "$branch_child"

# C(current grandchild) -> B(child failure artifact) -> C(IDを持つ別failure artifact) の
# 全edgeをbyte bindingした2-hop cycleは、visited transaction IDで拒否する。
cycle_active_exact=$test_root/cycle-active.exact.json
cycle_child_exact=$test_root/cycle-child.exact.json
cp -- "$grandchild_receipt" "$cycle_active_exact"
cp -- "$chain_parent_artifact" "$cycle_child_exact"
cycle_current_root=$receipt_root/lineage/$grandchild_id
cycle_current_artifact=$cycle_current_root/verification-failed.json
[[ ! -e $cycle_current_root && ! -L $cycle_current_root ]]
mkdir -m 0700 -- "$cycle_current_root"
cp -- "$cycle_active_exact" "$cycle_current_artifact"
chmod 0400 "$cycle_current_artifact"
cycle_current_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
  "$receipt_root" "$cycle_current_artifact" "$EUID" "$(id -g)" 400)
cycle_child_tmp=$chain_parent_artifact.cycle
jq \
  --arg currentId "$grandchild_id" \
  --arg recovery "$grandchild" \
  --argjson currentReceipt "$cycle_current_metadata" '
    .lineage.parentTransactionId = $currentId |
    .lineage.parentReceipt = $currentReceipt |
    .recoveryTarget = $recovery |
    .previous.running = $recovery
  ' "$chain_parent_artifact" > "$cycle_child_tmp"
chmod 0400 "$cycle_child_tmp"
mv -T -- "$cycle_child_tmp" "$chain_parent_artifact"
cycle_child_metadata=$(dotfiles_rebuild_protocol_artifact_metadata \
  "$receipt_root" "$chain_parent_artifact" "$EUID" "$(id -g)" 400)
rewrite_receipt "$grandchild_receipt" \
  '.lineage.parentReceipt = $parentReceipt' \
  --argjson parentReceipt "$cycle_child_metadata"
dotfiles_rebuild_validate_receipt_file \
  "$grandchild_receipt" "$EUID" "$repo" "$store_dir" "$test_user"
dotfiles_rebuild_read_lineage_artifact \
  "$receipt_root" "$child_id" "$cycle_child_metadata" "$EUID" "$(id -g)" \
  "$repo" "$store_dir" "$test_user" > /dev/null
dotfiles_rebuild_read_lineage_artifact \
  "$receipt_root" "$grandchild_id" "$cycle_current_metadata" "$EUID" "$(id -g)" \
  "$repo" "$store_dir" "$test_user" > /dev/null
jq -e \
  --arg child "$child_id" \
  --arg current "$grandchild_id" \
  --arg recovery "$grandchild" '
    .transactionId == $child and
    .lineage.parentTransactionId == $current and
    .recoveryTarget == $recovery
  ' "$chain_parent_artifact" > /dev/null
set +e
dotfiles_rebuild_verify_receipt_lineage \
  "$receipt_root" "$(cat "$grandchild_receipt")" "$EUID" "$(id -g)" \
  "$repo" "$store_dir" "$test_user"
cycle_status=$?
set -e
[[ $cycle_status -eq 1 ]]
cp -- "$cycle_active_exact" "$grandchild_receipt.tmp"
chmod 0600 "$grandchild_receipt.tmp"
mv -T -- "$grandchild_receipt.tmp" "$grandchild_receipt"
cp -- "$cycle_child_exact" "$chain_parent_artifact.tmp"
chmod 0400 "$chain_parent_artifact.tmp"
mv -T -- "$chain_parent_artifact.tmp" "$chain_parent_artifact"
rm -- "$cycle_current_artifact"
rmdir -- "$cycle_current_root"
run_rebuild switch '' '' --status
[[ $rebuild_status -eq 0 ]]
