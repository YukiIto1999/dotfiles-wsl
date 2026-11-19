#!/usr/bin/env bash
# dotfiles-capped-run が supervisor へ渡す引数から、CPU の割合、待機と走行の秒数、実測した需要の記録の鍵、使い方の誤りの扱いを読む。
# supervisor は引数を控えるだけの代替で、割合から入場を決める側は supervise の検査が持つ。
set -euo pipefail

fixture=$PWD/capped-run-fixture
repo=$fixture/repo
mkdir -p "$repo" "$fixture/home"
export HOME=$fixture/home
# fixture の外の repository へ根の探索が昇らないための天井
export GIT_CEILING_DIRECTORIES=$fixture
git init -q "$repo"

capture=$fixture/argv
export ARG_CAPTURE=$capture
argv=()

# 引数 $1: 作業 directory、$2以降: 入口の引数
# 副作用: 代替の supervisor が受けた引数を argv へ置く
run() {
  local directory=$1
  shift
  rm -f "$capture"
  (cd "$directory" && "$CAPPED_RUN" "$@")
  mapfile -d '' -t argv <"$capture"
}

# 引数 $1: option。argv で option の次にある値を返す
value_after() {
  local index
  for index in "${!argv[@]}"; do
    if [ "${argv[index]}" = "$1" ]; then
      printf '%s' "${argv[index + 1]}"
      return 0
    fi
  done
  return 1
}

# 引数 $1: option。argv にある option の数を返す
count_of() {
  local count=0 argument
  for argument in "${argv[@]}"; do
    if [ "$argument" = "$1" ]; then count=$((count + 1)); fi
  done
  printf '%s' "$count"
}

# 引数: 入口の引数。何も起動せず、使い方の誤りの status 2 で終わる
rejects() {
  local status=0
  rm -f "$capture"
  (cd "$repo" && "$CAPPED_RUN" "$@" 2>/dev/null) || status=$?
  test "$status" -eq 2
  test ! -e "$capture"
}

repo_top=$(realpath "$repo")

# 割合は一つだけ渡り、待機の期限と走行の秒数は別々の値で渡る。待機の期限は入口が始まった時刻から待機の秒数後で、走行の秒数には依らない
before=$(date +%s.%N)
run "$repo" --cpu-percent 250 --wait-seconds 90 --run-seconds 600 -- echo hello 'two words'
after=$(date +%s.%N)
test "$(count_of --resource-cpu)" -eq 1
test "$(value_after --resource-cpu)" = 250
test "$(value_after --resource-run-seconds)" = 600.0
awk -v until="$(value_after --resource-wait-until)" -v before="$before" -v after="$after" \
  'BEGIN { exit !(until >= before + 90 - 0.001 && until <= after + 90 + 0.001) }'
test "$(value_after --resource-policy)" = "$POLICY"
test "$(count_of --require-drained)" -eq 1
test "$(count_of --interrupt-cancels)" -eq 1
test "$(count_of --resource-memory)" -eq 0
# 鍵は capped、repository の根、command の行を改行でつないだ文字列で、deep の鍵とは入口の名前で分かれる
test "$(count_of --resource-key)" -eq 1
test "$(value_after --resource-key)" = $'capped\n'"$repo_top"$'\necho hello two words'
# command は supervisor の -- の後に、解決した実行 file、残りの引数の順で渡る
test "${argv[-4]}" = --
test "${argv[-3]}" = "$(type -P echo)"
test "${argv[-2]}" = hello
test "${argv[-1]}" = 'two words'

# 待機の秒数が走行の秒数より長くても、二つは混ざらない
before=$(date +%s.%N)
run "$repo" --cpu-percent 100 --wait-seconds 900 --run-seconds 30 -- echo hello
after=$(date +%s.%N)
test "$(value_after --resource-run-seconds)" = 30.0
awk -v until="$(value_after --resource-wait-until)" -v before="$before" -v after="$after" \
  'BEGIN { exit !(until >= before + 900 - 0.001 && until <= after + 900 + 0.001) }'

# 明示した需要は割合と並んで supervisor へ渡る
run "$repo" --cpu-percent 100 --wait-seconds 60 --run-seconds 60 --memory-gib 2 -- echo hello
test "$(value_after --resource-memory)" = 2147483648
test "$(value_after --resource-cpu)" = 100

# 割合も二つの秒数も必須で、足りなければ何も起動しない
rejects --wait-seconds 60 --run-seconds 60 -- echo hello
rejects --cpu-percent 100 --run-seconds 60 -- echo hello
rejects --cpu-percent 100 --wait-seconds 60 -- echo hello
# deep の入口の秒数の option は持たない
rejects --seconds 60 -- echo hello

# 割合は正の整数、秒数は有限で正の数に限る
for cpu in 0 -5 2.5 half; do
  rejects --cpu-percent "$cpu" --wait-seconds 60 --run-seconds 60 -- echo hello
done
for seconds in 0 -1 nan inf; do
  rejects --cpu-percent 100 --wait-seconds "$seconds" --run-seconds 60 -- echo hello
  rejects --cpu-percent 100 --wait-seconds 60 --run-seconds "$seconds" -- echo hello
done
rejects --cpu-percent 100 --wait-seconds 60 --run-seconds 60 --memory-gib 0 -- echo hello
rejects --cpu-percent 100 --wait-seconds 60 --run-seconds 60

# 存在しない command は 127 で、何も起動しない
rm -f "$capture"
status=0
(cd "$repo" && "$CAPPED_RUN" --cpu-percent 100 --wait-seconds 60 --run-seconds 60 -- no-such-command-for-capped-run 2>/dev/null) || status=$?
test "$status" -eq 127
test ! -e "$capture"
