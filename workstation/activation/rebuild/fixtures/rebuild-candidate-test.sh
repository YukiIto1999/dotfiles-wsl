#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "${1:?harness is required}"
harness_init "${2:?rebuild entrypoint is required}" "${3:?fixture dependencies are required}" \
  "${4:?restart planner is required}"
unconfirmed_rebuild=${5:?rebuild entrypoint with an unconfirming supervisor is required}

export REBUILD_GATE_RECORD=$REBUILD_ROOT/gate-record
lock_one=$(<"$REBUILD_CHECKOUT/flake.lock")
base_head=$(head_of)

# TERM による取消後の plan の残存の検査
#   $1: plan を止める stage の名前
#   $2 以降: 子の挙動を決める VAR=value 形式の fixture 設定
#   戻り値: 取消の不備を検出した場合の非ゼロ
cancel_during() {
  local stage=$1 pid status=0 child before candidates
  shift
  : >"$REBUILD_CHILD_PIDS"
  : >"$REBUILD_CALL_LOG"
  rm -f -- "$REBUILD_HANG_STARTED"
  before=$(checkout_snapshot)
  candidates=$(state_entries candidates)
  env REBUILD_HANG_AT="$stage" "$@" "$REBUILD_BIN" --plan >"$REBUILD_OUTPUT" 2>&1 &
  pid=$!
  wait_for_file "$REBUILD_HANG_STARTED"
  kill -TERM "$pid"
  wait "$pid" || status=$?
  if [[ $status != 130 ]]; then
    cat "$REBUILD_OUTPUT" >&2
    printf 'a cancelled plan returned %s instead of 130\n' "$status" >&2
    exit 1
  fi
  while read -r child; do
    if process_alive "$child"; then
      printf 'child %s of the cancelled plan is still running (stage %s)\n' "$child" "$stage" >&2
      exit 1
    fi
  done <"$REBUILD_CHILD_PIDS"
  [[ $(checkout_snapshot) == "$before" ]]
  [[ $(state_entries candidates) == "$candidates" ]]
  assert_no_work_left
  assert_no_switch
}

# 1. A plan resolves the latest standard in an isolated source, validates and builds there, and
# leaves the checkout and the system untouched, while a native GC root holds the candidate.
lock_two=$(lock_json rev-2)
before=$(checkout_snapshot)
: >"$REBUILD_OBSERVED"
REBUILD_LOCK_NEXT=$lock_two run_rebuild 0 --plan
[[ $(checkout_snapshot) == "$before" ]]
assert_output_has 'standard: rev-1 -> rev-2'
assert_output_has 'result: planned'
assert_no_switch
assert_no_work_left
first=$(candidate_id_of_output)
first_dir=$REBUILD_STATE/candidates/$first
[[ -L $first_dir/toplevel && $(readlink "$first_dir/toplevel") == "$(system_for_lock "$lock_two")" ]]
[[ $(<"$first_dir/flake.lock") == "$lock_two" ]]
mapfile -t observed <"$REBUILD_OBSERVED"
[[ ${observed[0]} == "$base_head 0" ]]
[[ ${observed[1]} == "$(printf '%s\n' "$lock_one" | sha256sum)" ]]
[[ ${observed[2]} == "$(printf '%s\n' "$lock_two" | sha256sum)" ]]
for stage in update-cwd verify-cwd build-cwd; do
  grep -q "^$stage " "$REBUILD_CALL_LOG"
  assert_not_called "$stage $REBUILD_CHECKOUT"
done
assert_call_order 'update-cwd' 'verify-cwd'
assert_call_order 'verify-cwd' 'build-cwd'

# 2. A failed fetch of the latest standard stops the run with a non-zero status and changes
# nothing; the locked recovery is a different, explicit request.
before=$(checkout_snapshot)
REBUILD_UPDATE_STATUS=1 REBUILD_LOCK_NEXT=$(lock_json rev-3) run_rebuild 2 --plan
assert_output_has 'dotfiles-rebuild --locked'
assert_not_called 'nix run'
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
assert_no_work_left
[[ $(state_entries candidates) == "$first" ]]
REBUILD_UPDATE_STATUS=1 run_rebuild 2
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
assert_no_work_left

