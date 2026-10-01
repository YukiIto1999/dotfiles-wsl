#!/usr/bin/env bash
set -euo pipefail

# pre-push が repository の T2 の入口 verify-push を引いて実行し、結果で push を通すか拒むかを見る。
export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$PWD/home/.gitconfig
mkdir -p "$HOME"
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch main
export MARKER=$PWD/marker LATE=$PWD/late
bypass_log=$HOME/.local/state/dotfiles-wsl/git/verify-push-bypass.log

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

new_repo() {
  local repo=$PWD/$1
  git init -q --bare "$repo.git"
  git init -q "$repo"
  git -C "$repo" remote add origin "$repo.git"
  printf 'held\n' >"$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" commit -q -m 'test: 検査の追加'
  printf '%s' "$repo"
}

push() {
  local hooks=$1 repo=$2
  git -C "$repo" -c core.hooksPath="$hooks" push -q origin main 2>stderr
}

remote_head() {
  git -C "$1.git" rev-parse --verify -q refs/heads/main || true
}

# 入口を宣言しない repository では何も実行せず、何も言わない。
plain=$(new_repo plain)
push "$HOOKS" "$plain" || fail 'push without a verify-push entry was refused'
test ! -s stderr || fail 'pre-push spoke for a repository without a verify-push entry'
test "$(remote_head "$plain")" = "$(git -C "$plain" rev-parse HEAD)"

# 宣言した入口は repository の根で走り、経過時間を伝える。ref の一覧は repository の hook へ残る。
declared=$(new_repo declared)
# 予算の超過では、recipe の shell が止まっても生き残る子孫まで止まることを見る。
printf 'STATUS ?= 0\nverify-push:\n\tpwd >"$(MARKER)"\n\tif [ -n "$(SLOW)" ]; then (sleep 3; touch "$(LATE)") & wait; fi\n\texit $(STATUS)\n' \
  >"$declared/Makefile"
mkdir "$declared/.githooks"
printf '#!%s\ncat >"%s"\n' "$BASH" "$PWD/refs" >"$declared/.githooks/pre-push"
chmod +x "$declared/.githooks/pre-push"
git -C "$declared" config dotfiles.hooks.trusted true
git -C "$declared" add Makefile .githooks
git -C "$declared" commit -q -m 'test: 検査の追加'
push "$HOOKS" "$declared" || fail 'push with a passing verify-push was refused'
test "$(cat "$MARKER")" = "$declared" || fail 'verify-push did not run at the repository root'
grep -qF 'verify-push: make verify-push を実行する' stderr || fail 'pre-push did not name the entry'
grep -qF 'verify-push: 通った(経過 ' stderr || fail 'pre-push did not report the elapsed time'
grep -qF "refs/heads/main $(git -C "$declared" rev-parse HEAD) refs/heads/main " refs \
  || fail 'verify-push consumed the ref list meant for the repository hook'

# 失敗した入口は push を拒み、remote を変えない。
printf 'changed\n' >>"$declared/tracked"
git -C "$declared" commit -q -am 'test: 検査の追加'
before=$(remote_head "$declared")
if STATUS=5 push "$HOOKS" "$declared"; then
  fail 'push with a failing verify-push was accepted'
fi
grep -qF 'verify-push: 失敗した(終了 ' stderr || fail 'pre-push did not report the failure'
test "$(remote_head "$declared")" = "$before" || fail 'a refused push still updated the remote'

# 利用者の理由付きの省略は、入口を走らせずに push を通し、理由を記録に残す。
rm -f "$MARKER"
STATUS=5 DOTFILES_VERIFY_PUSH_BYPASS='fixture の理由' push "$HOOKS" "$declared" \
  || fail 'the bypass did not let the push through'
test ! -e "$MARKER" || fail 'the bypass still ran verify-push'
grep -qF "repo=$declared" "$bypass_log" || fail 'the bypass log did not name the repository'
grep -qF 'reason=fixture の理由' "$bypass_log" || fail 'the bypass log lost the reason'
grep -qF 'fixture の理由' stderr || fail 'the bypass was not reported'

# 予算を超えた入口は子孫ごと止め、push を拒む。
printf 'slow\n' >>"$declared/tracked"
git -C "$declared" commit -q -am 'test: 検査の追加'
if SLOW=1 push "$SHORT_BUDGET_HOOKS" "$declared"; then
  fail 'push with an over-budget verify-push was accepted'
fi
grep -qF 'verify-push: 予算 0分01秒 を超えたため止めた' stderr || fail 'pre-push did not report the budget overrun'
sleep 4
test ! -e "$LATE" || fail 'the over-budget verify-push kept running after the push was refused'

# 入口は git が hook へ渡す GIT_DIR などを受け継がない。受け継ぐと、入口の中で一時 repository に
# 向けた git の操作が、push 元の repository の設定と index を書き換える。
linked_main=$(new_repo linked-main)
printf 'verify-push:\n\tgit init -q "$(SCRATCH)"\n\tgit -C "$(SCRATCH)" config core.bare true\n' \
  >"$linked_main/Makefile"
git -C "$linked_main" add Makefile
git -C "$linked_main" commit -q -m 'test: 検査の追加'
git -C "$linked_main" worktree add -q -b linked "$PWD/linked"
printf 'linked\n' >>"$PWD/linked/tracked"
git -C "$PWD/linked" commit -q -am 'test: 検査の追加'
SCRATCH=$PWD/scratch git -C "$PWD/linked" -c core.hooksPath="$HOOKS" push -q origin linked 2>stderr \
  || fail 'push from a linked worktree was refused'
test "$(git -C "$linked_main" config --type=bool --get core.bare)" = false \
  || fail 'verify-push inherited the git environment and rewrote the pushing repository'
test "$(git -C "$PWD/scratch" config --type=bool --get core.bare)" = true \
  || fail 'verify-push did not reach its own scratch repository'
