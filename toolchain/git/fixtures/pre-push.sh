#!/usr/bin/env bash
set -euo pipefail

export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$PWD/home/.gitconfig
mkdir -p "$HOME"
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch main
export MARKER=$PWD/marker LATE=$PWD/late
bypass_log=$HOME/.local/state/dotfiles-wsl/git/verify-push-bypass.log
controls=0

fail() {
  printf '%s\n' "$*" >&2
  if [ -s stderr ]; then
    printf -- '--- stderr of the last push\n' >&2
    cat stderr >&2
  fi
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
  shift 2
  [ "$#" -gt 0 ] || set -- main
  git -C "$repo" -c core.hooksPath="$hooks" push -q origin "$@" 2>stderr
}

remote_ref() {
  git -C "$1.git" rev-parse --verify -q "$2" || true
}

expect_refused() {
  local description=$1 hooks=$2 repo=$3 ref=$4 before
  shift 4
  before=$(remote_ref "$repo" "$ref")
  if push "$hooks" "$repo" "$@"; then
    fail "$description was accepted"
  fi
  test "$(remote_ref "$repo" "$ref")" = "$before" || fail "$description still updated the remote"
}

# 拒否だけの判定の不採用: 復元漏れによる拒否を対象不具合と誤認する偽陽性の回避
expect_clean_accepted() {
  controls=$((controls + 1))
  push "$HOOKS" "$1" "HEAD:refs/heads/restored-$controls" || fail 'the restored clean source was refused'
}

# 二つのindex flagを一度で解除する方法の不採用: Git 2.54でのskip-worktreeの残存
restore_source() {
  git -C "$1" update-index --no-assume-unchanged tracked
  git -C "$1" update-index --no-skip-worktree tracked
  git -C "$1" reset -q --hard
  git -C "$1" clean -qfd
  expect_clean_accepted "$1"
}

plain=$(new_repo plain)
printf 'dirty\n' >"$plain/untracked"
push "$HOOKS" "$plain" || fail 'push without a verify-push entry was refused'
test ! -s stderr || fail 'pre-push spoke for a repository without a verify-push entry'
test "$(remote_ref "$plain" refs/heads/main)" = "$(git -C "$plain" rev-parse HEAD)" \
  || fail 'the push without a verify-push entry did not reach the remote'

declared=$(new_repo declared)
# 予算の超過では、recipe の shell が止まっても生き残る子孫まで止まることを見る。
printf 'STATUS ?= 0\nCHANGE ?= true\nverify-push:\n\tpwd >"$(MARKER)"\n\t$(CHANGE)\n\tif [ -n "$(SLOW)" ]; then (sleep 3; touch "$(LATE)") & wait; fi\n\texit $(STATUS)\n' \
  >"$declared/Makefile"
mkdir "$declared/.githooks"
printf '#!%s\ncat >"%s"\n' "$BASH" "$PWD/refs" >"$declared/.githooks/pre-push"
chmod +x "$declared/.githooks/pre-push"
git -C "$declared" config dotfiles.hooks.trusted true
git -C "$declared" add Makefile .githooks
git -C "$declared" commit -q -m 'test: 検査の追加'

push "$HOOKS" "$declared" || fail 'push of the clean HEAD with a passing verify-push was refused'
head=$(git -C "$declared" rev-parse HEAD)
test "$(cat "$MARKER")" = "$declared" || fail 'verify-push did not run at the repository root'
test "$(remote_ref "$declared" refs/heads/main)" = "$head" || fail 'the accepted push did not reach the remote'
grep -qF "refs/heads/main $head refs/heads/main " refs \
  || fail 'verify-push consumed the ref list meant for the repository hook'

printf 'changed\n' >>"$declared/tracked"
git -C "$declared" commit -q -am 'test: 検査の追加'
rm -f "$MARKER"
STATUS=5 expect_refused 'push with a failing verify-push' "$HOOKS" "$declared" refs/heads/main
test -e "$MARKER" || fail 'the failing verify-push did not run'

for kind in worktree index untracked; do
  case $kind in
  worktree) printf 'dirty\n' >>"$declared/tracked" ;;
  index)
    printf 'dirty\n' >>"$declared/tracked"
    git -C "$declared" add tracked
    ;;
  untracked) printf 'dirty\n' >"$declared/untracked" ;;
  esac
  rm -f "$MARKER"
  expect_refused "push with a $kind difference" "$HOOKS" "$declared" refs/heads/main
  test ! -e "$MARKER" || fail "verify-push ran on a $kind difference"
  restore_source "$declared"
done

git -C "$declared" -c protocol.file.allow=always submodule add -q "$(new_repo sub)" vendor
git -C "$declared" commit -q -m 'test: 検査の追加'
for flag in assume-unchanged skip-worktree; do
  git -C "$declared" update-index --"$flag" tracked
  printf 'hidden\n' >>"$declared/tracked"
  test -z "$(git -C "$declared" status --porcelain)" || fail "status showed the difference hidden by $flag"
  rm -f "$MARKER"
  expect_refused "push with a $flag path" "$HOOKS" "$declared" refs/heads/main
  test ! -e "$MARKER" || fail "verify-push ran on a $flag path"
  restore_source "$declared"
