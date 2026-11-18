#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

# 終了待機前の観測情報による元 process の消滅判定
# 引数 $1: 観測済みの Linux process 番号
# 引数 $2: 同じ boot 内で観測した開始 tick
# 戻り値: 観測不能か開始 tick の変化で0となる判定結果
# zombie は回収前のため state だけによる完了判定は不可
# pid の再利用があるため pid だけによる寿命の照合は不可
process_reaped() {
  local proc_stat
  local -a proc_fields
  proc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  read -r -a proc_fields <<<"${proc_stat##*) }"
  [ "${proc_fields[19]}" != "$2" ]
}

check_metadata_snapshot_boundary() (
  local repository name status receipts litter
  export HOME=$home BOUNDARY_JQ
  BOUNDARY_JQ=$(command -v jq)
  mkdir -p "$home/.cache/dotfiles-wsl/verification" "$fixture/snapshot-bin"
  # 取消されなければ期限より長く生きる孫を持つ nix の代役。孫の PID を残してから、起動した印を書く
  cat >"$fixture/snapshot-bin/nix" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
sleep "$SNAPSHOT_CHILD_LIFE" &
printf '%s\n' "$!" >"$SNAPSHOT_CHILD"
printf run >"$SNAPSHOT_RUN"
wait
SCRIPT
  sed -i "1c#!$BASH" "$fixture/snapshot-bin/nix"
  chmod +x "$fixture/snapshot-bin/nix"
  export PATH="$fixture/snapshot-bin:$PATH"
  jq() {
    local result status=0
    if [[ " $* " == *" --arg stage verify "* && ! -e $SNAPSHOT_PROOF ]]; then
      result=$("$BOUNDARY_JQ" "$@") || status=$?
      if [ "$status" -eq 0 ]; then
        case $SNAPSHOT_CHANGE in
          removed-entry) printf '{"version":1,"frontend":"nix","entries":[],"verify":{"seconds":%s}}\n' "$SNAPSHOT_BUDGET" >"$SNAPSHOT_METADATA" ;;
          deleted) rm -- "$SNAPSHOT_METADATA" ;;
          malformed) printf 'not json\n' >"$SNAPSHOT_METADATA" ;;
        esac
        printf after-budget >"$SNAPSHOT_PROOF"
      fi
      printf '%s\n' "$result"
      return "$status"
    fi
    "$BOUNDARY_JQ" "$@"
  }
  export -f jq
  for name in removed-entry deleted malformed; do
    reach_begin
    while :; do
      repository=$fixture/snapshot-$name-$reach_budget
      git init -q "$repository"
      printf '{ outputs = { self }: {}; }\n' >"$repository/flake.nix"
      printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":%s}}\n' "$reach_budget" \
        >"$repository/tiergate.json"
      git -C "$repository" add flake.nix tiergate.json
      git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
      export SNAPSHOT_METADATA=$repository/tiergate.json SNAPSHOT_CHANGE=$name SNAPSHOT_BUDGET=$reach_budget
      export SNAPSHOT_PROOF=$fixture/snapshot-$name-$reach_budget-proof SNAPSHOT_RUN=$fixture/snapshot-$name-$reach_budget-run
      export SNAPSHOT_CHILD=$fixture/snapshot-$name-$reach_budget-child SNAPSHOT_CHILD_LIFE=$((reach_budget + 60))
      receipts=$(stall_receipt_count)
      litter=$(stall_litter)
      status=0
      (cd "$repository" && timeout "$((reach_budget + 60))" "$VERIFY" -- nix run --no-write-lock-file .#verify) \
        2>"$fixture/snapshot-$name-stderr" || status=$?
      # 期限が nix の起動より先に来た走行は、負荷の表れとして予算を伸ばしてやり直す
      if [ "$status" -ne 124 ] || [ -e "$SNAPSHOT_RUN" ]; then break; fi
      reach_widen "canonical T1 after a $name metadata edit"
    done
    if [ "$status" -ne 124 ]; then
      echo "canonical T1 after a $name metadata edit exited $status instead of retaining its captured deadline" >&2
      exit 1
    fi
    test "$(cat "$SNAPSHOT_PROOF")" = after-budget
    test "$(cat "$SNAPSHOT_RUN")" = run
    # 期限で取消された nix の孫は、返却の時点で回収済みである
    if process_alive "$(<"$SNAPSHOT_CHILD")"; then
      echo "the descendant of the canonical T1 after a $name metadata edit outlived its captured deadline" >&2
      exit 1
    fi
    test "$(stall_receipt_count)" = "$receipts"
    test "$(stall_litter)" = "$litter"
    git -C "$repository" restore --worktree -- tiergate.json
    expect_closed_gate "$repository" "$name snapshot race"
  done
  printf '#!%s\nprintf focused >"$SNAPSHOT_RUN"\n' "$BASH" >"$fixture/snapshot-bin/focused"
  chmod +x "$fixture/snapshot-bin/focused"
  for name in missing invalid-budget malformed; do
    case $name in
      missing) rm -- "$SNAPSHOT_METADATA" ;;
      invalid-budget) printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":0}}\n' >"$SNAPSHOT_METADATA" ;;
      malformed) printf 'not json\n' >"$SNAPSHOT_METADATA" ;;
    esac
    rm -f "$SNAPSHOT_RUN"
    status=0
    (cd "$repository" && timeout "$completion_budget" "$VERIFY" -- nix run --no-write-lock-file .#verify) \
      2>"$fixture/snapshot-initial-$name-stderr" || status=$?
    if [ "$status" -ne 78 ]; then
      echo "canonical T1 with $name metadata exited $status instead of refusing configuration" >&2
      exit 1
    fi
    test ! -e "$SNAPSHOT_RUN"
    [[ $(<"$fixture/snapshot-initial-$name-stderr") == *tiergate.json* ]]
    (cd "$repository" && "$VERIFY" -- "$fixture/snapshot-bin/focused")
    test "$(cat "$SNAPSHOT_RUN")" = focused
    test "$(stall_receipt_count)" = "$receipts"
    git -C "$repository" restore --worktree -- tiergate.json
    expect_closed_gate "$repository" "$name metadata refusal"
  done
)

