#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

submodule_repo=$fixture/submodule-repo

session_metadata() {
  jq -nc --arg session_id "$1" --argjson version "$2" --argjson owner_pid "$$" \
    '{version: $version, session_id: $session_id, client: "omp",
      project_id: ($session_id | split(".")[0]), boot_id: "0",
      owner_pid: $owner_pid, owner_start_time: "0"}'
}

# T1 の command の差し替え。slot は制御 file が許すまで走り続け、pass は何もせず、mutate は木を触る
slot_bin=$fixture/slot-bin
pass_bin=$fixture/pass-bin
mutate_bin=$fixture/mutate-bin

slot_commands() {
  mkdir -p "$slot_bin" "$pass_bin" "$mutate_bin"
  export PASS_LOG=$fixture/pass-log
  : >>"$PASS_LOG"
  cat >"$slot_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'start %s %s\n' "$SLOT_NAME" "$(<tracked)" >>"$SLOT_LOG"
printf '%s\n' "$$" >"$SLOT_DIR/$SLOT_NAME.pid"
: >"$SLOT_DIR/$SLOT_NAME.started"
while [ ! -e "$SLOT_DIR/$SLOT_NAME.release" ]; do
  sleep 0.05
done
printf 'end %s\n' "$SLOT_NAME" >>"$SLOT_LOG"
exit "$(cat "$SLOT_DIR/$SLOT_NAME.status" 2>/dev/null || printf 0)"
SCRIPT
  cat >"$pass_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
printf 'run\n' >>"$PASS_LOG"
SCRIPT
  cat >"$mutate_bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
case $MUTATE in
content) printf 'changed\n' >tracked ;;
touch) touch tracked ;;
artifact) printf 'output\n' >artifact ;;
layout) mkdir -p sub/.layout ;;
esac
SCRIPT
  chmod +x "$slot_bin/devenv" "$pass_bin/devenv" "$mutate_bin/devenv"
  sed -i "1c#!$BASH" "$slot_bin/devenv" "$pass_bin/devenv" "$mutate_bin/devenv"
}

# 引数 $1: 場面の名前、$2: その repository の T1 の予算秒
# 制御 directory と、tracked file を持つ T1 の repository を作り、その根へ移る
slot_prepare() {
  slot_repo=$fixture/slot-$1
  slot_dir=$fixture/slot-$1-control
  slot_log=$slot_dir/log
  mkdir -p "$slot_dir"
  : >"$slot_log"
  t1_repository "$slot_repo" "$2"
  printf 'original\n' >"$slot_repo/tracked"
  git -C "$slot_repo" add tracked
  git -C "$slot_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm tracked
  slot_file=$("$GATE" slot --repo "$slot_repo")
  cd "$slot_repo"
}

# 引数 $1: 走行の名前。制御 file の名にも使う。PID は slot_pid へ置く
slot_start() {
  SLOT_NAME=$1 SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
    "$VERIFY" -- devenv shell -- verify 2>"$slot_dir/$1.stderr" &
  slot_pid=$!
}

slot_await() {
  local _
  for _ in $(seq 1 "$mark_polls"); do
    [ ! -e "$1" ] || return 0
    sleep 0.05
  done
  echo "timed out waiting for $1" >&2
  exit 1
}

