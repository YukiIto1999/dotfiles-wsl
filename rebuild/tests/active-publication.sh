#!/usr/bin/env bash
set -Eeuo pipefail

atomic_source=${1:?atomic file source is required}
receipt_source=${2:?rebuild receipt source is required}
probe_mode=${3:-full}
test_root=$(mktemp -d)
trap 'chmod -R u+w -- "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

uid=$EUID
gid=$(id -g)
state_root=$test_root/state
mkdir -m 0700 "$state_root"
real_mv=$(command -v mv)
real_rm=$(command -v rm)
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
export TEST_REAL_RM=$real_rm

run_create() {
  local receipt_data=$1
  set +e
  printf '%s\n' "$receipt_data" | PATH="$fake_bin:$PATH" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_rebuild_validate_receipt_file() {
      local file=$1 expected_uid=$2 metadata
      metadata=$(stat -c "%u|%a|%h" -- "$file") || return 1
      [[ $metadata == "$expected_uid|600|1" ]] || return 1
      jq -e ".transactionId | type == \"string\" and test(\"^[0-9a-f]{32}$\")" \
        "$file" >/dev/null
    }
    dotfiles_rebuild_create_active_receipt "$3" "$4" /fixture /nix/store fixture
  ' active-create "$atomic_source" "$receipt_source" "$state_root" "$uid"
  publication_status=$?
  set -e
}

run_update() {
  set +e
  PATH="$fake_bin:$PATH" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    dotfiles_rebuild_validate_receipt_file() {
      local file=$1 expected_uid=$2 metadata
      metadata=$(stat -c "%u|%a|%h" -- "$file") || return 1
      [[ $metadata == "$expected_uid|600|1" ]] || return 1
      jq -e ".transactionId | type == \"string\" and test(\"^[0-9a-f]{32}$\")" \
        "$file" >/dev/null
    }
    dotfiles_rebuild_update_active_receipt \
      "$3" "$4" /fixture /nix/store fixture ".value = 2"
  ' active-update "$atomic_source" "$receipt_source" "$state_root" "$uid"
  publication_status=$?
  set -e
}

inspect_active_temps() {
  local active_id=${1:-} expected_uid=${2:-$uid} expected_gid=${3:-$gid}
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_rebuild_inspect_active_publish_temps "$2" "$3" "$4" "$5"
  ' active-inspect "$receipt_source" "$state_root" "$active_id" "$expected_uid" "$expected_gid"
  inspection_status=$?
  set -e
}

cleanup_active_temps() {
  local active_id=${1:-}
  set +e
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_rebuild_cleanup_active_publish_temps "$2" "$3" "$4" "$5"
  ' active-cleanup "$receipt_source" "$state_root" "$active_id" "$uid" "$gid"
  cleanup_status=$?
  set -e
}

create_id=11111111111111111111111111111111
update_id=22222222222222222222222222222222
other_id=33333333333333333333333333333333
create_receipt=$(jq -cn --arg id "$create_id" '{transactionId: $id, value: 1}')
update_receipt=$(jq -cn --arg id "$update_id" '{transactionId: $id, value: 1}')

if [[ $probe_mode == create-red ]]; then
  export TEST_KILL_RM_REGEX='^\.active\.[A-Za-z0-9]{6}$'
  export TEST_KILL_MV_PREFIX=".active-create-$create_id."
  run_create "$create_receipt"
  [[ $publication_status -eq 137 ]]
  [[ ! -e $state_root/active.json && ! -L $state_root/active.json ]]
  exit 0
fi

if [[ $probe_mode == update-red ]]; then
  printf '%s\n' "$update_receipt" > "$state_root/active.json"
  chmod 0600 "$state_root/active.json"
  export TEST_KILL_MV_PREFIX=".active-update-$update_id."
  run_update
  [[ $publication_status -eq 137 ]]
  exit 0
fi

[[ $probe_mode == full ]]

export TEST_KILL_RM_REGEX='^\.active\.[A-Za-z0-9]{6}$'
export TEST_KILL_MV_PREFIX=".active-create-$create_id."
run_create "$create_receipt"
[[ $publication_status -eq 137 ]]
[[ ! -e $state_root/active.json && ! -L $state_root/active.json ]]
create_temp=$(find "$state_root" -mindepth 1 -maxdepth 1 \
  -name ".active-create-$create_id.??????" -type f -print -quit)
[[ -n $create_temp &&
  $(stat -c '%u|%g|%a|%h' "$create_temp") == "$uid|$gid|600|1" ]]