# 予算が読めない間は、評価が止まる Nix の宣言も評価しない。
# 入口の綴りと一致する呼び出しだけを実行せず、隣の局所 command は証跡なしで従来どおり走る。
# 評価器が起動すると止まるため、待ち続けず時間を区切って呼ぶ。
stalled_repo=$fixture/stalled-nix-repo
git init -q "$stalled_repo"
cat >"$stalled_repo/flake.nix" <<'NIX'
{
  outputs = { self }: {
    apps =
      let fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2);
      in if fib 60 > 0 then { } else { };
  };
}
NIX
git -C "$stalled_repo" add flake.nix
git -C "$stalled_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
cd "$stalled_repo"
receipts_before=$(stall_receipt_count)
rm -f "$fixture/stalled-focused-count"
started=$SECONDS
COUNT=$fixture/stalled-focused-count NIX_REMOTE="$fixture/nix-store" \
  NIX_CONFIG="experimental-features = nix-command flakes" \
  timeout 60 "$VERIFY" -- "$fixture/check" focused-beside-nix
test "$(cat "$fixture/stalled-focused-count")" = 1
test "$((SECONDS - started))" -lt 30
test "$(stall_receipt_count)" = "$receipts_before"
status=0
NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
  timeout 60 "$VERIFY" -- nix run --no-write-lock-file .#verify 2>"$fixture/stalled-refused-stderr" || status=$?
if [ "$status" -ne 78 ] || [[ $(<"$fixture/stalled-refused-stderr") != *tiergate.json* ]]; then
  echo "T1 spelled as the native entry beside an unreadable budget exited $status instead of refusing" >&2
  exit 1
