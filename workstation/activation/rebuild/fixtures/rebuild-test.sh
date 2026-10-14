#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "${1:?harness is required}"
harness_init "${2:?rebuild entrypoint is required}" "${3:?fixture dependencies are required}" \
  "${4:?restart planner is required}"

# A tracked edit, a staged edit, an untracked file and an edit hidden by the index all keep
# every mode from starting, before any command is run.
printf 'edited\n' >>"$REBUILD_CHECKOUT/tracked"
for option in '' --plan --rollback; do
  if [[ -n $option ]]; then
    run_rebuild 2 "$option"
  else
    run_rebuild 2
  fi
  [[ ! -s $REBUILD_CALL_LOG ]]
  assert_output_has 'commit the working tree'
done
checkout_git add tracked
run_rebuild 2
[[ ! -s $REBUILD_CALL_LOG ]]
checkout_git commit -qm change

printf 'new\n' >"$REBUILD_CHECKOUT/untracked-source"
run_rebuild 2
[[ ! -s $REBUILD_CALL_LOG ]]
assert_output_has 'untracked-source'
rm -- "$REBUILD_CHECKOUT/untracked-source"

checkout_git update-index --assume-unchanged tracked
printf 'hidden\n' >>"$REBUILD_CHECKOUT/tracked"
run_rebuild 2 --plan
[[ ! -s $REBUILD_CALL_LOG ]]
assert_output_has 'commit the working tree'
checkout_git update-index --no-assume-unchanged tracked
checkout_git checkout -- tracked

# A plan builds a candidate and changes neither the checkout nor the system.
lock_one=$(<"$REBUILD_CHECKOUT/flake.lock")
candidate_one=$(system_for_lock "$lock_one")
head_before=$(head_of)
before=$(checkout_snapshot)
run_rebuild 0 --plan
assert_output_has 'plan: switch'
assert_output_has "candidate-path: $candidate_one"
assert_called 'nix flake update architectureStandard'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
assert_no_work_left
planned=$(candidate_id_of_output)
[[ $(readlink "$REBUILD_STATE/candidates/$planned/toplevel") == "$candidate_one" ]]

# Applying switches to exactly the candidate. The native tool is given the built store path
# and never resolves the flake again.
run_rebuild 0
assert_called "nixos-rebuild switch --no-reexec --store-path $candidate_one"
assert_not_called 'nixos-rebuild switch --flake'
assert_call_order 'agent-verify-head' 'nixos-rebuild'
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$candidate_one" ]]
assert_output_has "system profile: $candidate_one (generation 11)"
assert_output_has 'result: applied candidate'
assert_no_terminate
[[ $(head_of) == "$head_before" ]]
[[ $(state_entries candidates) == "$planned" ]]
run_rebuild 0 --discard "$planned"
[[ -z $(state_entries candidates) ]]

# A new standard revision becomes one commit that changes only flake.lock.
reset_profile
lock_two=$(lock_json rev-2)
head_before=$(head_of)
REBUILD_LOCK_NEXT=$lock_two run_rebuild 0
[[ $(head_of HEAD^) == "$head_before" ]]
[[ $(checkout_git log -1 --format=%s) == "$REBUILD_STANDARD_SUBJECT" ]]
[[ $(checkout_git diff-tree --no-commit-id --name-only -r HEAD) == flake.lock ]]
[[ $(checkout_git show HEAD:flake.lock) == "$lock_two" ]]
[[ -z $(checkout_git status --porcelain --untracked-files=all) ]]
assert_called "nixos-rebuild switch --no-reexec --store-path $(system_for_lock "$lock_two")"
assert_call_order 'nix flake update architectureStandard' 'nixos-rebuild'
assert_output_has 'standard: rev-1 -> rev-2'

# A failed build leaves the checkout and the system as they were.
reset_profile
before=$(checkout_snapshot)
REBUILD_BUILD_STATUS=1 run_rebuild 2
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
assert_no_work_left
[[ -z $(state_entries candidates) ]]

# A failed activation is reported as observed, never as restored.
REBUILD_SWITCH_STATUS=1 run_rebuild 5
assert_failure_guidance
assert_output_has 'activation-failed'
assert_output_lacks 'result: applied'
reset_profile
REBUILD_PARTIAL_SWITCH=1 REBUILD_SWITCH_STATUS=1 run_rebuild 5
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$(system_for_lock "$(<"$REBUILD_CHECKOUT/flake.lock")")" ]]
assert_failure_guidance
reset_profile
REBUILD_SWITCH_NOOP=1 run_rebuild 5
assert_output_has 'resolves to'
assert_output_lacks 'result: applied'
reset_profile

