#!/usr/bin/env bash
set -euo pipefail


# shellcheck source=/dev/null
source "${1:?harness is required}"
harness_init "${2:?rebuild entrypoint is required}" "${3:?fixture dependencies are required}" \
  "${4:?restart planner is required}"
group=${5:?scenario group is required}

concurrent_lock=$(lock_json rev-concurrent)

# 値の一致を要求する検査
# $1: 実際の値
# $2: 期待する値
# $3: 失敗時の検査名
# 失敗: 不一致時のscenario全体の終了
expect_equal() {
  if [[ $1 != "$2" ]]; then
    printf '%s: expected "%s", got "%s"\n' "$3" "$2" "$1" >&2
    exit 1
  fi
}

# build中に編集したlockのbyteとHEADと未適用状態の保持の検査
# 引数なし
# 副作用: 検査終了時のcheckoutの基点への復元
edit_while_built() {
  local base build_status
  base=$(head_of)
  for build_status in 0 1; do
    REBUILD_BUILD_STATUS=$build_status REBUILD_EDIT_AT=build REBUILD_EDIT_FILE=flake.lock REBUILD_EDIT_CONTENT=$concurrent_lock \
      run_rebuild 4
    assert_no_switch
    expect_equal "$(head_of)" "$base" 'HEAD after a lock edit made while the candidate was built'
    expect_equal "$(<"$REBUILD_CHECKOUT/flake.lock")" "$concurrent_lock" 'the working tree flake.lock after the concurrent edit'
    [[ $(checkout_git --no-optional-locks status --porcelain) == ' M flake.lock' ]]
    [[ -z $(state_entries candidates) ]]
    assert_no_work_left
    checkout_reset "$base"
  done
}

# plan表示中にstageしたlockのfileとindexの保持の検査
# 引数なし
# 副作用: 検査終了時のcheckoutの基点への復元
staged_edit_while_shown() {
  local base held
  base=$(head_of)
  run_rebuild 0 --plan
  held=$(candidate_id_of_output)
  REBUILD_EDIT_AT=show REBUILD_EDIT_RECORD=stage REBUILD_EDIT_FILE=flake.lock \
    REBUILD_EDIT_CONTENT=$concurrent_lock run_rebuild 4 --candidate "$held"
  assert_no_switch
  [[ $(head_of) == "$base" ]]
  [[ $(<"$REBUILD_CHECKOUT/flake.lock") == "$concurrent_lock" ]]
  [[ $(checkout_git show :flake.lock) == "$concurrent_lock" ]]
  [[ -z $(state_entries candidates) ]]
  checkout_reset "$base"
}

# build中に作成した別commitを上書きしない未適用状態の検査
# 引数なし
# 副作用: 検査終了時のcheckoutの基点への復元
commit_while_built() {
  local base
  base=$(head_of)
  REBUILD_EDIT_AT=build REBUILD_EDIT_RECORD=commit REBUILD_EDIT_FILE=tracked \
    REBUILD_EDIT_CONTENT=concurrent run_rebuild 4
  assert_no_switch
  [[ $(checkout_git log -1 --format=%s) == 'concurrent edit' ]]
  [[ $(head_of HEAD^) == "$base" ]]
  [[ $(checkout_git show HEAD:flake.lock) == "$(checkout_git show "$base:flake.lock")" ]]
  checkout_reset "$base"
}

# source-bound検証中に作成した別commitを上書きしない未適用状態の検査
# 引数なし
# 副作用: 検査終了時のcheckoutの基点への復元
commit_while_verified() {
  local base
  base=$(head_of)
  REBUILD_EDIT_AT=agent-verify REBUILD_EDIT_RECORD=commit REBUILD_EDIT_FILE=tracked \
    REBUILD_EDIT_CONTENT=concurrent run_rebuild 4
  assert_output_has 'HEAD moved'
  assert_no_switch
  expect_equal "$(checkout_git log -1 --format=%s)" 'concurrent edit' 'HEAD subject after a commit made while the source was verified'
  expect_equal "$(head_of HEAD^)" "$base" 'parent of the commit made while the source was verified'
  [[ -z $(state_entries candidates) ]]
  assert_no_work_left
  checkout_reset "$base"
}

declare -A plan_pids
# 差分表示で停止するplanの起動
# $1: この検査内で一意なplanの名前
# 副作用: plan_pidsへのPIDの記録と名前に対応する同期fileの作成
hold_plan_at_diff() {
  local name=$1
  rm -f -- "$REBUILD_ROOT/ready-$name" "$REBUILD_ROOT/release-$name"
  REBUILD_NVD_HOLD=1 REBUILD_NVD_READY=$REBUILD_ROOT/ready-$name \
    REBUILD_NVD_RELEASE=$REBUILD_ROOT/release-$name \
    "$REBUILD_BIN" --plan >"$REBUILD_ROOT/plan-$name" 2>&1 &
  plan_pids[$name]=$!
  wait_for_file "$REBUILD_ROOT/ready-$name"
}
# 差分表示で停止しているplanの再開
# $1: planの名前
release_plan() { : >"$REBUILD_ROOT/release-$1"; }
# 再開済みplanの成功を要求する終了待ち
# $1: planの名前
# 失敗: 非0の終了statusの表示とscenario全体の終了
await_plan() {
  local status=0
  wait "${plan_pids[$1]}" || status=$?
  if [[ $status != 0 ]]; then
    cat "$REBUILD_ROOT/plan-$1" >&2
    printf 'plan %s returned %s\n' "$1" "$status" >&2
    exit 1
  fi
}