fi
test "$(stall_receipt_count)" = "$receipts_before"
test -z "$(timeout 60 "$GATE" entry --repo "$stalled_repo")"
test "$(timeout 60 "$GATE" candidates --repo "$stalled_repo")" = 'nix run --no-write-lock-file .#verify'
timeout 60 "$GATE" check --repo "$stalled_repo" >/dev/null

# mock の待機は実 Nix の signal 応答を検査できないため不可
real_nix=$(command -v nix)
mkdir "$fixture/nix-observer-bin"
cat >"$fixture/nix-observer-bin/nix" <<'SCRIPT'
#!/usr/bin/env bash
process_stat=$(<"/proc/$$/stat")
read -r -a process_fields <<<"${process_stat##*) }"
printf '%s %s\n' "$$" "${process_fields[19]}" >>"$OBSERVED_NIX_PROCESSES"
exec "$OBSERVED_NIX" "$@"
SCRIPT
chmod +x "$fixture/nix-observer-bin/nix"
sed -i "1c#!$BASH" "$fixture/nix-observer-bin/nix"
# 外側 guard の取消を wrapper の期限と混同するため、終了statusだけの判定は不可
reach_begin
while :; do
  printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":%s}}\n' "$reach_budget" \
    >"$stalled_repo/tiergate.json"
  git -C "$stalled_repo" add tiergate.json
  git -C "$stalled_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm budget
  litter_before=$(stall_litter)
  rm -f "$fixture/stalled-nix.processes"
  status=0
  started=$SECONDS
  PATH="$fixture/nix-observer-bin:$PATH" OBSERVED_NIX=$real_nix \
    OBSERVED_NIX_PROCESSES=$fixture/stalled-nix.processes \
    NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
    timeout --preserve-status "$((reach_budget + 60))" "$VERIFY" -- nix run --no-write-lock-file .#verify || status=$?
  elapsed=$((SECONDS - started))
  # 期限が評価器の起動より先に来た走行は、負荷の表れとして予算を伸ばしてやり直す
  if [ "$status" -ne 124 ] || [ -s "$fixture/stalled-nix.processes" ]; then break; fi
  reach_widen 'T1 over a stalled Nix declaration'
done
if [ "$status" -eq 0 ] || [ "$elapsed" -lt 1 ] || [ "$elapsed" -ge "$((reach_budget + 60))" ]; then
  echo "T1 over a stalled Nix declaration returned status $status after ${elapsed}s outside its cancellation window" >&2
  exit 1
fi
if [ ! -s "$fixture/stalled-nix.processes" ]; then
  echo 'T1 over a stalled Nix declaration never started the evaluator' >&2
  exit 1
fi
while read -r observed_pid observed_start; do
  if ! process_reaped "$observed_pid" "$observed_start"; then
    echo 'T1 over a stalled Nix declaration returned before its evaluator was reaped' >&2
    exit 1
  fi
done <"$fixture/stalled-nix.processes"
expect_closed_gate_within() {
  local gate_status=0
  started=$SECONDS
  NIX_REMOTE="$fixture/nix-store" NIX_CONFIG="experimental-features = nix-command flakes" \
    timeout "$((reach_budget + 60))" "$GATE" check --repo "$1" >/dev/null 2>&1 || gate_status=$?
  if [ "$gate_status" -eq 0 ] || [ "$((SECONDS - started))" -ge "$((reach_budget + 30))" ]; then
    echo "gate over a stalled Nix declaration exited $gate_status instead of stopping at its budget" >&2
    exit 1
  fi
}
expect_closed_gate_within "$stalled_repo"
test "$(stall_litter)" = "$litter_before"
test "$(stall_receipt_count)" = "$receipts_before"
rm "$stalled_repo/tiergate.json"
expect_closed_gate_within "$stalled_repo"
status=0
timeout 60 "$VERIFY" -- nix run --no-write-lock-file .#verify >/dev/null 2>&1 || status=$?
test "$status" -eq 78
test "$(stall_receipt_count)" = "$receipts_before"

check_metadata_snapshot_boundary