# Rollback selects the previous generation that remains, without fetching or building. The
# client binary moved to a newer revision on its own, and the rollback reports the combination
# that results instead of claiming it moved the client back.
printf 'client binary 2\n' >"$REBUILD_STORE_DIR/omp-binary-2"
ln -sfn "$REBUILD_STORE_DIR/omp-binary-2" "$REBUILD_ROOT/clients/omp"
run_rebuild 0 --rollback --plan
assert_output_has 'plan: switch'
assert_output_has "rollback: system generation 3 ($REBUILD_PREVIOUS)"
assert_no_switch
assert_not_called 'nix '
run_rebuild 0 --rollback
assert_called 'nixos-rebuild switch --no-reexec --rollback'
assert_not_called 'nix '
assert_output_has "system profile: $REBUILD_PREVIOUS (generation 3)"
assert_output_has "omp: $REBUILD_ROOT/clients/omp -> $REBUILD_STORE_DIR/omp-binary-2"
assert_output_has 'this command does not change them'
assert_output_has 'result: rolled back the system generation to 3'
reset_profile

# A manifest change needs a restart but the switch is complete; the command is shown, not run.
printf '\n[interop]\nappendWindowsPath=true\n' >>"$REBUILD_PREVIOUS/etc/wsl.conf"
run_rebuild 0 --plan --rollback
assert_output_has 'plan: switch-restart'
assert_no_switch
run_rebuild 0 --rollback
assert_output_has "  wsl.exe --terminate 'Fixture Distro'"
assert_no_terminate
reset_profile

# An interface change is a boot transition: not a completed switch, and WSL is not terminated.
printf '[user]\ndefault=nixos\n' >"$REBUILD_PREVIOUS/etc/wsl.conf"
printf 'incompatible\n' >>"$REBUILD_PREVIOUS/init-interface-version"
run_rebuild 0 --rollback --plan
assert_output_has 'plan: boot-restart'
run_rebuild 3 --rollback
assert_output_has 'boot-transition'
assert_output_has "  wsl.exe --terminate 'Fixture Distro'"
assert_output_lacks 'result: rolled back'
assert_no_terminate
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$REBUILD_PREVIOUS" ]]
printf '1\n' >"$REBUILD_PREVIOUS/init-interface-version"
reset_profile

printf '7 2026-10-02 12:00:00 (current)\n' >"$REBUILD_GENERATIONS"
run_rebuild 2 --rollback
assert_no_switch
printf '3 2026-10-01 12:00:00\n7 2026-10-02 12:00:00 (current)\n' >"$REBUILD_GENERATIONS"
REBUILD_HISTORY_STATUS=1 run_rebuild 2 --rollback
assert_no_switch
printf '3 2026-10-01 12:00:00\n7 2026-10-02 12:00:00 (current)\n10 2026-10-03 12:00:00\n' >"$REBUILD_GENERATIONS"

REBUILD_SWITCH_STATUS=1 run_rebuild 5 --rollback
assert_failure_guidance
REBUILD_PARTIAL_SWITCH=1 REBUILD_SWITCH_STATUS=1 run_rebuild 5 --rollback
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$REBUILD_PREVIOUS" ]]
assert_failure_guidance
reset_profile
REBUILD_SWITCH_NOOP=1 run_rebuild 5 --rollback
assert_output_has 'resolves to'
assert_output_lacks 'result: rolled back'
reset_profile

for arguments in '--plan --plan' '--rollback --rollback' '--help --rollback' '--plan unexpected' \
  '--locked --locked' '--rollback --locked' '--candidate' '--candidate 1-2 --plan' \
  '--candidate 1-2 --locked' '--candidate 1-2 --rollback' '--discard 1-2 --rollback' \
  '--candidate 1-2 --discard 1-3' '--discard'; do
  read -r -a argv <<<"$arguments"
  run_rebuild 2 "${argv[@]}"
  [[ ! -s $REBUILD_CALL_LOG ]]
done
run_rebuild 0 --help
assert_output_has 'usage:'
[[ ! -s $REBUILD_CALL_LOG ]]

mv "$REBUILD_CHECKOUT/.git" "$REBUILD_ROOT/git-hidden"
run_rebuild 2
[[ ! -s $REBUILD_CALL_LOG ]]
mv "$REBUILD_ROOT/git-hidden" "$REBUILD_CHECKOUT/.git"
