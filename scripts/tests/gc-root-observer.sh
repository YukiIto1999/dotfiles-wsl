#!/usr/bin/env bash
set -Eeuo pipefail

receipt_source=${1:?rebuild receipt source is required}
probe_mode=${2:-full}
test_root=$(mktemp -d)
trap 'chmod -R u+w -- "$test_root" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT

state_root=$test_root/state
store_dir=$test_root/nix/store
auto_dir=$test_root/nix/var/nix/gcroots/auto
child_id=22222222222222222222222222222222
uid=$EUID
gid=$(id -g)
transaction_roots=$state_root/roots/$child_id
mkdir -p "$transaction_roots" "$auto_dir"
chmod 0700 "$state_root/roots" "$transaction_roots"
labels=(source candidate recovery-target previous-booted displaced-profile)
for label in "${labels[@]}"; do
  mkdir -p "$store_dir/$label"
done
child=$(jq -cn --arg id "$child_id" --arg store "$store_dir" '
  {
    transactionId: $id,
    source: ($store + "/source"),
    candidate: ($store + "/candidate"),
    recoveryTarget: ($store + "/recovery-target"),
    previous: {
      booted: ($store + "/previous-booted"),
      displacedProfile: ($store + "/displaced-profile")
    }
  }')

# shellcheck disable=SC1090 # The production library path is an explicit test input.
source "$receipt_source"

observe() {
  dotfiles_rebuild_observe_successor_roots \
    "$state_root" "$child" "$uid" "$gid" "$store_dir" "$auto_dir" "${1:-0}"
}

root_for() {
  printf '%s/%s\n' "$transaction_roots" "$1"
}

target_for() {
  case $1 in
    source) jq -r '.source' <<< "$child" ;;
    candidate) jq -r '.candidate' <<< "$child" ;;
    recovery-target) jq -r '.recoveryTarget' <<< "$child" ;;
    previous-booted) jq -r '.previous.booted' <<< "$child" ;;
    displaced-profile) jq -r '.previous.displacedProfile' <<< "$child" ;;
  esac
}

auto_name_for() {
  case $1 in
    source) printf '%032d\n' 1 ;;
    candidate) printf '%032d\n' 2 ;;
    recovery-target) printf '%032d\n' 3 ;;
    previous-booted) printf '%032d\n' 4 ;;
    displaced-profile) printf '%032d\n' 5 ;;
  esac
}

direct_temp=$(root_for source).tmp-123-456
ln -s "$(target_for source)" "$direct_temp"
if [[ $probe_mode == temp-red ]]; then
  observed=$(observe)
  jq -e '.observedRootTemps | length == 1' <<< "$observed" >/dev/null
  exit 0
fi

[[ $probe_mode == complexity-red || $probe_mode == full ]]

rm "$direct_temp"
for label in "${labels[@]}"; do
  root=$(root_for "$label")
  ln -s "$(target_for "$label")" "$root"
  ln -s "$root" "$auto_dir/$(auto_name_for "$label")"
done
for index in $(seq 1 40); do
  ln -s "$store_dir/unrelated-$index" "$auto_dir/unrelated-$index"
done

real_readlink=$(command -v readlink)
readlink_log=$test_root/readlink.log
fake_bin=$test_root/fake-bin
mkdir -m 0700 "$fake_bin"
cat > "$fake_bin/readlink" <<'SCRIPT'
#!@bash@
set -euo pipefail
printf '%s\n' "${!#}" >> "$TEST_READLINK_LOG"
exec "$TEST_REAL_READLINK" "$@"
SCRIPT
sed -i "1s|@bash@|$(command -v bash)|" "$fake_bin/readlink"
chmod 0500 "$fake_bin/readlink"
export TEST_REAL_READLINK=$real_readlink TEST_READLINK_LOG=$readlink_log
: > "$readlink_log"
observed=$(PATH="$fake_bin:$PATH" observe 1)
readlink_count=$(wc -l < "$readlink_log")
if [[ $probe_mode == complexity-red ]]; then
  [[ $readlink_count -le 55 ]]
  exit 0
fi

jq -e '
  (.observedRoots | length) == 5 and
  (.observedAutoRoots | length) == 5 and
  (.observedRootTemps | length) == 0 and
  (.observedAutoRootTemps | length) == 0
' <<< "$observed" >/dev/null
[[ $readlink_count -le 55 ]]

# Direct and daemon temporary names follow Nix makeSymlink():
# <canonical>.tmp-<decimal pid>-<decimal rand>.
source_auto=$auto_dir/$(auto_name_for source)
rm "$(root_for source)" "$source_auto"
ln -s "$(target_for source)" "$(root_for source).tmp-123-456"
ln -s "$(root_for source)" "$source_auto.tmp-789-1011"
observed=$(observe)
jq -e '
  (.observedRoots | has("source") | not) and
  ([.observedRootTemps[] | select(.label == "source")] | length == 1) and
  ([.observedAutoRootTemps[] | select(.label == "source")] | length == 1)
