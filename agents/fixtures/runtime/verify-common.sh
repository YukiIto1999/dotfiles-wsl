#!/usr/bin/env bash
set -euo pipefail
fixture=$PWD/verify-fixture
home=$fixture/home

stall_litter() {
  find "$home/.cache/dotfiles-wsl/verification" -mindepth 1 -name '.*' -print | sort
}

stall_receipt_count() {
  find "$home/.cache/dotfiles-wsl/verification" -type f -name '*.verified' -print | wc -l
}

declare_budget() {
  printf '{"version":1,"verify":{"seconds":%s}}\n' "$2" >"$1/tiergate.json"
}

# 完走を期待する走行の予算。wrapper の起動と後始末が混んだ機械で 10 秒かかっても通る
completion_budget=60
# 期限に達することを確かめる走行の予算（秒）。期限の前に起きるべきこと（evaluator の起動、入場の待ち、公開）へ
# 届く前に期限が来た走行は不具合ではなく負荷の表れなので、その走行だけを倍の予算で最初からやり直す。
# 静かな機械は最初の値で届く。次の場面の最初の値は、前の場面がやり直さずに済んだなら半分へ戻し、やり直したなら伸ばした値のままにする
reach_floor=4
reach_budget=$reach_floor
reach_limit=64
reach_retried=0
# 印の file が現れるまで 0.05 秒間隔で待つ回数（60 秒）
# shellcheck disable=SC2034
mark_polls=1200

# 期限に達することを確かめる場面の最初の予算を決める
# 入力 reach_retried: 前の場面が予算を伸ばしてやり直したか
reach_begin() {
  if [ "$reach_retried" -eq 0 ] && [ "$reach_budget" -gt "$reach_floor" ]; then
    reach_budget=$((reach_budget / 2))
  fi
  reach_retried=0
}

# 期限が起きるべきことへ届く前に来た走行のやり直しに向けて reach_budget を倍にする
# 引数 $1: 届かなかった場面の名前
# 制約: reach_limit を超えても届かないなら、負荷ではなく不具合として止める
reach_widen() {
  reach_retried=1
  reach_budget=$((reach_budget * 2))
  if [ "$reach_budget" -gt "$reach_limit" ]; then
    echo "$1 did not reach its stage inside a $reach_limit second budget" >&2
    exit 1
  fi
}

t1_repository() {
  git init -q "$1"
  printf 'scripts.verify.exec = "true";\n' >"$1/devenv.nix"
  declare_budget "$1" "$2"
  git -C "$1" add devenv.nix tiergate.json
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
}

# 期限に達した走行の後に、完走を期待する再走のため予算の宣言を書き換えて commit する
# 引数 $1: repository
# 制約: 木が変わるので、同じ木の上で走行を重ねる場面には使わない。止めた走行が何も残さないことと、
# 再走が証跡を一つ公開することは、木の同一性に依らない
widen_budget() {
  declare_budget "$1" "$completion_budget"
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit -qam 'test: 再走の予算の拡大'
}

expect_closed_gate() {
  if "$GATE" check --repo "$1" >/dev/null 2>&1; then
    echo "gate accepted a T1 that did not finish inside its budget: $2" >&2
    exit 1
  fi
}

expect_open_gate() {
  if ! "$GATE" check --repo "$1" >/dev/null 2>&1; then
    echo "gate closed on a tree that a completed T1 verified: $2" >&2
    exit 1
  fi
}

# 別 session の孫が検証の返却時点でまだ動くかを判定する観測
# 引数 $1: 当該 fixture が起動した Linux process 番号
# 戻り値: 読取可能な非 zombie process なら0でそれ以外は1
# 返却後の待ち直しは別 session の孫の回収を返却時点で検証できないため不可
process_alive() {
  local proc_stat
  proc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  [[ ${proc_stat##*) } != [ZX]* ]]
}

mkdir -p "$home"
cat > "$fixture/check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$COUNT" || count=$(cat "$COUNT")
printf '%s\n' "$((count + 1))" > "$COUNT"
exit "${CHECK_STATUS:-0}"
SCRIPT
chmod +x "$fixture/check"
sed -i "1c#!$BASH" "$fixture/check"

export HOME=$home
mkdir -p "$HOME/.cache/dotfiles-wsl/verification"