# 3. The locked recovery fetches nothing and commits nothing, says it is not the latest, and
# the plan it leaves replaces the previous held candidate.
REBUILD_UPDATE_STATUS=1 run_rebuild 0 --locked --plan
assert_not_called 'nix flake update'
assert_output_has 'standard: rev-1 (locked recovery'
locked_id=$(candidate_id_of_output)
[[ $(state_entries candidates) == "$locked_id" ]]
head_before=$(head_of)
run_rebuild 0 --candidate "$locked_id"
[[ $(head_of) == "$head_before" ]]
assert_not_called 'nix flake update'
assert_not_called 'nix build'
assert_called "nixos-rebuild switch --no-reexec --store-path $(system_for_lock "$lock_one")"
[[ -z $(state_entries candidates) ]]
reset_profile

# 4. Each failed stage of the candidate stops before the next and leaves nothing behind.
before=$(checkout_snapshot)
REBUILD_VERIFY_STATUS=1 run_rebuild 2 --plan
assert_output_has 'validation of the candidate failed'
assert_not_called 'nix build'
REBUILD_VERIFY_STATUS=124 run_rebuild 2 --plan
assert_output_has 'exceeded its 300s budget'
assert_not_called 'nix build'
REBUILD_BUDGET_STATUS=1 run_rebuild 2 --plan
assert_not_called 'nix run'
assert_not_called 'nix build'
REBUILD_VERIFY_ENTRY='' run_rebuild 2 --plan
assert_not_called 'nix run'
assert_not_called 'nix build'
REBUILD_BUILD_STATUS=1 run_rebuild 2 --plan
assert_output_has 'candidate build failed'
REBUILD_LOCK_NEXT=$(lock_json rev-9 nixpkgs-2) run_rebuild 2 --plan
assert_output_has 'outside architectureStandard'
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
assert_no_work_left
[[ -z $(state_entries candidates) ]]

# 5. A cancel during a fetch, a validation or a build stops every child, with or without TERM
# being honored, and leaves no candidate root, no source worktree and no change.
cancel_during update
cancel_during verify
cancel_during build
cancel_during build REBUILD_HANG_IGNORE_TERM=1
cancel_during build REBUILD_HANG_ESCAPE=1
cancel_during build REBUILD_HANG_ESCAPE=1 REBUILD_HANG_IGNORE_TERM=1
rm -f -- "$REBUILD_STOP_OBSERVED"
cancel_during build REBUILD_HANG_SLOW_STOP=1
[[ $(<"$REBUILD_STOP_OBSERVED") == present ]]

before=$(checkout_snapshot)
REBUILD_BIN=$unconfirmed_rebuild run_rebuild 2 --plan
assert_output_has 'did not confirm that every process'
assert_output_has 'dotfiles-rebuild --discard'
pinned=$(state_entries work)
[[ $(state_entries candidates) == "$pinned" ]]
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
run_rebuild 0 --plan
[[ -f $REBUILD_STATE/work/$pinned/unconfirmed && -f $REBUILD_STATE/candidates/$pinned/unconfirmed ]]
run_rebuild 2 --candidate "$pinned"
assert_output_has 'is pinned'
run_rebuild 0 --plan
[[ -d $REBUILD_STATE/work/$pinned && -d $REBUILD_STATE/candidates/$pinned ]]
run_rebuild 0 --discard "$pinned"
[[ ! -e $REBUILD_STATE/work/$pinned && ! -e $REBUILD_STATE/candidates/$pinned ]]
assert_no_work_left

# 開始した plan と止めた supervisor の識別
#   plan_pid: 回収前の rebuild の pid
#   paused_supervisor: 止めている supervisor の pid
#   paused_start: paused_supervisor の起動時刻
plan_pid=
paused_supervisor=
paused_start=

# 子が stage で停止した plan の開始
#   $1: 子を止める stage の名前
#   $2 以降: 子の挙動を決める VAR=value 形式の fixture 設定
#   設定: plan_pid
#   戻り値: 子の停止の合図が現れない場合の非ゼロ
start_hung_plan() {
  local stage=$1
  shift
  : >"$REBUILD_CHILD_PIDS"
  : >"$REBUILD_CALL_LOG"
  rm -f -- "$REBUILD_HANG_STARTED"
  env REBUILD_HANG_AT="$stage" "$@" "$REBUILD_BIN" --plan >"$REBUILD_OUTPUT" 2>&1 &
  plan_pid=$!
  wait_for_file "$REBUILD_HANG_STARTED"
}