before=$(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
inspect_active_temps
[[ $inspection_status -eq 3 ]]
[[ $(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$before" ]]
unset TEST_KILL_RM_REGEX TEST_KILL_MV_PREFIX
cleanup_active_temps
[[ $cleanup_status -eq 0 && ! -e $create_temp && ! -L $create_temp ]]
run_create "$create_receipt"
[[ $publication_status -eq 0 ]]
[[ $(stat -c '%a|%h' "$state_root/active.json") == '600|1' ]]

rm -- "$state_root/active.json"
partial_create=$state_root/.active-create-$create_id.abcdef
printf '%s' '{"transactionId":' > "$partial_create"
chmod 0600 "$partial_create"
inspect_active_temps
[[ $inspection_status -eq 3 ]]
cleanup_active_temps
[[ $cleanup_status -eq 0 && ! -e $partial_create && ! -L $partial_create ]]

mismatched_create=$state_root/.active-create-$create_id.abcdef
printf '%s\n' "$(jq -cn --arg id "$other_id" '{transactionId: $id}')" > "$mismatched_create"
chmod 0600 "$mismatched_create"
before=$(find "$mismatched_create" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n')
inspect_active_temps
[[ $inspection_status -eq 2 ]]
cleanup_active_temps
[[ $cleanup_status -eq 1 ]]
[[ $(find "$mismatched_create" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n') == "$before" ]]
rm -- "$mismatched_create"

# Pre-migration create could stop before link(2), leaving one anonymous temp.
legacy_temp=$state_root/.active.abcdef
printf '%s' '{' > "$legacy_temp"
chmod 0600 "$legacy_temp"
inspect_active_temps
[[ $inspection_status -eq 3 ]]
cleanup_active_temps
[[ $cleanup_status -eq 0 && ! -e $legacy_temp && ! -L $legacy_temp ]]

# Pre-migration create could stop after link(2), leaving active.json and its
# anonymous temp as two names for the same inode.
printf '%s\n' "$create_receipt" > "$legacy_temp"
chmod 0600 "$legacy_temp"
ln "$legacy_temp" "$state_root/active.json"
inspect_active_temps "$create_id"
[[ $inspection_status -eq 3 ]]
cleanup_active_temps "$create_id"
[[ $cleanup_status -eq 0 && ! -e $legacy_temp && ! -L $legacy_temp ]]
[[ $(stat -c '%h' "$state_root/active.json") -eq 1 ]]
rm -- "$state_root/active.json"

# Pre-migration update used rename(2), so its anonymous temp is a distinct,
# single-link inode beside the still-valid old active receipt.
printf '%s\n' "$update_receipt" > "$state_root/active.json"
chmod 0600 "$state_root/active.json"
printf '%s\n' "$(jq -c '.value = 2' <<< "$update_receipt")" > "$legacy_temp"
chmod 0600 "$legacy_temp"
inspect_active_temps "$update_id"
[[ $inspection_status -eq 3 ]]
cleanup_active_temps "$update_id"
[[ $cleanup_status -eq 0 && ! -e $legacy_temp && ! -L $legacy_temp ]]

# Multiple anonymous residues and a two-link residue on a different inode are
# ambiguous and remain untouched.
printf '%s' '{' > "$state_root/.active.abcdef"
printf '%s' '{' > "$state_root/.active.ghijkl"
chmod 0600 "$state_root/.active.abcdef" "$state_root/.active.ghijkl"
before=$(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
inspect_active_temps "$update_id"
[[ $inspection_status -eq 2 ]]
[[ $(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$before" ]]
rm -- "$state_root/.active.abcdef" "$state_root/.active.ghijkl"

printf '%s' '{' > "$legacy_temp"
chmod 0600 "$legacy_temp"
ln "$legacy_temp" "$test_root/legacy-active-hardlink"
before=$(find "$legacy_temp" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n')
inspect_active_temps "$update_id"
[[ $inspection_status -eq 2 ]]
[[ $(find "$legacy_temp" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n') == "$before" ]]
rm -- "$test_root/legacy-active-hardlink" "$legacy_temp"

export TEST_KILL_MV_PREFIX=".active-update-$update_id."
run_update
[[ $publication_status -eq 137 ]]
jq -e '.value == 1' "$state_root/active.json" >/dev/null
update_temp=$(find "$state_root" -mindepth 1 -maxdepth 1 \
  -name ".active-update-$update_id.??????" -type f -print -quit)
[[ -n $update_temp && $(stat -c '%u|%g|%a|%h' "$update_temp") == "$uid|$gid|600|1" ]]
before=$(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort)
inspect_active_temps "$update_id"
[[ $inspection_status -eq 3 ]]
[[ $(find "$state_root" -printf '%p|%y|%u|%g|%m|%h|%s|%l\n' | sort) == "$before" ]]
unset TEST_KILL_MV_PREFIX
cleanup_active_temps "$update_id"
[[ $cleanup_status -eq 0 && ! -e $update_temp && ! -L $update_temp ]]
run_update
[[ $publication_status -eq 0 ]]
jq -e '.transactionId == $id and .value == 2' --arg id "$update_id" \
  "$state_root/active.json" >/dev/null
[[ $(stat -c '%a|%h' "$state_root/active.json") == '600|1' ]]

partial_update=$state_root/.active-update-$update_id.abcdef
printf '%s' '{' > "$partial_update"
chmod 0600 "$partial_update"
inspect_active_temps "$update_id"
[[ $inspection_status -eq 3 ]]
cleanup_active_temps "$update_id"
[[ $cleanup_status -eq 0 && ! -e $partial_update && ! -L $partial_update ]]

for invalid_kind in unknown symlink mode hardlink uid gid wrong-active-id; do
  invalid=$state_root/.active-update-$update_id.abcdef
  case $invalid_kind in
    unknown) invalid=$state_root/.active-unknown-$update_id.abcdef; : > "$invalid" ;;
    symlink) ln -s "$test_root/missing" "$invalid" ;;
    *) printf '%s' '{' > "$invalid" ;;
  esac
  [[ -L $invalid ]] || chmod 0600 "$invalid"
  case $invalid_kind in
    mode) chmod 0644 "$invalid" ;;
    hardlink) ln "$invalid" "$test_root/active-hardlink" ;;
    wrong-active-id)
      mv "$invalid" "$state_root/.active-update-$other_id.abcdef"
      invalid=$state_root/.active-update-$other_id.abcdef
      ;;
  esac
  expected_uid=$uid
  expected_gid=$gid
  [[ $invalid_kind != uid ]] || expected_uid=$((uid + 1))
  [[ $invalid_kind != gid ]] || expected_gid=$((gid + 1))
  before=$(find "$invalid" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n')
  inspect_active_temps "$update_id" "$expected_uid" "$expected_gid"
  [[ $inspection_status -eq 2 ]]
  [[ $(find "$invalid" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%h|%s|%l\n') == "$before" ]]
  rm -f -- "$test_root/active-hardlink" "$invalid"
done
