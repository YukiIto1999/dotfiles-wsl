set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verify -- COMMAND [ARG...]\n' >&2
  exit 64
}

started_ms=$((${EPOCHREALTIME/[.,]/} / 1000))
budget_seconds=
budget_error=
# 走行の目標秒。目標を宣言していなければ空。目標は報告するだけで、取消にも判定にも使わない
feedback_target=
remaining=
# 同じ project の T1 を一度に一つへ絞る flock の fd。取得するまで空
slot_fd=
# 実行枠の取得に待った ms。枠を待たなかった走行は 0。入口を実行する supervise の記録へ slotWaitSeconds として渡す
slot_wait_ms=0
resource_policy=@resourcePolicy@
resource_args=()
# 資源予約の需要を実測の記録から決める鍵。repository の根と入口の command ごとに分ける
resource_key=
# 検査入口の完了と資源を待った時間を supervisor が記録する --result の file
resource_result=

refresh_remaining() {
  local left=$((budget_seconds * 1000 - (${EPOCHREALTIME/[.,]/} / 1000 - started_ms)))
  [ "$left" -gt 0 ] || return 1
  printf -v remaining '%d.%03d' "$((left / 1000))" "$((left % 1000))"
}

# 資源の入場に待った秒数を T1 の予算から外す。予算は走行の枠で、待ちは別の上限（予算と同じ秒数）で数える
# 入力 resource_result: supervise が finished 段階に waitSeconds を残した file
# 副作用: 予算の起点を待った秒数だけ進める。読めなければ進めない
settle_wait() {
  local waited_ms
  waited_ms=$(jq -r '((.waitSeconds // 0) * 1000) | floor' "$resource_result" 2>/dev/null) || waited_ms=0
  [[ $waited_ms =~ ^[0-9]+$ ]] || waited_ms=0
  started_ms=$((started_ms + waited_ms))
}

# 目標超過時と走行期限到達時の scope 計測値の報告
# 入力 resource_result: 当該走行の supervisor の計測結果
# 制約: scope 外の処理と空転を区別できないため作業の進捗判定には不使用
report_measurements() {
  local line
  line=$(jq -r '
    def share($stall): if $stall == null then "不明" else "\($stall / .runSeconds * 100 | round)%" end;
    def seconds: if . == null then "不明" else "\(. | round) 秒" end;
    select(.phase == "finished" and .runSeconds != null)
    | if .targetSeconds != null and .runSeconds > .targetSeconds then
        "verify: 走行が時間の目標 \(.targetSeconds) 秒を超えた(走行 \(.runSeconds | seconds)、滞留の割合は CPU \(share(.cpuStallSeconds))、IO \(share(.ioStallSeconds))、メモリ \(share(.memoryStallSeconds)))"
        + (if .deadlineExpired then "。scope の CPU 時間 \(.cpuSeconds | seconds)、目標時点 \(.atTarget.cpuSeconds | seconds)" else "" end)
      elif .deadlineExpired then "verify: 走行 \(.runSeconds | seconds)、scope の CPU 時間 \(.cpuSeconds | seconds)"
      else empty end
  ' "$resource_result" 2>/dev/null) || return 0
  [ -z "$line" ] || printf '%s\n' "$line" >&2
}

bounded_pid=
interrupted=false

# bounded_pid が指す起動済みの job の終了待ち
# 入力 bounded_pid: 当該 job のPID
# 戻り値: job の終了status
# 副作用: 終了後に bounded_pid を空へ戻す
# 制約: signal trapが待ちを中断しても、job が消えるまで待ち直す
await_bounded() {
  local status
  while :; do
    if wait "$bounded_pid"; then status=0; else status=$?; fi
    [ -n "$(jobs -rp)" ] || break
  done
  bounded_pid=
  return "$status"
}

# T1の残り予算で取消を開始するcommandの実行
# 引数 $1: 実行する command 名か実行 path
# 引数 $2以降: 当該commandへ渡す引数
# 入力 remaining: refresh_remainingが確定した取消開始までの正の残秒
# 入力 interrupted: signal trapが記録する当該走行の取消状態
# 入力 slot_fd: 取得済みの実行枠か空
# 戻り値: 開始前取消の130か子孫回収後の監督器の終了監視で得たstatus
# 副作用: signal転送先として起動中だけbounded_pidへ保持する監督器PID
# 完了: 起動した監督器と所有子孫の回収後の返却
# 制約: 取消開始の予算を超えても終了確認を打ち切らない待機。実行枠は監督器が子孫の回収まで握り、親が先に消えても解放しない
run_bounded() {
  local -a hold=()
  [ "$interrupted" = false ] || return 130
  [ -z "$slot_fd" ] || hold=(--hold-fd "$slot_fd")
  @supervise@ --require-drained --parent-death-cancels "$$" --term-grace 30 --resource-run-seconds "$remaining" \
    "${hold[@]}" "${resource_args[@]}" -- @env@ -- "$@" <&0 &
  bounded_pid=$!
  if [ "$interrupted" = true ]; then
    kill -s TERM "$bounded_pid" 2>/dev/null || true
  fi
  await_bounded
}

# 同じ project の T1 を一度に一つへ絞る実行枠の取得
# 入力 top: 検査する repository の根
# 入力 budget_seconds: 走行の予算秒。枠の待ちの上限秒にも使う
# 入力 interrupted: signal trapが記録する当該走行の取消状態
# 戻り値: 取得で0、待ちの上限に達すれば75、予算を使い切っていれば124、取消か枠の失敗でその終了status
# 副作用: 取得後は slot_fd が枠を保持し、以降の supervise が子孫の回収まで同じ fd を握る。待った時間だけ予算の起点を進め、待った ms を slot_wait_ms へ残す
# 制約: 待ちは走行の予算に数えず、別の上限（予算と同じ秒数）で数え、取消で待ちを止める。待った後も呼ばれた command を実行し、先行する走行の結果は借りない
acquire_slot() {
  local slot_file status=0 waited_from_ms
  refresh_remaining || return 124
  run_bounded @gate@ slot --repo "$top" >"$entry_file" || return $?
  IFS= read -r slot_file <"$entry_file" || return 1
  exec {slot_fd}>>"$slot_file"
  @flock@ -n -E 75 -x "$slot_fd" || status=$?
  case $status in
  0) return 0 ;;
  75) ;;
  *) return "$status" ;;
  esac
  printf 'verify: 同じ project の検証が実行枠を使っている。終わるまで待つ\n' >&2
  # 待つ前に予算を使い切っていれば、待った後も走れないため待たない
  refresh_remaining || return 124
  waited_from_ms=$((${EPOCHREALTIME/[.,]/} / 1000))
  @flock@ -w "$budget_seconds" -E 75 -x "$slot_fd" &
  bounded_pid=$!
  if [ "$interrupted" = true ]; then
    kill -s TERM "$bounded_pid" 2>/dev/null || true
  fi
  status=0
  await_bounded || status=$?
  case $status in
  0)
    slot_wait_ms=$((${EPOCHREALTIME/[.,]/} / 1000 - waited_from_ms))
    started_ms=$((started_ms + slot_wait_ms))
    ;;
  75) printf 'verify: 実行枠の空きを待つ上限（予算と同じ %s 秒）に達し、検証を実行しなかった(75)。同じ処理を重複投入せず、空いてから投入し直す\n' "$budget_seconds" >&2 ;;
  esac
  return "$status"
}