slot_await_waiting() {
  local _
  for _ in $(seq 1 "$mark_polls"); do
    if [ -s "$slot_dir/$1.stderr" ] && [[ $(<"$slot_dir/$1.stderr") == *実行枠* ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "T1 $1 never reported that it waits for the slot" >&2
  exit 1
}

slot_finish() {
  slot_status=0
  wait "$1" || slot_status=$?
}

slot_expect_free() {
  if ! flock -n "$slot_file" true; then
    echo "the slot is still held after $1" >&2
    exit 1
  fi
}

# 実行枠を T1 の外の process で握り、握ったと確かめてから返る。PID は slot_holder へ置く。解放は slot_holder を止める
# 入力 slot_file: slot_prepare が確保した実行枠 file
slot_hold() {
  local _
  "$BASH" -c 'exec {fd}>>"$1"; flock -x "$fd"; exec sleep 120' _ "$slot_file" &
  slot_holder=$!
  for _ in $(seq 1 "$mark_polls"); do
    if ! flock -n "$slot_file" true; then break; fi
    sleep 0.05
  done
  if flock -n "$slot_file" true; then
    echo 'the native holder never took the slot' >&2
    exit 1
  fi
}

# agent session が launcher の証明付きで割り当てた scratch を作る。名前は slot_session_tmp へ置く
slot_session() {
  local sessions=$home/.cache/dotfiles-wsl/sessions
  slot_session_id=fixture-slot-$1.omp.4300.AbCd1234
  slot_session_tmp=$sessions/$slot_session_id/tmp
  mkdir -p "$slot_session_tmp"
  session_metadata "$slot_session_id" 1 >"$sessions/$slot_session_id/metadata.json"
}

# 同じ project の T1 は枠の中で一度に一つだけ走り、待った走行も自分の command を実行する
check_slot_exclusive() {
  local first second
  slot_prepare exclusive 60
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  sleep 0.3
  if [ -e "$slot_dir/second.started" ]; then
    echo 'a second T1 of the same project ran its command while the first one held the slot' >&2
    exit 1
  fi
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  slot_await "$slot_dir/second.started"
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second original\nend second'
  expect_open_gate "$slot_repo" 'serialized runs'
  slot_expect_free 'both T1 runs'
}

# 枠を待つ走行を取消しても、待った走行は command を実行せず何も残さず、枠を持つ走行へ影響しない
check_slot_waiter_cancel() {
  local first second litter
  slot_prepare waiter-cancel 60
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  litter=$(stall_litter)
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  kill -TERM "$second"
  slot_finish "$second"
  test "$slot_status" -ne 0
  test ! -e "$slot_dir/second.started"
  test "$(stall_litter)" = "$litter"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first'
  expect_open_gate "$slot_repo" 'holder after a cancelled waiter'
  slot_expect_free 'a cancelled waiter'
}

# 先行の失敗は、待った走行の結果にも成功の根拠にもならない。待った走行が自分の command を実行する
check_slot_producer_failure() {
  local first second receipts
  slot_prepare producer-failure 60
  receipts=$(stall_receipt_count)
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  printf '7\n' >"$slot_dir/first.status"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 7
  slot_await "$slot_dir/second.started"
  expect_closed_gate "$slot_repo" 'failed holder while the waiter runs'
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second original\nend second'
  test "$(stall_receipt_count)" = "$((receipts + 1))"
  expect_open_gate "$slot_repo" 'waiter after a failed holder'
}

# 枠を待つ間に木が変わっても、待った走行は変わった木を実行して証跡もその木へ結ぶ。先行の証跡は借りない
check_slot_source_edit_while_waiting() {
  local first second receipts
  slot_prepare source-edit 60
  receipts=$(stall_receipt_count)
  slot_start first
  first=$slot_pid
  slot_await "$slot_dir/first.started"
  slot_start second
  second=$slot_pid
  slot_await_waiting second
  printf 'edited\n' >"$slot_repo/tracked"
  : >"$slot_dir/first.release"
  slot_finish "$first"
  test "$slot_status" -eq 0
  [[ $(<"$slot_dir/first.stderr") == *木が変わった* ]]
  test "$(stall_receipt_count)" = "$receipts"
  slot_await "$slot_dir/second.started"
  : >"$slot_dir/second.release"
  slot_finish "$second"
  test "$slot_status" -eq 0
  test "$(<"$slot_log")" = $'start first original\nend first\nstart second edited\nend second'
  expect_open_gate "$slot_repo" 'edited tree that the waiter ran'
  git -C "$slot_repo" checkout -q -- tracked
  expect_closed_gate "$slot_repo" 'original tree that no run verified'
}

# 枠の待ちには予算と同じ秒数の上限がある。上限まで枠が空かなければ command を実行せず、未実行の 75 を返して何も残さない
# 入口解決と枠の確保で予算を使い切り、枠の待ちを始める前に 124 で返った走行は、その走行だけを倍の予算でやり直す
check_slot_waiter_deadline() {
  local status litter started
  reach_begin
  while :; do
    slot_prepare "waiter-deadline-$reach_budget" "$reach_budget"
    slot_hold
    litter=$(stall_litter)
    started=$SECONDS
    status=0
    SLOT_NAME=waiter SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
      "$VERIFY" -- devenv shell -- verify 2>"$slot_dir/waiter.stderr" || status=$?
    if [ "$status" -ne 124 ] || [[ $(<"$slot_dir/waiter.stderr") == *実行枠* ]]; then break; fi
    kill "$slot_holder"
    wait "$slot_holder" || true
    reach_widen 'T1 waiting for the slot'
  done
  if [ "$status" -ne 75 ]; then
    echo "T1 that waited out its slot limit exited $status instead of 75" >&2
    exit 1
  fi
  # 待ちは予算と同じ秒数をまるごと使ってから打ち切られ、その後も長く待たない
  test "$((SECONDS - started))" -ge "$reach_budget"
  test "$((SECONDS - started))" -lt "$((reach_budget + 30))"
  test ! -e "$slot_dir/waiter.started"
  [[ $(<"$slot_dir/waiter.stderr") == *'(75)'* ]]
  test "$(stall_litter)" = "$litter"
  expect_closed_gate "$slot_repo" 'run that waited out its slot limit'
  kill "$slot_holder"
  wait "$slot_holder" || true
  widen_budget "$slot_repo"
  : >"$slot_dir/retry.release"
  SLOT_NAME=retry SLOT_DIR=$slot_dir SLOT_LOG=$slot_log PATH="$slot_bin:$PATH" \
    "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$slot_repo" 'run after the holder released the slot'
}

# 枠を待った時間は走行の予算に数えない。枠が空いた後の走行は、待たなかった場合と同じ予算の全量で自分の command を走らせる
# 待ちと走行 6 秒の合計は予算に等しく、待ち以外の所要が加わるので、待ちを数える実装は command を起動する前に 124 で返る
# 待ち以外の所要（入口解決、証跡の記録と公開）は最初の予算（16 秒）なら 10 秒に及んでも収まる。
# command を起動した後で予算を使い切った走行は、待ち以外の所要が重なった負荷の表れなので、倍の予算でやり直す
check_slot_wait_outside_budget() {
  local budget waited ran=6 waiter _
  reach_begin
  while :; do
    budget=$((reach_budget * 4))
    waited=$((budget - ran))
    slot_prepare "wait-budget-$budget" "$budget"
    slot_hold
    slot_start waiter
    waiter=$slot_pid
    slot_await_waiting waiter
    sleep "$waited"
    kill "$slot_holder"
    wait "$slot_holder" || true
    for _ in $(seq 1 "$mark_polls"); do
      [ ! -e "$slot_dir/waiter.started" ] || break
      kill -0 "$waiter" 2>/dev/null || break
      sleep 0.05
    done
    sleep "$ran"
    : >"$slot_dir/waiter.release"
    slot_finish "$waiter"
    if [ "$slot_status" -ne 124 ] || [ ! -e "$slot_dir/waiter.started" ]; then break; fi
    reach_widen 'T1 that waited for the slot'
  done
  if [ "$slot_status" -ne 0 ]; then
    echo "T1 that waited $waited seconds for the slot exited $slot_status instead of running with its whole $budget second budget" >&2
    exit 1
  fi
  test "$(<"$slot_log")" = $'start waiter original\nend waiter'
  expect_open_gate "$slot_repo" 'run that waited for the slot and then used its whole budget'
  slot_expect_free 'a run that waited for the slot'
}

# 走行の取消は、枠と木の外の一時 file と仮の控えを残さない。session の scratch も空に戻る
check_slot_cancel_cleanup() {
  local litter
  local -x DOTFILES_AGENT_SESSION_ID TMPDIR
  slot_prepare cancel-cleanup 60
  slot_session cancel-cleanup
  DOTFILES_AGENT_SESSION_ID=$slot_session_id
  TMPDIR=$slot_session_tmp
  litter=$(stall_litter)
  slot_start running
  slot_await "$slot_dir/running.started"
  kill -TERM "$slot_pid"
  slot_finish "$slot_pid"
  test "$slot_status" -ne 0
  if process_alive "$(<"$slot_dir/running.pid")"; then
    echo 'a cancelled T1 returned while its command was still running' >&2
    exit 1
  fi
  slot_expect_free 'a cancelled T1'
  test "$(stall_litter)" = "$litter"
  test -z "$(find "$slot_session_tmp" -mindepth 1 -print -quit)"
  expect_closed_gate "$slot_repo" 'cancelled run'
}

# 呼び出し元が死んでも、枠は command の子孫が消えるまで残り、残った仮の控えは次の走行が捨てる
check_slot_parent_death() {
  local litter stale _
  slot_prepare parent-death 60
  litter=$(stall_litter)
  slot_start orphaned
  slot_await "$slot_dir/orphaned.started"
  kill -KILL "$slot_pid"
  slot_finish "$slot_pid"
  for _ in $(seq 1 "$mark_polls"); do
    process_alive "$(<"$slot_dir/orphaned.pid")" || break
    sleep 0.05
  done
  if process_alive "$(<"$slot_dir/orphaned.pid")"; then
    echo 'the command outlived its killed caller' >&2
    exit 1
  fi
  for _ in $(seq 1 "$mark_polls"); do
    ! flock -n "$slot_file" true || break
    sleep 0.05
  done
  slot_expect_free 'the killed caller'
  stale=$(find "$home/.cache/dotfiles-wsl/verification" -name '.pending.*' -print -quit)
  if [ -z "$stale" ]; then
    echo 'the killed caller left no pending receipt, so the next run has nothing to reap' >&2
    exit 1
  fi
  : >"$slot_dir/next.release"
  slot_start next
  slot_finish "$slot_pid"
  test "$slot_status" -eq 0
  test "$(stall_litter)" = "$litter"
  expect_open_gate "$slot_repo" 'run after the killed caller'
}

# 引数 $1: repository、$2: 説明。command は成功し、証跡は作られない
slot_pass_refused() {
  local status=0
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify 2>"$fixture/refusal.stderr" || status=$?
  test "$status" -eq 0
  [[ $(<"$fixture/refusal.stderr") == *証跡を作らない* ]]
  expect_closed_gate "$1" "$2"
}

# 走行の間に木が触られた、または照合できない木へは証跡を作らない。command の成功は変えない
check_slot_refusals() {
  local repository=$fixture/refusal mutation status receipts
  t1_repository "$repository" 60
  printf 'original\n' >"$repository/tracked"
  git -C "$repository" add tracked
  git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm tracked
  cd "$repository"
  receipts=$(stall_receipt_count)
  for mutation in content touch artifact; do
    status=0
    MUTATE=$mutation PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify \
      2>"$fixture/refusal-$mutation.stderr" || status=$?
    test "$status" -eq 0
    [[ $(<"$fixture/refusal-$mutation.stderr") == *木が変わった* ]]
    expect_closed_gate "$repository" "tree touched by T1 ($mutation)"
    test "$(stall_receipt_count)" = "$receipts"
    git -C "$repository" checkout -q -- tracked
    rm -f "$repository/artifact"
    expect_closed_gate "$repository" "restored tree after T1 ($mutation)"
  done
  MUTATE=none PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'T1 that left the tree alone'

  # 汚れた gitlink、変更検出を偽る印、.git の無い gitlink は照合できない。gitlink の配置は照合値へ入らない
  repository=$fixture/refusal-gitlink
  t1_repository "$repository" 60
  git -C "$repository" -c protocol.file.allow=always submodule add -q "$submodule_repo" sub
  git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm submodule
  cd "$repository"
  printf 'dirty\n' >"$repository/sub/untracked"
  slot_pass_refused "$repository" 'untracked file in a gitlink'
  rm "$repository/sub/untracked"
  git -C "$repository/sub" update-index --assume-unchanged tracked
  printf 'changed\n' >"$repository/sub/tracked"
  slot_pass_refused "$repository" 'assume-unchanged content in a gitlink'
  git -C "$repository/sub" update-index --no-assume-unchanged tracked
  git -C "$repository/sub" checkout -q -- tracked
  mv "$repository/sub/.git" "$fixture/refusal-sub-dotgit"
  slot_pass_refused "$repository" 'gitlink without its own repository'
  mv "$fixture/refusal-sub-dotgit" "$repository/sub/.git"
  MUTATE=layout PATH="$mutate_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'clean gitlink whose directory layout changed during T1'
}

# 一時 file が検査する木の中へ入る TMPDIR は、symlink 越しでも証跡を作らない。空の TMPDIR は未指定と同じである
check_slot_tmpdir() {
  local repository=$fixture/tmpdir status tmpdir
  t1_repository "$repository" 60
  mkdir "$repository/scratch"
  ln -s "$repository/scratch" "$fixture/tmpdir-link"
  cd "$repository"
  for tmpdir in "$repository/scratch" "$fixture/tmpdir-link"; do
    status=0
    TMPDIR=$tmpdir PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify \
      2>"$fixture/tmpdir.stderr" || status=$?
    test "$status" -eq 0
    [[ $(<"$fixture/tmpdir.stderr") == *TMPDIR* ]]
    expect_closed_gate "$repository" "TMPDIR $tmpdir inside the tree"
  done
  TMPDIR='' PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  expect_open_gate "$repository" 'empty TMPDIR'
}

# 検証の状態は自分だけが書ける実 directory に直し、symlink や他人の directory へは控えも枠も置かず command も実行しない
check_slot_state_directories() {
  local repository=$fixture/state-directories state foreign=$fixture/foreign-state status runs
  t1_repository "$repository" 60
  cd "$repository"
  mkdir -p "$home/.cache/dotfiles-wsl/verification"
  chmod 0777 "$home/.cache/dotfiles-wsl" "$home/.cache/dotfiles-wsl/verification"
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify
  state=$(dirname "$("$GATE" slot --repo "$repository")")
  test "$(stat -c %a "$home/.cache/dotfiles-wsl")" = 700
  test "$(stat -c %a "$home/.cache/dotfiles-wsl/verification")" = 700
  test "$(stat -c %a "$state")" = 700
  test "$(stat -c %a "$state/run.lock")" = 600
  rm -rf "$state"
  mkdir "$foreign"
  ln -s "$foreign" "$state"
  runs=$(wc -l <"$PASS_LOG")
  status=0
  PATH="$pass_bin:$PATH" "$VERIFY" -- devenv shell -- verify 2>"$fixture/state-symlink.stderr" || status=$?
  test "$status" -ne 0
  test "$(wc -l <"$PASS_LOG")" -eq "$runs"
  test -z "$(find "$foreign" -mindepth 1 -print -quit)"
  rm "$state"
}

check_verification_slot() {
  local previous=$PWD
  slot_commands
  check_slot_exclusive
  check_slot_waiter_cancel
  check_slot_producer_failure
  check_slot_source_edit_while_waiting
  check_slot_waiter_deadline
  check_slot_wait_outside_budget
  check_slot_cancel_cleanup
  check_slot_parent_death
  check_slot_refusals
  check_slot_tmpdir
  check_slot_state_directories
  cd "$previous"
}

mkdir -p "$home" "$submodule_repo"
git -C "$submodule_repo" init -q
git -C "$submodule_repo" config user.name fixture
git -C "$submodule_repo" config user.email fixture@example.invalid
printf 'nested\n' >"$submodule_repo/tracked"
git -C "$submodule_repo" add tracked
git -C "$submodule_repo" commit -qm initial

check_verification_slot