# 開始した plan の rebuild の SIGKILL による終了と回収
#   参照: plan_pid
#   回収後の plan_pid: 空
kill_plan() {
  kill -KILL "$plan_pid"
  wait "$plan_pid" 2>/dev/null || true
  plan_pid=
}

# 子が停止中の plan の rebuild の SIGKILL
#   $1: 子を止める stage の名前
#   $2 以降: 子の挙動を決める VAR=value 形式の fixture 設定
kill_during() {
  start_hung_plan "$@"
  kill_plan
}

# 止めた supervisor の SIGCONT による再開
#   参照: paused_supervisor と paused_start
#   再開後の paused_supervisor: 空
resume_supervisor() {
  [[ -n $paused_supervisor ]] || return 0
  signal_same_process CONT "$paused_supervisor" "$paused_start"
  paused_supervisor=
}

# 回収前の rebuild の終了と止めた supervisor の再開
abandon_plan() {
  if [[ -n $plan_pid ]]; then
    kill_plan || true
  fi
  resume_supervisor
}

# supervisor を止めたままの rebuild の SIGKILL
#   $1: 子を止める stage の名前
#   $2 以降: 子の挙動を決める VAR=value 形式の fixture 設定
#   設定: paused_supervisor と paused_start
#   戻り値: supervisor を plan の rebuild の子として確認できない場合の非ゼロ
kill_with_supervisor_paused() {
  local leader supervisor
  start_hung_plan "$@"
  read -r leader <"$REBUILD_CHILD_PIDS"
  supervisor=$(process_field "$leader" 4)
  if [[ $(process_field "$supervisor" 4) != "$plan_pid" ]]; then
    printf 'process %s is not the supervisor of plan %s\n' "$supervisor" "$plan_pid" >&2
    exit 1
  fi
  paused_start=$(process_field "$supervisor" 22)
  paused_supervisor=$supervisor
  signal_same_process STOP "$supervisor" "$paused_start"
  # STOP の発効前に親を失った supervisor は TERM を先に処理し得るため発効の確認前の rebuild の SIGKILL は不可
  wait_for_process_state "$supervisor" T
  kill_plan
}

# supervisor が全 process の終了を記録するまでの待機
#   $1: supervisor の結果 file を持つ作業 directory の id
#   戻り値: 待機の上限までに記録されない場合の非ゼロ
drain_recorded() {
  for _ in {1..600}; do
    if jq -e '.phase == "finished" and .drained == true' "$REBUILD_STATE/work/$1/supervisor.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  printf 'the supervisor of %s never recorded the end of its session\n' "$1" >&2
  return 1
}

# 記録された leader と子孫の全生存の検査
#   戻り値: 終了した process を検出した場合の非ゼロ
assert_children_alive() {
  local child
  while read -r child; do
    if ! process_alive "$child"; then
      printf 'child %s ended while its supervisor was paused\n' "$child" >&2
      exit 1
    fi
  done <"$REBUILD_CHILD_PIDS"
}

# 記録された leader と子孫の全終了の検査
#   戻り値: 残存した process を検出した場合の非ゼロ
assert_children_ended() {
  local child
  while read -r child; do
    if process_alive "$child"; then
      printf 'child %s outlived the SIGKILLed rebuild\n' "$child" >&2
      exit 1
    fi
  done <"$REBUILD_CHILD_PIDS"
}

kill_during build REBUILD_HANG_ESCAPE=1
orphan=$(state_entries work)
drain_recorded "$orphan"
assert_children_ended
run_rebuild 0 --plan
assert_no_work_left
[[ $(state_entries candidates) == "$(candidate_id_of_output)" ]]

(
  trap abandon_plan EXIT
  kill_with_supervisor_paused build REBUILD_HANG_IGNORE_TERM=1
  orphan=$(state_entries work)
  assert_children_alive
  # 次の plan の所要時間が TERM の猶予を超え得るため猶予内の未完了状態への依存は不可
  run_rebuild 0 --plan
  [[ -d $REBUILD_STATE/work/$orphan ]]
  [[ $(process_field "$paused_supervisor" 3) == T ]]
  jq -e '.phase == "started"' "$REBUILD_STATE/work/$orphan/supervisor.json" >/dev/null
  assert_children_alive
  resume_supervisor
  drain_recorded "$orphan"
  assert_children_ended
  run_rebuild 0 --plan
  [[ ! -e $REBUILD_STATE/work/$orphan ]]
)