# 入口の一覧のいずれかが呼び出しの綴りと一致するか。一覧は entry_file に一行ずつ入る
names_entry() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$1" ] || return 0
  done <"$entry_file"
  return 1
}

# 未追跡の file があるまま宣言した入口を走らせる呼び出しへの注意
# 入力 top: 検査する repository の根
# 副作用: 未追跡で ignore されていない file があれば stderr へ一行。終了statusも証跡も変えない
# 制約: 証跡の鍵は未追跡 file の path の一覧を含み、検査は追跡 file の一覧を列挙するため、走行の後に追跡すると別の木になる。
#   Nix の入口は未追跡 file があると入口の解決が拒否するため、この関数の呼び出しへは来ない
warn_untracked() {
  IFS= read -r -d '' _ < <(git -C "$top" ls-files --others --exclude-standard -z 2>/dev/null) || return 0
  printf 'verify: 未追跡の file がある。走行の後に追跡すると証跡の鍵が変わり、通した木とは別の木になるため、先に git add か git add -N で追跡する\n' >&2
}

if [ "${1-}" = -- ]; then
  shift
fi
test "$#" -gt 0 || usage

if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
  exec "$@"
fi
trap 'interrupted=true; [ -z "$bounded_pid" ] || kill -s TERM "$bounded_pid" 2>/dev/null || true' HUP INT TERM XFSZ
entry_file=$(mktemp)
policy_file=$(mktemp)
resource_result=$(mktemp)
trap 'rm -f -- "$entry_file" "$policy_file" "$resource_result"' EXIT
status=0
if @gate@ snapshot --repo "$top" >"$policy_file" 2>"$entry_file"; then
  if budget=$(@gate@ budget --repo "$top" --policy "$policy_file" 2>&1) && [[ $budget =~ ^[1-9][0-9]*$ ]]; then
    budget_seconds=$budget
    # 目標は上限と同じ snapshot から読む。不正な目標は上限の不正と同じく、補完も無視もせず予算を決められない扱いにする
    if declared_target=$(@gate@ feedback-target --repo "$top" --policy "$policy_file" 2>&1) \
      && [[ $declared_target =~ ^([1-9][0-9]*)?$ ]]; then
      feedback_target=$declared_target
    else
      budget_seconds=
      budget_error=$declared_target
    fi
  else
    budget_error=$budget
  fi
