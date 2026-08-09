#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/git-shim-fixture
mkdir -p "$fixture/repo/subdirectory"
git -C "$fixture/repo" init -q

capture() {
  local name=$1
  shift
  ARG_CAPTURE="$fixture/$name.argv" \
    PWD_CAPTURE="$fixture/$name.pwd" \
    CONFIG_CAPTURE="$fixture/$name.config" \
    "$@"
}

assert_argv() {
  local file=$1
  shift
  local -a actual
  mapfile -d '' -t actual < "$file"
  test "${#actual[@]}" -eq "$#"
  local index=0
  for expected in "$@"; do
    test "${actual[$index]}" = "$expected"
    index=$((index + 1))
  done
}

test "$(command -v git)" != "$GIT_SHIM_DIR/bin/git"
PATH="$GIT_SHIM_DIR/bin:$PATH"
export PATH
test "$(command -v git)" = "$GIT_SHIM_DIR/bin/git"

capture regular git status --short
assert_argv "$fixture/regular.argv" status --short

capture worktree-list git --no-pager worktree list
assert_argv "$fixture/worktree-list.argv" --no-pager worktree list

capture worktree-move git worktree move old new
assert_argv "$fixture/worktree-move.argv" worktree move old new

capture worktree-remove git worktree remove old
assert_argv "$fixture/worktree-remove.argv" worktree remove old

capture worktree-add git worktree add "$fixture/new-worktree" topic
assert_argv "$fixture/worktree-add.argv" add "$fixture/new-worktree" topic

capture worktree-add-global git -C "$fixture/repo/subdirectory" --no-pager worktree add ../linked topic
assert_argv "$fixture/worktree-add-global.argv" add ../linked topic
test "$(cat "$fixture/worktree-add-global.pwd")" = "$(realpath "$fixture/repo/subdirectory")"

capture worktree-add-config git -c advice.detachedHead=false worktree add "$fixture/configured"
assert_argv "$fixture/worktree-add-config.argv" add "$fixture/configured"
test "$(cat "$fixture/worktree-add-config.config")" = false