# 6. Applying a held candidate uses its root and its own lock. A newer upstream revision is not
# resolved and nothing is built again, and the candidate is released afterwards.
lock_four=$(lock_json rev-4)
REBUILD_LOCK_NEXT=$lock_four run_rebuild 0 --plan
retained=$(candidate_id_of_output)
retained_path=$(system_for_lock "$lock_four")
[[ $(state_entries candidates) == "$retained" ]]
head_before=$(head_of)
REBUILD_LOCK_NEXT=$(lock_json rev-5) run_rebuild 0 --candidate "$retained"
assert_not_called 'nix flake update'
assert_not_called 'nix build'
[[ $(head_of HEAD^) == "$head_before" ]]
[[ $(checkout_git show HEAD:flake.lock) == "$lock_four" ]]
[[ $(checkout_git log -1 --format=%s) == "$REBUILD_STANDARD_SUBJECT" ]]
[[ $(checkout_git diff-tree --no-commit-id --name-only -r HEAD) == flake.lock ]]
assert_called "agent-verify-head $(head_of)"
assert_called "nixos-rebuild switch --no-reexec --store-path $retained_path"
assert_call_order 'agent-verify-head' 'nixos-rebuild'
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$retained_path" ]]
[[ -z $(state_entries candidates) ]]
reset_profile

# 7. A candidate whose root or store path is gone is rejected before anything is written, and
# no other candidate is built to take its place.
lock_six=$(lock_json rev-6)
REBUILD_LOCK_NEXT=$lock_six run_rebuild 0 --plan
expired=$(candidate_id_of_output)
rm -- "$REBUILD_STATE/candidates/$expired/toplevel"
before=$(checkout_snapshot)
run_rebuild 2 --candidate "$expired"
assert_output_has 'expired'
assert_output_has 'No other candidate was substituted'
assert_not_called 'nix flake update'
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
[[ ! -e $REBUILD_STATE/candidates/$expired ]]
REBUILD_LOCK_NEXT=$lock_six run_rebuild 0 --plan
invalid=$(candidate_id_of_output)
printf '%s\n' "$(system_for_lock "$lock_six")" >"$REBUILD_INVALID_PATHS"
run_rebuild 2 --candidate "$invalid"
assert_output_has 'expired'
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
rm -f -- "$REBUILD_INVALID_PATHS"

# 8. A candidate prepared from another HEAD is stale and is rejected the same way.
REBUILD_LOCK_NEXT=$lock_six run_rebuild 0 --plan
stale=$(candidate_id_of_output)
printf 'unrelated\n' >>"$REBUILD_CHECKOUT/tracked"
checkout_git commit -qam unrelated
before=$(checkout_snapshot)
run_rebuild 2 --candidate "$stale"
assert_output_has 'stale'
assert_not_called 'nix flake update'
assert_not_called 'nix build'
assert_no_switch
[[ $(checkout_snapshot) == "$before" ]]
[[ ! -e $REBUILD_STATE/candidates/$stale ]]

# 9. A newer plan replaces the older candidate; the older id is then refused, not substituted.
REBUILD_LOCK_NEXT=$(lock_json rev-7) run_rebuild 0 --plan
older=$(candidate_id_of_output)
REBUILD_LOCK_NEXT=$(lock_json rev-8) run_rebuild 0 --plan
newer=$(candidate_id_of_output)
[[ $(state_entries candidates) == "$newer" ]]
run_rebuild 2 --candidate "$older"
assert_output_has 'no held candidate'
assert_no_switch
run_rebuild 0 --discard "$newer"
[[ -z $(state_entries candidates) ]]
run_rebuild 2 --candidate "$newer"
run_rebuild 2 --discard "$newer"
run_rebuild 2 --discard not-an-id
assert_no_switch

