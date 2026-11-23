set -euo pipefail

export XDG_STATE_HOME="$PWD/state"
mkdir project
cd project
git init -q
git -c user.name=fixture -c user.email=fixture@localhost commit --allow-empty -qm initial
"$BRIEF" list > before
test ! -s before
test ! -e "$XDG_STATE_HOME"
case_id=$("$BRIEF" new 'request#17' '入力を読み込める' '旧データを移行できる' '担当者が再開できる')
"$BRIEF" accept "$case_id" 1 'example.csv: run 1' >/dev/null
"$BRIEF" note "$case_id" 2 '旧版の保存例を待っている' >/dev/null
"$BRIEF" add "$case_id" 'comment#18' '配布物でも起動できる' >/dev/null
"$BRIEF" withdraw "$case_id" 4 'user decision#19' >/dev/null
second=$("$BRIEF" new 'request#20' '別件の入力変換')
test "$case_id" != "$second"
git worktree add -q --detach ../child
cd ../child
"$BRIEF" show "$case_id" > handoff
grep -F 'request#17' handoff
grep -F '1 [done] 入力を読み込める' handoff
grep -F 'example.csv: run 1' handoff
grep -F '2 [open] 旧データを移行できる' handoff
grep -F '旧版の保存例を待っている' handoff
grep -F '3 [open] 担当者が再開できる' handoff
grep -F '4 [withdrawn] 配布物でも起動できる' handoff
grep -F 'user decision#19' handoff
grep -F 'comment#18' handoff
if grep -q '別件の入力変換' handoff; then exit 1; fi
if "$BRIEF" accept "$case_id" 2 '  '; then exit 1; fi
if "$BRIEF" accept "$case_id" 99 'example'; then exit 1; fi
if "$BRIEF" forget "$case_id"; then exit 1; fi
"$BRIEF" show "$case_id" > after
cmp handoff after
"$BRIEF" list | grep -F "$case_id"
"$BRIEF" reopen "$case_id" 1 '保存形式の変更で旧証拠は失効' | grep -F '1 [open] 入力を読み込める'
"$BRIEF" accept "$second" 1 'report#21' >/dev/null
"$BRIEF" forget "$second"
if "$BRIEF" show "$second"; then exit 1; fi
mkdir ../unrelated
cd ../unrelated
git init -q
"$BRIEF" list > unrelated
test ! -s unrelated
