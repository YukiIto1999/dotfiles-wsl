#!/usr/bin/env bash
set -euo pipefail

# 配備する hook 一式を global の hooksPath に置き、実際の git から起こす。
export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$PWD/home/.gitconfig
mkdir -p "$HOME"
git config --global core.hooksPath "$HOOKS"
git config --global user.name fixture
git config --global user.email fixture@example.invalid
git config --global init.defaultBranch main

remote=$PWD/remote.git
repo=$PWD/repo
marker=$PWD/marker
git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" remote add origin "$remote"
git -C "$repo" config dotfiles.hooks.trusted true
mkdir "$repo/.githooks"

# repository の hook。名前、argv、stdin を marker へ控え、REPO_HOOK_STATUS で終わる。
write_repo_hook() {
  local name=$1
  cat >"$repo/.githooks/$name" <<SCRIPT
#!$BASH
{
  printf 'hook=%s\n' '$name'
  printf 'arg=%s\n' "\$@"
  printf 'stdin\n'
  cat
} >>"$marker"
exit "\${REPO_HOOK_STATUS:-0}"
SCRIPT
  chmod +x "$repo/.githooks/$name"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

commit() {
  printf '%s\n' "$1" >>"$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" commit -q -m 'test: 検査の追加' </dev/null
}

# 信頼した repository では、dotfiles の検査の後に repository の hook が同じ argv で走る。
write_repo_hook pre-commit
write_repo_hook commit-msg
commit first
grep -qx 'hook=pre-commit' "$marker" || fail 'repository pre-commit did not run'
grep -qx 'hook=commit-msg' "$marker" || fail 'repository commit-msg did not run'
grep -qx 'arg=.git/COMMIT_EDITMSG' "$marker" || fail 'repository commit-msg lost its argv'

# dotfiles の検査が拒んだ commit では、repository の hook を走らせない。
rm -f "$marker"
if git -C "$repo" commit -q --allow-empty -m 'fix: update README' 2>/dev/null; then
  fail 'commit-msg accepted an invalid subject'
fi
grep -qx 'hook=commit-msg' "$marker" && fail 'repository commit-msg ran after the global check failed'
rm -f "$marker"
printf 'ghp_%s\n' "$(printf 'a%.0s' {1..36})" >"$repo/leak.txt"
git -C "$repo" add leak.txt
if git -C "$repo" commit -q -m 'test: 検査の追加' 2>/dev/null; then
  fail 'pre-commit accepted a staged token'
fi
test ! -e "$marker" || fail 'repository pre-commit ran after the global check failed'
git -C "$repo" rm -q --cached leak.txt
rm "$repo/leak.txt"

# repository の hook の失敗は、その終了 status のまま git へ返る。
rm -f "$marker"
set +e
(cd "$repo" && REPO_HOOK_STATUS=3 "$HOOKS/pre-commit")
status=$?
set -e
test "$status" -eq 3 || fail "repository hook status was not propagated: $status"
printf 'second\n' >>"$repo/tracked"
git -C "$repo" add tracked
if REPO_HOOK_STATUS=3 git -C "$repo" commit -q -m 'test: 検査の追加' 2>/dev/null; then
  fail 'git committed although the repository pre-commit failed'
fi
git -C "$repo" commit -q -m 'test: 検査の追加'

# pre-push の ref の一覧は、repository の hook へも同じ stdin で届く。
rm -f "$marker"
write_repo_hook pre-push
head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin main 2>/dev/null
expected_stdin="refs/heads/main $head refs/heads/main $(printf '0%.0s' $(seq 1 ${#head}))"
grep -qx 'hook=pre-push' "$marker" || fail 'repository pre-push did not run'
grep -qx "arg=$remote" "$marker" || fail 'repository pre-push lost the remote URL'
grep -qxF "$expected_stdin" "$marker" || fail 'repository pre-push did not receive the ref list'

# dotfiles が検査を持たない hook でも、repository の hook は走る。
rm -f "$marker"
write_repo_hook post-checkout
git -C "$repo" checkout -q -b topic
grep -qx 'hook=post-checkout' "$marker" || fail 'repository post-checkout did not run'

# 実行権の無い hook は走らせず、何も言わない。
rm -f "$marker"
chmod -x "$repo/.githooks/post-checkout"
git -C "$repo" checkout -q main 2>stderr
test ! -e "$marker" || fail 'a non-executable repository hook ran'
test ! -s stderr || fail 'a non-executable repository hook produced output'
chmod +x "$repo/.githooks/post-checkout"

# 信頼していない repository の hook は走らせず、そのことを一行だけ伝える。
rm -f "$marker"
git -C "$repo" config --unset dotfiles.hooks.trusted
git -C "$repo" checkout -q topic 2>stderr
test ! -e "$marker" || fail 'an untrusted repository hook ran'
test "$(wc -l <stderr)" -eq 1 || fail 'the untrusted notice was not exactly one line'
grep -qF "$repo/.githooks/post-checkout" stderr || fail 'the untrusted notice did not name the hook'