# 10. The commit gate is the repository's own. A refusal takes back only what this run wrote,
# keeps an explicit candidate, and a later apply of the same candidate succeeds.
lock_ten=$(lock_json rev-10)
before=$(checkout_content)
install_hook pre-commit 'exit 1'
REBUILD_LOCK_NEXT=$lock_ten run_rebuild 2
assert_output_has 'refused by the commit gate'
assert_output_has 'result: unchanged'
assert_no_switch
[[ $(checkout_content) == "$before" ]]
[[ -z $(state_entries candidates) ]]
REBUILD_LOCK_NEXT=$lock_ten run_rebuild 0 --plan
gated=$(candidate_id_of_output)
run_rebuild 2 --candidate "$gated"
assert_output_has 'result: unchanged'
assert_no_switch
[[ $(checkout_content) == "$before" ]]
[[ $(state_entries candidates) == "$gated" ]]
remove_hooks
install_hook commit-msg 'cat "$1" > "$REBUILD_GATE_RECORD"'
head_before=$(head_of)
run_rebuild 0 --candidate "$gated"
[[ $(head_of HEAD^) == "$head_before" ]]
[[ $(<"$REBUILD_GATE_RECORD") == "$REBUILD_STANDARD_SUBJECT" ]]
assert_called "nixos-rebuild switch --no-reexec --store-path $(system_for_lock "$lock_ten")"
reset_profile
remove_hooks

export REBUILD_HOOK_DRAIN_RECORD=$REBUILD_ROOT/hook-drain-record
export REBUILD_HOOK_CHILD_READY=$REBUILD_ROOT/hook-child-ready
install_hook post-commit "$(cat <<'HOOK'
(
  trap 'if test -d "$GIT_DIR"; then printf held; else printf released; fi >"$REBUILD_HOOK_DRAIN_RECORD"; exit 0' TERM
  : >"$REBUILD_HOOK_CHILD_READY"
  while :; do sleep 600; done
) &
while test ! -f "$REBUILD_HOOK_CHILD_READY"; do sleep 0.01; done
HOOK
)"
REBUILD_LOCK_NEXT=$(lock_json rev-hook-lifetime) run_rebuild 0
[[ $(<"$REBUILD_HOOK_DRAIN_RECORD") == held ]]
assert_no_work_left
reset_profile
remove_hooks

mkdir "$REBUILD_ROOT/include-hooks"
install_hook pre-commit 'printf rejecting >"$REBUILD_GATE_RECORD"; exit 1'
mv "$REBUILD_CHECKOUT/.git/hooks/pre-commit" "$REBUILD_ROOT/include-hooks/pre-commit"
checkout_git config extensions.worktreeConfig true
checkout_git config --file "$REBUILD_CHECKOUT/.git/required.conf" core.hooksPath "$REBUILD_ROOT/include-hooks"
checkout_git config --worktree include.path required.conf
rm -f -- "$REBUILD_GATE_RECORD"
before=$(checkout_content)
REBUILD_LOCK_NEXT=$(lock_json rev-relative-include) run_rebuild 2
[[ $(checkout_content) == "$before" ]]
[[ $(<"$REBUILD_GATE_RECORD") == rejecting ]]
assert_no_switch
assert_no_work_left
checkout_git config --worktree --unset-all include.path
checkout_git config --unset-all extensions.worktreeConfig
rm -- "$REBUILD_CHECKOUT/.git/config.worktree"

conditional_key="includeIf.onbranch:$(checkout_git symbolic-ref --short HEAD).path"
checkout_git config "$conditional_key" "$REBUILD_CHECKOUT/.git/required.conf"
rm -f -- "$REBUILD_GATE_RECORD"
before=$(checkout_content)
REBUILD_LOCK_NEXT=$(lock_json rev-conditional-include) run_rebuild 2
[[ $(checkout_content) == "$before" ]]
[[ ! -e $REBUILD_GATE_RECORD ]]
assert_no_switch
assert_no_work_left
checkout_git config --unset-all "$conditional_key"
rm -- "$REBUILD_CHECKOUT/.git/required.conf"

base=$(head_of)
install_hook pre-commit 'printf "hook\n" >> tracked; git add tracked'
REBUILD_LOCK_NEXT=$(lock_json rev-11) run_rebuild 4
assert_output_has 'source-changed'
assert_no_switch
[[ $(head_of) == "$base" ]]
grep -Fxq hook "$REBUILD_CHECKOUT/tracked"
remove_hooks
checkout_reset "$base"
install_hook post-commit 'printf "post\n" >> tracked'
REBUILD_LOCK_NEXT=$(lock_json rev-12) run_rebuild 4
assert_output_has 'source-changed'
assert_no_switch
[[ $(head_of) == "$base" ]]
grep -Fxq post "$REBUILD_CHECKOUT/tracked"
[[ -n $(checkout_git status --porcelain --untracked-files=all) ]]
remove_hooks
checkout_reset "$base"