' <<< "$observed" >/dev/null
set +e
observe 1 >/dev/null
complete_status=$?
set -e
[[ $complete_status -eq 1 ]]

# direct + temp and canonical auto + auto temp are valid interrupted updates.
ln -s "$(target_for source)" "$(root_for source)"
ln -s "$(root_for source)" "$source_auto"
observed=$(observe)
jq -e '
  (.observedRoots | has("source")) and
  ([.observedRootTemps[] | select(.label == "source")] | length == 1) and
  ([.observedAutoRoots[] | select(.label == "source")] | length == 1) and
  ([.observedAutoRootTemps[] | select(.label == "source")] | length == 1)
' <<< "$observed" >/dev/null

# Removing the user-owned names leaves authenticated dangling daemon entries.
rm "$(root_for source)" "$(root_for source).tmp-123-456"
observed=$(observe)
jq -e '
  (.observedRoots | has("source") | not) and
  ([.observedAutoRoots[] | select(.label == "source")] | length == 1) and
  ([.observedAutoRootTemps[] | select(.label == "source")] | length == 1)
' <<< "$observed" >/dev/null

for invalid_kind in target suffix duplicate hardlink regular; do
  rm -f "$source_auto.tmp-789-1011"
  invalid="$(root_for source).tmp-123-456"
  case $invalid_kind in
    target) ln -s "$store_dir/candidate" "$invalid" ;;
    suffix) invalid="$(root_for source).tmp-invalid"; ln -s "$(target_for source)" "$invalid" ;;
    duplicate)
      ln -s "$(target_for source)" "$invalid"
      ln -s "$(target_for source)" "$(root_for source).tmp-789-1011"
      ;;
    hardlink)
      ln -s "$(target_for source)" "$invalid"
      ln "$invalid" "$test_root/root-hardlink"
      ;;
    regular) printf '%s' invalid > "$invalid" ;;
  esac
  before=$(find "$invalid" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%n|%s|%l\n')
  set +e
  observe >/dev/null
  invalid_status=$?
  set -e
  [[ $invalid_status -eq 1 ]]
  [[ $(find "$invalid" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%n|%s|%l\n') == "$before" ]]
  rm -f "$test_root/root-hardlink" "$invalid" "$(root_for source).tmp-789-1011"
done

# A partial record remains observable after its store target was collected.
ln -s "$(target_for source)" "$(root_for source).tmp-123-456"
mv -T -- "$store_dir/source" "$test_root/source-store-detached"
observed=$(observe)
jq -e '
  ([.observedRootTemps[] | select(.label == "source")] | length == 1) and
  ([.observedAutoRoots[] | select(.label == "source")] | length == 1)
' <<< "$observed" >/dev/null
mv -T -- "$test_root/source-store-detached" "$store_dir/source"
rm -- "$(root_for source).tmp-123-456"

source_auto_base=${source_auto##*/}
for invalid_auto_kind in suffix duplicate hardlink regular wrong-base cross-label; do
  invalid_auto=$source_auto.tmp-123-456
  case $invalid_auto_kind in
    suffix)
      invalid_auto=$source_auto.tmp-invalid
      ln -s "$(root_for source)" "$invalid_auto"
      ;;
    duplicate)
      ln -s "$(root_for source)" "$invalid_auto"
      ln -s "$(root_for source)" "$source_auto.tmp-789-1011"
      ;;
    hardlink)
      ln -s "$(root_for source)" "$invalid_auto"
      ln "$invalid_auto" "$test_root/auto-hardlink"
      ;;
    regular)
      invalid_auto=$auto_dir/regular-entry
      printf '%s' invalid > "$invalid_auto"
      ;;
    wrong-base)
      invalid_auto=$auto_dir/$(printf '%032d' 9).tmp-123-456
      ln -s "$(root_for source)" "$invalid_auto"
      ;;
    cross-label)
      invalid_auto=$auto_dir/$source_auto_base.tmp-123-456
      ln -s "$(root_for candidate)" "$invalid_auto"
      ;;
  esac
  before=$(find "$invalid_auto" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%n|%s|%l\n')
  set +e
  observe >/dev/null
  invalid_status=$?
  set -e
  [[ $invalid_status -eq 1 ]]
  [[ $(find "$invalid_auto" -maxdepth 0 -printf '%p|%y|%u|%g|%m|%n|%s|%l\n') == "$before" ]]
  rm -f "$test_root/auto-hardlink" "$invalid_auto" "$source_auto.tmp-789-1011"
done
