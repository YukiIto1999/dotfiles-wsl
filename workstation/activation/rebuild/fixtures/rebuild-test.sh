#!/usr/bin/env bash
set -euo pipefail

rebuild=${1:?rebuild entrypoint is required}
dependencies=${2:?fixture dependencies are required}
restart_planner=${3:?restart planner is required}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export REBUILD_CHECKOUT="$test_root/checkout"
export REBUILD_SYSTEM_PROFILE="$test_root/profiles/system"
export REBUILD_CANDIDATE="$test_root/candidate"
export REBUILD_BOOTED_SYSTEM="$test_root/booted"
export REBUILD_RUNNING_SYSTEM="$test_root/running"
export REBUILD_GENERATIONS="$test_root/generations"
export REBUILD_CALL_LOG="$test_root/calls"
export REBUILD_RESTART_PLANNER=$restart_planner
export PATH="$dependencies/bin:$PATH"
output=$test_root/output
mkdir -p "$REBUILD_CHECKOUT" "${REBUILD_SYSTEM_PROFILE%/*}"
for system in "$REBUILD_CANDIDATE" "$REBUILD_BOOTED_SYSTEM" "$REBUILD_RUNNING_SYSTEM"; do
  mkdir -p "$system/etc"
  printf '[user]\ndefault=nixos\n' > "$system/etc/wsl.conf"
  printf '1\n' > "$system/init-interface-version"
done
previous=$test_root/previous
cp -r "$REBUILD_CANDIDATE" "$previous"
ln -s "$previous" "$REBUILD_SYSTEM_PROFILE-3-link"
ln -s "$REBUILD_RUNNING_SYSTEM" "$REBUILD_SYSTEM_PROFILE-7-link"
ln -s "$REBUILD_SYSTEM_PROFILE-7-link" "$REBUILD_SYSTEM_PROFILE"
printf '3 2026-10-01 12:00:00\n7 2026-10-02 12:00:00 (current)\n10 2026-10-03 12:00:00\n' > "$REBUILD_GENERATIONS"

git -C "$REBUILD_CHECKOUT" init -q
git -C "$REBUILD_CHECKOUT" config user.name 'Rebuild fixture'
git -C "$REBUILD_CHECKOUT" config user.email 'fixture@example.invalid'
printf 'initial\n' > "$REBUILD_CHECKOUT/tracked"
git -C "$REBUILD_CHECKOUT" add tracked
git -C "$REBUILD_CHECKOUT" commit -qm initial

run_rebuild() {
  local expected_status=$1 status=0
  shift
  : > "$REBUILD_CALL_LOG"
  "$rebuild" "$@" > "$output" 2>&1 || status=$?
  if [[ $status != "$expected_status" ]]; then
    cat "$output" >&2
    printf 'expected exit %s, got %s\n' "$expected_status" "$status" >&2
    exit 1
  fi
}

assert_no_switch() {
  if grep -q '^nixos-rebuild ' "$REBUILD_CALL_LOG"; then
    printf 'a read-only or rejected invocation switched the system\n' >&2
    exit 1
  fi
}

printf 'edited\n' >> "$REBUILD_CHECKOUT/tracked"
for option in '' --plan --rollback; do
  if [[ -n $option ]]; then
    run_rebuild 2 "$option"
  else
    run_rebuild 2
  fi
  [[ ! -s $REBUILD_CALL_LOG ]]
  grep -Fq 'commit the working tree' "$output"
done
git -C "$REBUILD_CHECKOUT" add tracked
run_rebuild 2
[[ ! -s $REBUILD_CALL_LOG ]]
git -C "$REBUILD_CHECKOUT" commit -qm change

run_rebuild 0 --plan
grep -Fxq 'plan: switch' "$output"
assert_no_switch
run_rebuild 0
grep -Fxq "nixos-rebuild switch --flake $REBUILD_CHECKOUT#fixture-host" "$REBUILD_CALL_LOG"

export REBUILD_CANDIDATE=$previous
run_rebuild 0 --rollback --plan
grep -Fxq 'plan: switch' "$output"
assert_no_switch
if grep -q '^nix ' "$REBUILD_CALL_LOG"; then
  printf 'rollback built a new flake instead of selecting an existing generation\n' >&2
  exit 1
fi
run_rebuild 0 --rollback
grep -Fxq 'nixos-rebuild switch --rollback' "$REBUILD_CALL_LOG"

printf '\n[interop]\nappendWindowsPath=true\n' >> "$previous/etc/wsl.conf"
run_rebuild 0 --plan --rollback
grep -Fxq 'plan: switch-restart' "$output"
assert_no_switch
run_rebuild 0 --rollback
grep -Fxq "  wsl.exe --terminate 'Fixture Distro'" "$output"

printf '7 2026-10-02 12:00:00 (current)\n' > "$REBUILD_GENERATIONS"
run_rebuild 2 --rollback
assert_no_switch
printf '3 2026-10-01 12:00:00\n7 2026-10-02 12:00:00 (current)\n' > "$REBUILD_GENERATIONS"
REBUILD_HISTORY_STATUS=1 run_rebuild 2 --rollback
assert_no_switch

REBUILD_SWITCH_STATUS=1 run_rebuild 2
assert_failure_guidance() {
  grep -Fq 'readlink -f /run/current-system' "$output"
  grep -Fq "readlink -f $REBUILD_SYSTEM_PROFILE" "$output"
  grep -Fq 'systemctl --failed' "$output"
  grep -Fq 'journalctl' "$output"
  if grep -q 'previous generation is still active' "$output"; then
    printf 'switch failure claimed an unobserved active generation\n' >&2
    exit 1
  fi
}
assert_failure_guidance
REBUILD_PARTIAL_SWITCH=1 REBUILD_SWITCH_STATUS=1 run_rebuild 2
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$REBUILD_CANDIDATE" ]]
assert_failure_guidance
ln -sfn "$REBUILD_SYSTEM_PROFILE-7-link" "$REBUILD_SYSTEM_PROFILE"
REBUILD_SWITCH_STATUS=1 run_rebuild 2 --rollback
assert_failure_guidance

REBUILD_BUILD_STATUS=1 run_rebuild 2
assert_no_switch
for arguments in '--plan --plan' '--rollback --rollback' '--help --rollback' '--plan unexpected'; do
  read -r -a argv <<< "$arguments"
  run_rebuild 2 "${argv[@]}"
  [[ ! -s $REBUILD_CALL_LOG ]]
done

mv "$REBUILD_CHECKOUT/.git" "$test_root/git-hidden"
run_rebuild 2
[[ ! -s $REBUILD_CALL_LOG ]]