# 12. A failed verification of the committed source leaves a commit and no activation, and the
# next plain rebuild applies that commit without committing again.
lock_thirteen=$(lock_json rev-13)
REBUILD_AGENT_VERIFY_STATUS=1 REBUILD_LOCK_NEXT=$lock_thirteen run_rebuild 4
assert_output_has 'verification of the committed source failed'
assert_output_has 'committed but not applied'
assert_no_switch
[[ $(head_of HEAD^) == "$base" ]]
[[ $(checkout_git show HEAD:flake.lock) == "$lock_thirteen" ]]
[[ -z $(state_entries candidates) ]]
head_before=$(head_of)
run_rebuild 0
[[ $(head_of) == "$head_before" ]]
assert_called "nixos-rebuild switch --no-reexec --store-path $(system_for_lock "$lock_thirteen")"
reset_profile

# 13. A committed source that does not evaluate to the held candidate is not activated.
base=$(head_of)
REBUILD_EVAL_PATH=$REBUILD_STORE_DIR/elsewhere REBUILD_LOCK_NEXT=$(lock_json rev-14) run_rebuild 4
assert_output_has 'not to the held candidate'
assert_no_switch
[[ $(head_of HEAD^) == "$base" ]]

# 14. An edit made while the source is being verified stops the apply, and the edit stays.
base=$(head_of)
REBUILD_AGENT_VERIFY_DIRTY=1 REBUILD_LOCK_NEXT=$(lock_json rev-15) run_rebuild 4
assert_output_has 'working tree'
assert_no_switch
grep -Fxq edited-during-verify "$REBUILD_CHECKOUT/tracked"
[[ -n $(checkout_git status --porcelain) ]]
checkout_reset "$(head_of)"

# 15. A failure after activation started is partial: the commit stays, the profile is reported
# as observed, and nothing is said to be restored.
REBUILD_PARTIAL_SWITCH=1 REBUILD_SWITCH_STATUS=1 REBUILD_LOCK_NEXT=$(lock_json rev-16) run_rebuild 5
assert_output_has 'stays in the checkout'
assert_output_has 'activation-failed'
assert_failure_guidance
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$(system_for_lock "$(lock_json rev-16)")" ]]
[[ -z $(state_entries candidates) ]]
reset_profile

# 16. One writer at a time: while an apply is inside the native tool, a rollback, a discard and
# another apply are refused, and the tool is never run twice at once.
: >"$REBUILD_CALL_LOG"
rm -f -- "$REBUILD_SWITCH_STARTED" "$REBUILD_SWITCH_RELEASE" "$REBUILD_OVERLAP_LOG"
REBUILD_SWITCH_HOLD=1 REBUILD_LOCK_NEXT=$(lock_json rev-17) \
  "$REBUILD_BIN" >"$REBUILD_ROOT/first-output" 2>&1 &
first_pid=$!
wait_for_file "$REBUILD_SWITCH_STARTED"
for refused in '--rollback' '--discard 1-2' '--candidate 1-2' ''; do
  status=0
  read -r -a argv <<<"$refused"
  "$REBUILD_BIN" "${argv[@]}" >"$REBUILD_OUTPUT" 2>&1 || status=$?
  [[ $status == 2 ]]
  assert_output_has 'writer lock'
done
[[ $(grep -c '^nixos-rebuild ' "$REBUILD_CALL_LOG") == 1 ]]
: >"$REBUILD_SWITCH_RELEASE"
status=0
wait "$first_pid" || status=$?
[[ $status == 0 ]]
[[ ! -s $REBUILD_OVERLAP_LOG ]]
[[ $(grep -c '^nixos-rebuild ' "$REBUILD_CALL_LOG") == 1 ]]
reset_profile

# 17. A boot transition is switched but reported as unfinished, and WSL is not terminated.
printf 'incompatible\n' >>"$REBUILD_CANDIDATE/init-interface-version"
REBUILD_LOCK_NEXT=$(lock_json rev-18) run_rebuild 3
assert_output_has 'boot-transition'
assert_output_has "  wsl.exe --terminate 'Fixture Distro'"
assert_output_lacks 'result: applied'
assert_no_terminate
[[ $(readlink -f "$REBUILD_SYSTEM_PROFILE") == "$(system_for_lock "$(lock_json rev-18)")" ]]
printf '1\n' >"$REBUILD_CANDIDATE/init-interface-version"
reset_profile