else
  budget_error=$(cat "$entry_file")
fi
if [ -n "$budget_seconds" ]; then
  if ! refresh_remaining; then
    exit 124
  fi
  run_bounded @gate@ entry --repo "$top" --policy "$policy_file" >"$entry_file" || status=$?
else
  # 読めない予算の既定値補完と期限なしの評価は不可のため、評価器を起動せず入口になり得る綴りだけを集める
  @gate@ candidates --repo "$top" >"$entry_file" || status=$?
fi
[ "$interrupted" = false ] || status=130
[ "$status" -eq 0 ] || exit "$status"
if names_entry "$*" \
  && [ "$(realpath -e -- "$PWD")" = "$(realpath -e -- "$top")" ]; then
  if [ -z "$budget_seconds" ]; then
    printf 'verify: T1 の入口 %s の時間予算を決められないため実行しない\n%s\n' "$*" "$budget_error" >&2
    exit 78
  fi
  if ! refresh_remaining; then
    printf 'verify: T1 の時間予算を入口解決で使い切った\n' >&2
    exit 124
  fi
  run_bounded @gate@ push-declaration --repo "$top" --policy "$policy_file" || true
  receipt=${EPOCHREALTIME/[.,]/}.$$
  witness=
  published=
  status=0
  # slot 待ちの間に source が変わり得るため取得前の検証証跡の記録は不可
  acquire_slot || status=$?
  if [ "$status" -eq 0 ]; then
    warn_untracked
    if refresh_remaining; then
      run_bounded @gate@ record --repo "$top" --command "$*" --pending "$receipt" >"$entry_file" || status=$?
    else
      status=124
    fi
  fi
  if [ "$status" -eq 0 ]; then
    IFS= read -r witness <"$entry_file" || true
    if refresh_remaining; then
      resource_args=(--result "$resource_result")
      if [ -n "$resource_policy" ]; then
        # 待ちの上限は走行の予算と同じ秒数。走行の枠は入場から数えるので、待った秒数は予算に入れない
        printf -v wait_until '%d' "$((${EPOCHREALTIME%[.,]*} + budget_seconds))"
        printf -v resource_key 'verify\n%s\n%s' "$top" "$*"
        # 壁時計が戻った場合の負の値は supervise が拒否して走行を止めるため、記録へは 0 を渡す
        [ "$slot_wait_ms" -ge 0 ] || slot_wait_ms=0
        printf -v slot_wait '%d.%03d' "$((slot_wait_ms / 1000))" "$((slot_wait_ms % 1000))"
        resource_args+=(--resource-policy "$resource_policy" --resource-wait-until "$wait_until"
          --resource-key "$resource_key" --resource-slot-wait "$slot_wait")
        [ -z "$feedback_target" ] || resource_args+=(--resource-target-seconds "$feedback_target")
      fi
      run_bounded "$@" || status=$?
      if [ "$status" -ne 0 ]; then printf 'verify: 検証入口の呼び出しが終了 %d で戻った\n' "$status" >&2; fi
      if [ -n "$resource_policy" ]; then
        settle_wait
        report_measurements
      fi
      resource_args=()
      if [ "$status" -eq 0 ] && ! jq -es '
        length == 1 and (.[0] | .phase == "finished" and .spawned == true and .drained == true
          and .cancelled == false and .client_status == 0 and .status == 0)' "$resource_result" >/dev/null; then
        printf 'verify: 監督器は終了 0 で戻ったが、取消のない正常終了を確認できず、成功証跡を確定しない\n' >&2
        status=1
      fi
    else
      status=124
    fi
  fi
  if [ "$status" -eq 0 ] && [ -n "$witness" ]; then
    if refresh_remaining; then
      run_bounded @gate@ publish --repo "$top" --pending "$receipt" --witness "$witness" >"$entry_file" || status=$?
    else
      status=124
    fi
  fi
  if [ "$status" -eq 0 ]; then
    [ -z "$witness" ] || published=$(cat "$entry_file")
    if refresh_remaining; then
      run_bounded rm -f -- "$entry_file" "$policy_file" "$resource_result" || status=$?
      trap - EXIT
    else
      status=124
    fi
    if [ "$status" -eq 0 ] && [ "$interrupted" = false ]; then
      if [ -n "$published" ]; then
        printf 'completed=true\n' >>"$published" || status=$?
      fi
      refresh_remaining || status=124
    fi
  fi
  if [ "$status" -eq 0 ] && [ "$interrupted" = true ]; then
    status=130
  fi
  if [ "$status" -ne 0 ]; then
    (trap '' HUP INT TERM; exec @gate@ discard --pending "$receipt") || true
    exit "$status"
  fi
  exit 0
fi
rm -f -- "$entry_file" "$policy_file" "$resource_result"
trap - EXIT
exec "$@"