# 順番に公開したplanによる旧候補の失効と最新候補の適用の検査
# 引数なし
# 副作用: 適用終了時のfixtureのsystem profileの復元
planners_publish_in_turn() {
  local first_id second_id
  hold_plan_at_diff first
  hold_plan_at_diff second
  release_plan first
  await_plan first
  release_plan second
  await_plan second
  first_id=$(candidate_id_of_output "$REBUILD_ROOT/plan-first")
  second_id=$(candidate_id_of_output "$REBUILD_ROOT/plan-second")
  expect_equal "$(state_entries candidates)" "$second_id" 'the held candidates after two plans published in turn'
  [[ -d $REBUILD_STATE/candidates/$second_id/toplevel ]]
  run_rebuild 2 --candidate "$first_id"
  run_rebuild 0 --candidate "$second_id"
  reset_profile
}

# 同時に公開したplanが実際に適用可能な一候補を残す検査
# 引数なし
# 副作用: 適用終了時のfixtureのsystem profileの復元
planners_publish_together() {
  local left_id right_id kept
  hold_plan_at_diff left
  hold_plan_at_diff right
  release_plan left
  release_plan right
  await_plan left
  await_plan right
  left_id=$(candidate_id_of_output "$REBUILD_ROOT/plan-left")
  right_id=$(candidate_id_of_output "$REBUILD_ROOT/plan-right")
  kept=$(state_entries candidates)
  if [[ $kept != "$left_id" && $kept != "$right_id" ]]; then
    printf 'held candidates are "%s" after two plans published together; they printed %s and %s\n' "$kept" "$left_id" "$right_id" >&2
    exit 1
  fi
  [[ -d $REBUILD_STATE/candidates/$kept/toplevel ]]
  run_rebuild 0 --candidate "$kept"
  reset_profile
}

# 適用中の候補を後続planが解放しない検査
# 引数なし
# 副作用: 保持中のactivationの再開とfixtureのsystem profileの復元
plan_during_apply() {
  local applying following apply_pid status=0
  run_rebuild 0 --plan
  applying=$(candidate_id_of_output)
  rm -f -- "$REBUILD_SWITCH_STARTED" "$REBUILD_SWITCH_RELEASE"
  REBUILD_SWITCH_HOLD=1 "$REBUILD_BIN" --candidate "$applying" >"$REBUILD_ROOT/applying-output" 2>&1 &
  apply_pid=$!
  wait_for_file "$REBUILD_SWITCH_STARTED"
  run_rebuild 0 --plan
  following=$(candidate_id_of_output)
  [[ -d $REBUILD_STATE/candidates/$applying ]]
  [[ -f $REBUILD_STATE/candidates/$following/receipt ]]
  : >"$REBUILD_SWITCH_RELEASE"
  wait "$apply_pid" || status=$?
  [[ $status == 0 ]]
  [[ $(state_entries candidates) == "$following" ]]
  run_rebuild 0 --candidate "$following"
  reset_profile
}

# 差分表示中の取消による既存候補とsystemの保持の検査
# 引数なし
cancel_while_shown() {
  local held_before status=0
  : >"$REBUILD_CALL_LOG"
  held_before=$(state_entries candidates)
  hold_plan_at_diff cancelled
  kill -TERM "${plan_pids[cancelled]}"
  release_plan cancelled
  wait "${plan_pids[cancelled]}" || status=$?
  expect_equal "$status" 130 'exit status of a plan cancelled while it was shown'
  expect_equal "$(state_entries candidates)" "$held_before" 'the held candidates after a plan cancelled while it was shown'
  assert_no_work_left
  assert_no_switch
}

# 公開区間へ入る前の取消による既存候補の保持の検査
# 引数なし
# 戻り値: 既存候補の置換または成功扱いを検出した場合の非ゼロ
cancel_while_publication_waits() {
  local held blocked status=0 lock_fd
  run_rebuild 0 --plan
  held=$(candidate_id_of_output)
  exec {lock_fd}>"$REBUILD_STATE/publish.lock"
  flock "$lock_fd"
  hold_plan_at_diff waiting
  blocked=$(candidate_id_of_output "$REBUILD_ROOT/plan-waiting")
  release_plan waiting
  wait_for_file "$REBUILD_STATE/candidates/$blocked/receipt.tmp"
  kill -TERM "${plan_pids[waiting]}"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  wait "${plan_pids[waiting]}" || status=$?
  expect_equal "$status" 130 'exit status of a plan cancelled before publication'
  expect_equal "$(state_entries candidates)" "$held" 'candidate retained after cancellation at publication'
  assert_no_work_left
  assert_no_switch
}

case $group in
edits)
  edit_while_built
  staged_edit_while_shown
  commit_while_built
  commit_while_verified
  ;;
planners)
  planners_publish_in_turn
  planners_publish_together
  plan_during_apply
  ;;
cancelled-plan)
  cancel_while_shown
  cancel_while_publication_waits
  ;;
*)
  printf 'unknown scenario group: %s\n' "$group" >&2
  exit 64
  ;;
esac
