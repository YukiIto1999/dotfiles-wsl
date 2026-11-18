#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

# 資源予約つきの T1 は、鍵 verify と repository の根と入口の command を改行でつないだ文字列で実測を記録する。
# 記録は sandbox の HOME ではなくこの fixture 専用の directory へ書く
resource_state=$fixture/resource-state
resource_repo=$fixture/resource-key-repo
t1_repository "$resource_repo" 60
mkdir "$fixture/resource-bin"
printf '#!%s\nsleep 0.3\n' "$BASH" >"$fixture/resource-bin/devenv"
chmod +x "$fixture/resource-bin/devenv"
(cd "$resource_repo" && XDG_STATE_HOME=$resource_state PATH="$fixture/resource-bin:$PATH" \
  "$RESOURCE_VERIFY" -- devenv shell -- verify)
resource_digest=$(printf 'verify\n%s\n%s' "$resource_repo" 'devenv shell -- verify' | sha256sum | cut -d' ' -f1)
test -s "$resource_state/dotfiles-wsl/workload/demand/$resource_digest.json" || {
  echo 'T1 under a resource policy did not record its memory peak under the verify key' >&2
  exit 1
}

# 入場の待ちは T1 の予算に数えず、走行の枠だけを予算で数える。待った後の走行は、待たなかった場合と同じ予算で完走する。
# 待ちと走行 6 秒の合計は予算に等しく、待ち以外の所要が加わるので、待ちを数える実装は command を起動する前に 124 で返る。
# 待ち以外の所要は最初の予算（16 秒）なら 10 秒に及んでも収まる。command を起動した後で予算を使い切った走行は、
# 待ち以外の所要が重なった負荷の表れなので、倍の予算でやり直す
# 待ちの上限は予算と同じ秒数で、超えると command を実行せず 75 を返し、証跡を公開しない
mkdir "$fixture/resource-slow-bin"
printf '#!%s\ntouch "$WAIT_STARTED"\nsleep 6\n' "$BASH" >"$fixture/resource-slow-bin/devenv"
chmod +x "$fixture/resource-slow-bin/devenv"
pressure=$fixture/resource-pressure
reach_begin
while :; do
  wait_budget=$((reach_budget * 4))
  wait_repo=$fixture/resource-wait-repo-$wait_budget
  t1_repository "$wait_repo" "$wait_budget"
  : >"$pressure"
  : >"$fixture/wait.stderr"
  (cd "$wait_repo" && WAIT_STARTED=$fixture/wait-started-$wait_budget AGENT_RESOURCE_PRESSURE_FILE=$pressure \
    XDG_STATE_HOME=$resource_state PATH="$fixture/resource-slow-bin:$PATH" "$RESOURCE_VERIFY" -- devenv shell -- verify) 2>"$fixture/wait.stderr" &
  waiting_pid=$!
  # 入場の待ちが始まったと分かってから、走行 6 秒を足して予算になる秒数だけ押さえる。入場を求めるまでの所要は待ちの長さに響かない
  for _ in $(seq 1 "$mark_polls"); do
    if [[ $(<"$fixture/wait.stderr") == *'waiting for resources'* ]]; then break; fi
    sleep 0.05
  done
  if [[ $(<"$fixture/wait.stderr") != *'waiting for resources'* ]]; then
    kill -TERM "$waiting_pid" 2>/dev/null || true
    wait "$waiting_pid" || true
    echo 'T1 under resource pressure never reported that it waits' >&2
    exit 1
  fi
  sleep "$((wait_budget - 6))"
  rm -f "$pressure"
  wait_status=0
  wait "$waiting_pid" || wait_status=$?
  if [ "$wait_status" -ne 124 ] || [ ! -e "$fixture/wait-started-$wait_budget" ]; then break; fi
  reach_widen 'T1 that waited for resources'
done
test "$wait_status" -eq 0
expect_open_gate "$wait_repo" 'T1 that waited for resources and then ran inside its budget'
: >"$pressure"
reach_begin
while :; do
  limit_repo=$fixture/resource-limit-repo-$reach_budget
  t1_repository "$limit_repo" "$reach_budget"
  limit_status=0
  (cd "$limit_repo" && AGENT_RESOURCE_PRESSURE_FILE=$pressure XDG_STATE_HOME=$resource_state \
    PATH="$fixture/resource-bin:$PATH" "$RESOURCE_VERIFY" -- devenv shell -- verify) 2>"$fixture/limit.stderr" || limit_status=$?
  # 入場を求める前に予算を使い切った走行（124）は待ちの上限へ届いていないので、予算を伸ばしてやり直す
  if [ "$limit_status" -ne 124 ] || [[ $(<"$fixture/limit.stderr") == *'waiting for resources'* ]]; then break; fi
  reach_widen 'T1 waiting for resources'
