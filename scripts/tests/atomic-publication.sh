#!/usr/bin/env bash
set -Eeuo pipefail

atomic_source=${1:?atomic file source is required}
operation_source=${2:?operation lock source is required}
oci_source=${3:?OCI image state source is required}
probe_mode=${4:-full}
legacy_operation_source=${5:-}
legacy_oci_source=${6:-}
test_root=$(mktemp -d)
trap 'chmod -R u+w -- "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

uid=$EUID
gid=$(id -g)
real_mv=$(command -v mv)
fake_bin=$test_root/fake-bin
mkdir -m 0700 "$fake_bin"
cat > "$fake_bin/mv" <<'SCRIPT'
#!@bash@
set -euo pipefail
source_path=${@: -2:1}
if [[ -n ${TEST_KILL_MV_PREFIX:-} && ${source_path##*/} == "$TEST_KILL_MV_PREFIX"* ]]; then
  kill -KILL "$PPID"
  exit 137
fi
if [[ -n ${TEST_MV_PAUSE_PREFIX:-} && ${source_path##*/} == "$TEST_MV_PAUSE_PREFIX"* ]]; then
  : > "$TEST_MV_PAUSE_READY"
  while [[ ! -e $TEST_MV_PAUSE_RELEASE ]]; do sleep 0.01; done
fi
exec "$TEST_REAL_MV" "$@"
SCRIPT
sed -i "1s|@bash@|$(command -v bash)|" "$fake_bin/mv"
chmod 0500 "$fake_bin/mv"
cat > "$fake_bin/rm" <<'SCRIPT'
#!@bash@
set -euo pipefail
for argument in "$@"; do
  if [[ -n ${TEST_KILL_RM_REGEX:-} && ${argument##*/} =~ $TEST_KILL_RM_REGEX ]]; then
    kill -KILL "$PPID"
    exit 137
  fi
done
exec "$TEST_REAL_RM" "$@"
SCRIPT
sed -i "1s|@bash@|$(command -v bash)|" "$fake_bin/rm"
chmod 0500 "$fake_bin/rm"
export TEST_REAL_MV=$real_mv
TEST_REAL_RM=$(command -v rm)
export TEST_REAL_RM

run_operation() {
  local common_git_dir=$1 bootstrap_mode=${2:-create}
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_acquire_operation_lock "$3" "$4" "$5" "$6"
    if declare -F dotfiles_release_operation_lock >/dev/null; then
      dotfiles_release_operation_lock
    fi
  ' operation-contract "$atomic_source" "$operation_source" "$common_git_dir" \
    "$uid" "$gid" "$bootstrap_mode"
  operation_status=$?
  set -e
}

run_operation_source() {
  local source_file=$1 common_git_dir=$2 bootstrap_mode=${3:-create}
  local saved_source=$operation_source
  operation_source=$source_file
  run_operation "$common_git_dir" "$bootstrap_mode"
  operation_source=$saved_source
}

run_oci_ensure() {
  local state_root=$1
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_oci_ensure_lock_file "$3" "$4" "$5"
  ' oci-ensure-contract "$atomic_source" "$oci_source" "$state_root" "$uid" "$gid"
  oci_status=$?
  set -e
}

run_oci_acquire() {
  local state_root=$1 kind=$2 bootstrap_mode=${3:-existing-only}
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_oci_acquire_image_lock "$3" "$4" "$5" "$6" "$7"
    dotfiles_oci_release_image_lock
  ' oci-acquire-contract "$atomic_source" "$oci_source" "$state_root" "$uid" "$gid" "$kind" \
    "$bootstrap_mode"
  oci_status=$?
  set -e
}

if [[ $probe_mode == old-operation-hardlink ]]; then
  operation_root=$test_root/old-operation
  mkdir -m 0700 "$operation_root"
  export TEST_KILL_RM_REGEX='^\.dotfiles-operation\.[A-Za-z0-9]{6}$'
  PATH="$fake_bin:$PATH" run_operation "$operation_root" create
  [[ $operation_status -eq 0 ]]
  [[ $(stat -c '%h' "$operation_root/dotfiles-operation.lock") -eq 1 ]]
  exit 0
fi

if [[ $probe_mode == old-oci-hardlink ]]; then
  oci_root=$test_root/old-oci
  mkdir -m 0700 "$oci_root" "$oci_root/receipts"
  export TEST_KILL_RM_REGEX='^\.operation-lock\.[A-Za-z0-9]{6}$'
  PATH="$fake_bin:$PATH" run_oci_ensure "$oci_root"
  [[ $oci_status -eq 0 ]]
  [[ $(stat -c '%h' "$oci_root/operation.lock") -eq 1 ]]
  exit 0
fi

if [[ $probe_mode == interop ]]; then
  [[ -n $legacy_operation_source && -n $legacy_oci_source ]]
  operation_root=$test_root/interop-operation
  mkdir -m 0700 "$operation_root"
  run_operation "$operation_root" create
  [[ $operation_status -eq 0 ]]

  ready=$test_root/legacy-operation-ready
  release=$test_root/legacy-operation-release
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_acquire_operation_lock "$2" "$3" "$4"
    : > "$5"
    while [[ ! -e $6 ]]; do sleep 0.01; done
  ' legacy-operation-holder "$legacy_operation_source" "$operation_root" "$uid" "$gid" \
    "$ready" "$release" &
  holder=$!
  while [[ ! -e $ready ]]; do sleep 0.01; done
  run_operation "$operation_root" create
  [[ $operation_status -eq 1 ]]
  : > "$release"
  wait "$holder"

  ready=$test_root/current-operation-ready
  release=$test_root/current-operation-release
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_acquire_operation_lock "$3" "$4" "$5" create
    : > "$6"
    while [[ ! -e $7 ]]; do sleep 0.01; done
  ' current-operation-holder "$atomic_source" "$operation_source" "$operation_root" \
    "$uid" "$gid" "$ready" "$release" &
  holder=$!
  while [[ ! -e $ready ]]; do sleep 0.01; done
  run_operation_source "$legacy_operation_source" "$operation_root" create
  [[ $operation_status -eq 1 ]]
  : > "$release"
  wait "$holder"

  # An old publisher may win the canonical-name race because it does not know
  # the directory lock.  The new publisher must bind and remove only its own
  # no-replace temp after acquiring the legacy inode lock.
  rm -- "$operation_root/dotfiles-operation.lock"
  export TEST_MV_PAUSE_PREFIX=.dotfiles-operation-bootstrap.
  export TEST_MV_PAUSE_READY=$test_root/operation-publish-ready
  export TEST_MV_PAUSE_RELEASE=$test_root/operation-publish-release
  PATH="$fake_bin:$PATH" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_acquire_operation_lock "$3" "$4" "$5" create
    dotfiles_release_operation_lock
  ' current-operation-publisher "$atomic_source" "$operation_source" "$operation_root" \
    "$uid" "$gid" &
  publisher=$!
  while [[ ! -e $TEST_MV_PAUSE_READY ]]; do sleep 0.01; done
  run_operation_source "$legacy_operation_source" "$operation_root" create
  [[ $operation_status -eq 0 ]]
  : > "$TEST_MV_PAUSE_RELEASE"
  wait "$publisher"
  [[ $(stat -c '%h' "$operation_root/dotfiles-operation.lock") -eq 1 ]]
  [[ -z $(find "$operation_root" -mindepth 1 -maxdepth 1 \
    -name '.dotfiles-operation*' -print -quit) ]]
  unset TEST_MV_PAUSE_PREFIX TEST_MV_PAUSE_READY TEST_MV_PAUSE_RELEASE

  oci_root=$test_root/interop-oci
  mkdir -m 0700 "$oci_root" "$oci_root/receipts"
  run_oci_acquire "$oci_root" exclusive create
  [[ $oci_status -eq 0 ]]
  ready=$test_root/legacy-oci-ready
  release=$test_root/legacy-oci-release
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_oci_acquire_image_lock "$2" "$3" "$4" exclusive
    : > "$5"
    while [[ ! -e $6 ]]; do sleep 0.01; done
  ' legacy-oci-holder "$legacy_oci_source" "$oci_root" "$uid" "$gid" \
    "$ready" "$release" &
  holder=$!
  while [[ ! -e $ready ]]; do sleep 0.01; done
  run_oci_acquire "$oci_root" exclusive create
  [[ $oci_status -eq 1 ]]
  : > "$release"
  wait "$holder"

  ready=$test_root/current-oci-ready
  release=$test_root/current-oci-release
  bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_oci_acquire_image_lock "$3" "$4" "$5" exclusive create
    : > "$6"
    while [[ ! -e $7 ]]; do sleep 0.01; done
  ' current-oci-holder "$atomic_source" "$oci_source" "$oci_root" "$uid" "$gid" \
    "$ready" "$release" &
  holder=$!
  while [[ ! -e $ready ]]; do sleep 0.01; done
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_oci_acquire_image_lock "$2" "$3" "$4" exclusive
  ' legacy-oci-contender "$legacy_oci_source" "$oci_root" "$uid" "$gid"
  legacy_oci_status=$?
  set -e
  [[ $legacy_oci_status -eq 1 ]]
  : > "$release"
  wait "$holder"

  rm -- "$oci_root/operation.lock"
  export TEST_MV_PAUSE_PREFIX=.operation-lock-bootstrap.
  export TEST_MV_PAUSE_READY=$test_root/oci-publish-ready
  export TEST_MV_PAUSE_RELEASE=$test_root/oci-publish-release
  PATH="$fake_bin:$PATH" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_oci_acquire_image_lock "$3" "$4" "$5" exclusive create
    dotfiles_oci_release_image_lock
  ' current-oci-publisher "$atomic_source" "$oci_source" "$oci_root" "$uid" "$gid" &
  publisher=$!
  while [[ ! -e $TEST_MV_PAUSE_READY ]]; do sleep 0.01; done
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_oci_ensure_lock_file "$2"
    dotfiles_oci_acquire_image_lock "$2" "$3" "$4" exclusive
  ' legacy-oci-publisher "$legacy_oci_source" "$oci_root" "$uid" "$gid"
  : > "$TEST_MV_PAUSE_RELEASE"
  wait "$publisher"
  [[ $(stat -c '%h' "$oci_root/operation.lock") -eq 1 ]]
  [[ -z $(find "$oci_root" -mindepth 1 -maxdepth 1 \
    -name '.operation-lock*' -print -quit) ]]
  unset TEST_MV_PAUSE_PREFIX TEST_MV_PAUSE_READY TEST_MV_PAUSE_RELEASE
  exit 0
fi

[[ $probe_mode == full ]]

operation_root=$test_root/operation
mkdir -m 0700 "$operation_root"
operation_before=$(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_operation "$operation_root" existing-only
[[ $operation_status -eq 1 ]]
[[ $(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$operation_before" ]]
run_operation "$operation_root" create
[[ $operation_status -eq 0 ]]
operation_lock_metadata=$(stat -c '%u|%g|%a|%h|%s' "$operation_root/dotfiles-operation.lock")
[[ $operation_lock_metadata == "$uid|$gid|600|1|0" ]]
[[ -z $(find "$operation_root" -mindepth 1 -maxdepth 1 \
  -name '.dotfiles-operation*' -print -quit) ]]

# New publication interrupted before rename leaves only a single-link temp.
rm -- "$operation_root/dotfiles-operation.lock"
export TEST_KILL_MV_PREFIX=.dotfiles-operation-bootstrap.
PATH="$fake_bin:$PATH" run_operation "$operation_root" create
[[ $operation_status -eq 137 ]]
operation_temp=$(find "$operation_root" -mindepth 1 -maxdepth 1 \
  -name '.dotfiles-operation-bootstrap.*' -type f -print -quit)
[[ -n $operation_temp &&
  $(stat -c '%u|%g|%a|%h|%s' "$operation_temp") == "$uid|$gid|600|1|0" ]]
operation_residue_before=$(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_operation "$operation_root" existing-only
[[ $operation_status -eq 1 ]]
[[ $(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == \
  "$operation_residue_before" ]]
unset TEST_KILL_MV_PREFIX
run_operation "$operation_root" create
[[ $operation_status -eq 0 && ! -e $operation_temp && ! -L $operation_temp ]]

# A legacy hard-link residue is recovered only after both migration locks are held.
legacy_temp=$operation_root/.dotfiles-operation.abcdef
rm -- "$operation_root/dotfiles-operation.lock"
: > "$legacy_temp"
chmod 0600 "$legacy_temp"
ln "$legacy_temp" "$operation_root/dotfiles-operation.lock"
legacy_before=$(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_operation "$operation_root" existing-only
[[ $operation_status -eq 1 ]]
[[ $(find "$operation_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == \
  "$legacy_before" ]]
run_operation "$operation_root" create
[[ $operation_status -eq 0 && ! -e $legacy_temp && ! -L $legacy_temp ]]
[[ $(stat -c '%h' "$operation_root/dotfiles-operation.lock") -eq 1 ]]

# The directory lock serializes new controllers; the legacy file lock keeps
# old and rollback generations mutually exclusive during migration.
operation_ready=$test_root/operation-ready
operation_release=$test_root/operation-release
bash -c '
  set -euo pipefail
  source "$1"
  dotfiles_acquire_operation_lock "$2" "$3" "$4"
  : > "$5"
  while [[ ! -e $6 ]]; do sleep 0.01; done
  dotfiles_release_operation_lock
' operation-holder "$operation_source" "$operation_root" "$uid" "$gid" \
  "$operation_ready" "$operation_release" &
operation_holder=$!
while [[ ! -e $operation_ready ]]; do sleep 0.01; done
run_operation "$operation_root" create
[[ $operation_status -eq 1 ]]
: > "$operation_release"
wait "$operation_holder"
run_operation "$operation_root" create
[[ $operation_status -eq 0 ]]
operation_lock_metadata=$(stat -c '%u|%g|%a|%h|%s' "$operation_root/dotfiles-operation.lock")
[[ $operation_lock_metadata == "$uid|$gid|600|1|0" ]]

run_operation "$operation_root" create
[[ $operation_status -eq 0 ]]
run_operation "$operation_root" existing-only
[[ $operation_status -eq 0 ]]
run_operation "$operation_root" unexpected-mode
[[ $operation_status -eq 1 ]]

operation_link=$test_root/operation-link
ln -s "$operation_root" "$operation_link"
run_operation "$operation_link"
[[ $operation_status -eq 1 ]]
expected_uid=$((uid + 1))
set +e
bash -c 'source "$1"; dotfiles_acquire_operation_lock "$2" "$3" "$4"' \
  invalid-operation "$operation_source" "$operation_root" "$expected_uid" "$gid"
invalid_status=$?
set -e
[[ $invalid_status -eq 1 ]]

oci_root=$test_root/oci
mkdir -m 0700 "$oci_root" "$oci_root/receipts"
oci_before=$(find "$oci_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_oci_acquire "$oci_root" shared
[[ $oci_status -eq 2 ]]
[[ $(find "$oci_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$oci_before" ]]
run_oci_acquire "$oci_root" exclusive create
[[ $oci_status -eq 0 ]]
oci_lock_metadata=$(stat -c '%u|%g|%a|%h|%s' "$oci_root/operation.lock")
[[ $oci_lock_metadata == "$uid|$gid|600|1|0" ]]
run_oci_acquire "$oci_root" shared
[[ $oci_status -eq 0 ]]

legacy_temp=$oci_root/.operation-lock.abcdef
rm -- "$oci_root/operation.lock"
: > "$legacy_temp"
chmod 0600 "$legacy_temp"
ln "$legacy_temp" "$oci_root/operation.lock"
legacy_before=$(find "$oci_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
run_oci_acquire "$oci_root" shared existing-only
[[ $oci_status -eq 2 ]]
[[ $(find "$oci_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$legacy_before" ]]
run_oci_acquire "$oci_root" exclusive create
[[ $oci_status -eq 0 && ! -e $legacy_temp && ! -L $legacy_temp ]]
[[ $(stat -c '%h' "$oci_root/operation.lock") -eq 1 ]]

oci_ready=$test_root/oci-ready
oci_release=$test_root/oci-release
bash -c '
  set -euo pipefail
  source "$1"
  dotfiles_oci_acquire_image_lock "$2" "$3" "$4" shared
  : > "$5"
  while [[ ! -e $6 ]]; do sleep 0.01; done
  dotfiles_oci_release_image_lock
' oci-holder "$oci_source" "$oci_root" "$uid" "$gid" "$oci_ready" "$oci_release" &
oci_holder=$!
while [[ ! -e $oci_ready ]]; do sleep 0.01; done
run_oci_acquire "$oci_root" shared
[[ $oci_status -eq 0 ]]
run_oci_acquire "$oci_root" exclusive create
[[ $oci_status -eq 1 ]]
: > "$oci_release"
wait "$oci_holder"
run_oci_acquire "$oci_root" exclusive create
[[ $oci_status -eq 0 ]]
oci_lock_metadata=$(stat -c '%u|%g|%a|%h|%s' "$oci_root/operation.lock")
[[ $oci_lock_metadata == "$uid|$gid|600|1|0" ]]

chmod 0755 "$oci_root"
run_oci_acquire "$oci_root" shared
[[ $oci_status -eq 2 ]]
chmod 0700 "$oci_root"
mv "$oci_root/receipts" "$oci_root/receipts-real"
ln -s "$oci_root/receipts-real" "$oci_root/receipts"
run_oci_acquire "$oci_root" shared
[[ $oci_status -eq 2 ]]
