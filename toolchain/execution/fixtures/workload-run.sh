#!/usr/bin/env bash
# dotfiles-workload-run が supervisor へ渡す引数から、実測した需要の記録の鍵と、明示した需要の扱いを読む。
# supervisor は引数を控えるだけの代替で、鍵から需要を決める側は supervise の検査が持つ。
set -euo pipefail

fixture=$PWD/workload-run-fixture
repo=$fixture/repo
other=$fixture/other
plain=$fixture/plain
mkdir -p "$repo/sub dir" "$other" "$plain" "$fixture/home"
export HOME=$fixture/home
# fixture の外の repository へ根の探索が昇らないための天井
export GIT_CEILING_DIRECTORIES=$fixture
git init -q "$repo"
git init -q "$other"

capture=$fixture/argv
export ARG_CAPTURE=$capture
argv=()

# 引数 $1: 実行する wrapper、$2: 作業 directory、$3以降: wrapper の引数
# 副作用: 代替の supervisor が受けた引数を argv へ置く
run_with() {
  local wrapper=$1 directory=$2
  shift 2
  rm -f "$capture"
  (cd "$directory" && "$wrapper" "$@")
  mapfile -d '' -t argv <"$capture"
}

run() {
  run_with "$WORKLOAD_RUN" "$@"
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

repo_top=$(realpath "$repo")
other_top=$(realpath "$other")
plain_top=$(realpath "$plain")

# 鍵は deep、repository の根、command の行を改行でつないだ文字列で、一つの走行に一つだけ渡る
run "$repo" --seconds 30 -- echo hello 'two words'
test "$(count_of --resource-key)" -eq 1
test "$(value_after --resource-key)" = $'deep\n'"$repo_top"$'\necho hello two words'
test "$(value_after --resource-policy)" = "$POLICY"
test "$(value_after --resource-run-seconds)" = 30.0
test "$(count_of --resource-memory)" -eq 0
# command は supervisor の -- の後に、解決した実行 file、残りの引数の順で渡る。解決前の綴りは鍵にだけ使う
test "${argv[-4]}" = --
test "${argv[-3]}" = "$(type -P echo)"
test "${argv[-2]}" = hello
test "${argv[-1]}" = 'two words'

# 同じ repository の subdirectory からも同じ根の鍵になる
repo_key=$(value_after --resource-key)
run "$repo/sub dir" --seconds 30 -- echo hello 'two words'
test "$(value_after --resource-key)" = "$repo_key"

# 別の repository と別の command は別の鍵になる
run "$other" --seconds 30 -- echo hello 'two words'
test "$(value_after --resource-key)" = $'deep\n'"$other_top"$'\necho hello two words'
run "$repo" --seconds 30 -- echo hello
test "$(value_after --resource-key)" = $'deep\n'"$repo_top"$'\necho hello'

# repository の外では作業 directory が根の代わりになる
run "$plain" --seconds 30 -- echo hello
test "$(value_after --resource-key)" = $'deep\n'"$plain_top"$'\necho hello'

# git を実行できなくても走行は止まらず、作業 directory が根の代わりになる
run_with "$GITLESS_WORKLOAD_RUN" "$repo/sub dir" --seconds 30 -- echo hello
test "$(value_after --resource-key)" = $'deep\n'"$(realpath "$repo/sub dir")"$'\necho hello'

# 明示した需要は鍵があっても supervisor へ渡り、鍵も渡る。需要の優先は supervisor が決める
run "$repo" --seconds 30 --memory-gib 2 -- echo hello
test "$(value_after --resource-memory)" = 2147483648
test "$(value_after --resource-key)" = $'deep\n'"$repo_top"$'\necho hello'
run "$repo" --seconds 30 --memory-gib 0.5 -- echo hello
test "$(value_after --resource-memory)" = 536870912

# 使い方の誤りは何も起動しない
rm -f "$capture"
status=0
(cd "$repo" && "$WORKLOAD_RUN" --seconds 30 2>/dev/null) || status=$?
test "$status" -eq 2
test ! -e "$capture"