done
rm -f "$pressure"
test "$limit_status" -eq 75 || {
  echo "T1 that could not enter within its wait limit returned $limit_status instead of 75" >&2
  exit 1
}
grep -qF '(75)' "$fixture/limit.stderr"
expect_closed_gate "$limit_repo" 'T1 that was never started'

# 時間の目標は報告するだけで、走行を取り消さず、終了statusも変えない。滞留は走行の scope の cgroup の値で、
# fixture の scope は cgroup の file を持たないため、command が書いた file だけが読める。scope は最後の processごと消えるので、
# command の終了後も残る子を置き、終了時の読取がその scope を読めるようにする
target_bin=$fixture/target-bin
mkdir "$target_bin"
cat >"$target_bin/devenv" <<'SCRIPT'
#!BASH
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=500000\n' >"$DOTFILES_FAKE_SCOPE/cpu.pressure"
sleep 600 </dev/null >/dev/null 2>&1 &
sleep 2
SCRIPT
sed -i "1c#!$BASH" "$target_bin/devenv"
chmod +x "$target_bin/devenv"
# 目標を超えて上限の内に終わる走行は 0 で返り、証跡を公開し、目標を超えた旨の一行だけを出す
over_repo=$fixture/resource-over-target-repo
t1_repository "$over_repo" "$completion_budget" 1
over_status=0
(cd "$over_repo" && XDG_STATE_HOME=$resource_state PATH="$target_bin:$PATH" \
  "$RESOURCE_VERIFY" -- devenv shell -- verify) 2>"$fixture/over.stderr" || over_status=$?
test "$over_status" -eq 0
expect_open_gate "$over_repo" 'T1 that exceeded its target and finished inside its limit'
test "$(grep -c '時間の目標' "$fixture/over.stderr")" -eq 1
grep -qE '時間の目標 1 秒を超えた\(走行 [0-9]+ 秒、滞留の割合は CPU [0-9]+%、IO 不明、メモリ 不明\)$' "$fixture/over.stderr"
# 目標の内に終わる走行は何も出さない
within_repo=$fixture/resource-within-target-repo
t1_repository "$within_repo" "$completion_budget" "$((completion_budget / 2))"
(cd "$within_repo" && XDG_STATE_HOME=$resource_state PATH="$target_bin:$PATH" \
  "$RESOURCE_VERIFY" -- devenv shell -- verify) 2>"$fixture/within.stderr"
expect_open_gate "$within_repo" 'T1 that finished inside its target'
test "$(grep -c '時間の目標' "$fixture/within.stderr")" -eq 0

# 上限で取り消された走行は 124 のまま、目標の時点から scope の CPU 時間が増えたかを添える。
# command は目標の後に CPU 時間を書き足すか、書き足さずに止まり続ける。書き足す場面に届く前に上限が来た走行は負荷の表れなので、
# その走行だけを倍の予算でやり直す
limit_bin=$fixture/target-limit-bin
mkdir "$limit_bin"
cat >"$limit_bin/devenv" <<'SCRIPT'
#!BASH
printf 'usage_usec 1000000\n' >"$DOTFILES_FAKE_SCOPE/cpu.stat"
sleep 600 </dev/null >/dev/null 2>&1 &
sleep 2.5
[ "$PROGRESS" != 1 ] || printf 'usage_usec 3000000\n' >"$DOTFILES_FAKE_SCOPE/cpu.stat"
touch "$PAST_TARGET"
exec sleep 600
SCRIPT
sed -i "1c#!$BASH" "$limit_bin/devenv"
chmod +x "$limit_bin/devenv"
for progress in 1 0; do
  reach_begin
  while :; do
    cancel_repo=$fixture/resource-cancel-repo-$progress-$reach_budget
    t1_repository "$cancel_repo" "$reach_budget" 2
    cancel_status=0
    (cd "$cancel_repo" && PROGRESS=$progress PAST_TARGET=$fixture/past-target-$progress-$reach_budget \
      XDG_STATE_HOME=$resource_state PATH="$limit_bin:$PATH" \
      "$RESOURCE_VERIFY" -- devenv shell -- verify) 2>"$fixture/cancel.stderr" || cancel_status=$?
    [ ! -e "$fixture/past-target-$progress-$reach_budget" ] || break
    reach_widen 'T1 cancelled at its limit after its target'
  done
  test "$cancel_status" -eq 124
  expect_closed_gate "$cancel_repo" 'T1 cancelled at its limit'
  test "$(grep -c '時間の目標' "$fixture/cancel.stderr")" -eq 1
  grep -qE '時間の目標 2 秒を超えた\(走行 [0-9]+ 秒、滞留の割合は CPU 不明、IO 不明、メモリ 不明\)。上限で取り消された。' "$fixture/cancel.stderr"
  if [ "$progress" -eq 1 ]; then
    grep -qF '目標の時点から scope の CPU 時間は増えていた(進行中)' "$fixture/cancel.stderr"
  else
    grep -qF '目標の時点から scope の CPU 時間は増えていない(進行の兆しが無い)' "$fixture/cancel.stderr"
  fi
done