done
git -C "$declared/vendor" update-index --assume-unchanged tracked
printf 'hidden\n' >>"$declared/vendor/tracked"
test -z "$(git -C "$declared" status --porcelain --ignore-submodules=none)" \
  || fail 'status showed the difference hidden by assume-unchanged in a submodule'
rm -f "$MARKER"
expect_refused 'push with an assume-unchanged path in a submodule' "$HOOKS" "$declared" refs/heads/main
test ! -e "$MARKER" || fail 'verify-push ran on an assume-unchanged path in a submodule'
git -C "$declared/vendor" update-index --no-assume-unchanged tracked
git -C "$declared/vendor" checkout -q -- tracked
expect_clean_accepted "$declared"

git -C "$declared" branch side HEAD~1
git -C "$declared" tag -a -m old old HEAD~1
git -C "$declared" tag -a -m current current
rm -f "$MARKER"
expect_refused 'push of a branch that is not HEAD' "$HOOKS" "$declared" refs/heads/side side
expect_refused 'push of HEAD together with a branch that is not HEAD' "$HOOKS" "$declared" refs/heads/main main side
expect_refused 'push of a tag that is not HEAD' "$HOOKS" "$declared" refs/tags/old old
test ! -e "$MARKER" || fail 'verify-push ran for a ref that is not HEAD'
push "$HOOKS" "$declared" current || fail 'push of an annotated tag at HEAD was refused'
test -e "$MARKER" || fail 'verify-push did not run for the tag at HEAD'
test "$(remote_ref "$declared" refs/tags/current)" = "$(git -C "$declared" rev-parse current)" \
  || fail 'the annotated tag did not reach the remote'

for change in 'printf moved >>tracked' 'printf moved >moved' 'git update-index --assume-unchanged tracked' 'git commit -q --allow-empty -m moved'; do
  rm -f "$MARKER"
  CHANGE=$change expect_refused "push whose source moved while verify-push ran ($change)" \
    "$HOOKS" "$declared" refs/heads/main
  test -e "$MARKER" || fail "verify-push did not run for: $change"
  restore_source "$declared"
done

git -C "$declared" push -q origin HEAD:refs/heads/gone
printf 'dirty\n' >"$declared/untracked"
rm -f "$MARKER"
STATUS=5 push "$HOOKS" "$declared" --delete gone || fail 'push that only deletes a branch was refused'
test ! -e "$MARKER" || fail 'verify-push ran for a push that only deletes'
test -z "$(remote_ref "$declared" refs/heads/gone)" || fail 'the deletion did not reach the remote'
restore_source "$declared"

git -C "$declared" push -q origin HEAD:refs/heads/gone
rm -f "$MARKER"
push "$HOOKS" "$declared" main :gone || fail 'push of HEAD together with a deletion was refused'
test -e "$MARKER" || fail 'verify-push did not run for the pushed HEAD'
test "$(remote_ref "$declared" refs/heads/main)" = "$(git -C "$declared" rev-parse HEAD)" \
  || fail 'the push together with a deletion did not update the remote'
test -z "$(remote_ref "$declared" refs/heads/gone)" || fail 'the deletion together with HEAD did not reach the remote'

printf 'dirty\n' >"$declared/untracked"
rm -f "$MARKER"
STATUS=5 DOTFILES_VERIFY_PUSH_BYPASS='fixture の理由' push "$HOOKS" "$declared" side \
  || fail 'the bypass did not let the push through'
test ! -e "$MARKER" || fail 'the bypass still ran verify-push'
test -n "$(remote_ref "$declared" refs/heads/side)" || fail 'the bypassed push did not reach the remote'
grep -qF "repo=$declared" "$bypass_log" || fail 'the bypass log did not name the repository'
grep -qF 'reason=fixture の理由' "$bypass_log" || fail 'the bypass log lost the reason'
restore_source "$declared"

printf 'slow\n' >>"$declared/tracked"
git -C "$declared" commit -q -am 'test: 検査の追加'
rm -f "$MARKER"
SLOW=1 expect_refused 'push with an over-budget verify-push' \
  "$SHORT_BUDGET_HOOKS" "$declared" refs/heads/main
test -e "$MARKER" || fail 'the over-budget verify-push did not run'
sleep 4
test ! -e "$LATE" || fail 'the over-budget verify-push kept running after the push was refused'

expect_clean_accepted "$declared"
rm -f "$MARKER"
expect_refused 'push whose verify-push entry could not be resolved' \
  "$FAILING_ENTRY_HOOKS" "$declared" refs/heads/main
test ! -e "$MARKER" || fail 'verify-push ran although its entry could not be resolved'

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
test "$(remote_ref "$linked_main" refs/heads/linked)" = "$(git -C "$PWD/linked" rev-parse HEAD)" \
  || fail 'the push from a linked worktree did not reach the remote'
