#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/git-shim-fixture
mkdir -p "$fixture"

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

capture() {
  local name=$1
  shift
  ARG_CAPTURE="$fixture/$name.argv" "$@"
}

# Outside a session, and for every other command inside one, git receives the argv unchanged.
unset DOTFILES_AGENT_WORKTREE_RECORD
capture regular "$GIT_SHIM_DIR/bin/git" status --short
assert_argv "$fixture/regular.argv" status --short

capture worktree-add-outside "$GIT_SHIM_DIR/bin/git" -C "$fixture" worktree add new topic
assert_argv "$fixture/worktree-add-outside.argv" -C "$fixture" worktree add new topic

export DOTFILES_AGENT_WORKTREE_RECORD=$fixture/fake-record
capture worktree-list "$GIT_SHIM_DIR/bin/git" --no-pager worktree list
assert_argv "$fixture/worktree-list.argv" --no-pager worktree list

capture worktree-remove "$GIT_SHIM_DIR/bin/git" worktree remove old
assert_argv "$fixture/worktree-remove.argv" worktree remove old
test ! -e "$DOTFILES_AGENT_WORKTREE_RECORD"

repo=$fixture/repo
git init -q "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
mkdir "$repo/subdirectory"
head=$(git -C "$repo" rev-parse HEAD)

read_record() {
  record=()
  if [ -e "$DOTFILES_AGENT_WORKTREE_RECORD" ]; then
    mapfile -d '' -t record < "$DOTFILES_AGENT_WORKTREE_RECORD"
  fi
}

# A successful add inside a session records the worktree it created and the HEAD it started from,
# resolving a relative path against the -C directory.
export DOTFILES_AGENT_WORKTREE_RECORD=$fixture/record
"$AGENT_SHIM_DIR/bin/git" -C "$repo/subdirectory" worktree add -q -b topic ../../linked
read_record
test "${#record[@]}" -eq 2
test "${record[0]}" = "$(realpath "$fixture/linked")"
test "${record[1]}" = "$head"

# A failed add records nothing and keeps the failure status.
set +e
"$AGENT_SHIM_DIR/bin/git" -C "$repo" worktree add -q "$fixture/linked" 2>/dev/null
status=$?
set -e
test "$status" -ne 0
read_record
test "${#record[@]}" -eq 2

# When another add lands between the snapshots, the shim cannot tell which worktree is its own and
# records neither of them.
RACE_REPO=$repo RACE_WORKTREE=$fixture/other-session \
  "$RACING_GIT_SHIM_DIR/bin/git" -C "$repo" worktree add -q --detach "$fixture/raced"
test -d "$fixture/other-session"
test -d "$fixture/raced"
read_record
test "${#record[@]}" -eq 2
