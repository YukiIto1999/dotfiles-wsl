#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/verify-fixture
home=$fixture/home
repo=$fixture/repo
gitlink_repo=$fixture/gitlink-repo
nested_gitlink_repo=$fixture/nested-gitlink-repo
mkdir -p "$home" "$repo" "$gitlink_repo" "$nested_gitlink_repo"
git -C "$nested_gitlink_repo" init -q
git -C "$nested_gitlink_repo" config user.name fixture
git -C "$nested_gitlink_repo" config user.email fixture@example.invalid
printf 'nested\n' >"$nested_gitlink_repo/tracked"
git -C "$nested_gitlink_repo" add tracked
git -C "$nested_gitlink_repo" commit -qm initial
git -C "$gitlink_repo" init -q
git -C "$gitlink_repo" config user.name fixture
git -C "$gitlink_repo" config user.email fixture@example.invalid
printf 'gitlink\n' >"$gitlink_repo/tracked"
printf 'gitlink missing\n' >"$gitlink_repo/tracked-missing"
printf 'gitlink special\n' >"$gitlink_repo/tracked-special"
printf 'target one\n' >"$gitlink_repo/link-target-one"
printf 'target two\n' >"$gitlink_repo/link-target-two"
ln -s link-target-one "$gitlink_repo/tracked-link"
printf '.layout/\n' >"$gitlink_repo/.gitignore"
git -C "$gitlink_repo" add tracked tracked-missing tracked-special link-target-one \
  link-target-two tracked-link .gitignore
git -C "$gitlink_repo" commit -qm initial
git -C "$gitlink_repo" -c protocol.file.allow=always submodule add -q \
  "$nested_gitlink_repo" nested
git -C "$gitlink_repo" commit -qam nested
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$repo/tracked"
printf 'tracked missing\n' > "$repo/tracked-missing"
printf 'tracked special\n' > "$repo/tracked-special"
printf 'link target one\n' > "$repo/link-target-one"
printf 'link target two\n' > "$repo/link-target-two"
ln -s link-target-one "$repo/tracked-link"
printf 'ignored\n' > "$repo/.gitignore"
git -C "$repo" add tracked tracked-missing tracked-special link-target-one link-target-two \
  tracked-link .gitignore
git -C "$repo" commit -qm initial

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
export COUNT=$fixture/count
mkdir -p "$HOME/.cache/dotfiles-wsl/verification"
chmod 0777 "$HOME/.cache/dotfiles-wsl" "$HOME/.cache/dotfiles-wsl/verification"
cd "$repo"

cat > "$fixture/environment-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$ENV_COUNT" || count=$(cat "$ENV_COUNT")
printf '%s\n' "$((count + 1))" > "$ENV_COUNT"
test "${DOTFILES_ARBITRARY_INPUT-}" != fail || exit 42
SCRIPT
chmod +x "$fixture/environment-check"
sed -i "1c#!$BASH" "$fixture/environment-check"
export ENV_COUNT=$fixture/environment-count

DOTFILES_ARBITRARY_INPUT=pass "$VERIFY" -- "$fixture/environment-check"
set +e
DOTFILES_ARBITRARY_INPUT=fail "$VERIFY" -- "$fixture/environment-check"
environment_status=$?
set -e
if [ "$environment_status" -ne 42 ]; then
  echo 'verify reused success after arbitrary environment changed' >&2
  exit 1
fi
test "$(cat "$ENV_COUNT")" = 2
project_state=$(find "$HOME/.cache/dotfiles-wsl/verification" -mindepth 1 -maxdepth 1 -type d)
success_file=$(find "$project_state" -type f -name '*.success' -print -quit)
chmod 0666 "$success_file"
DOTFILES_ARBITRARY_INPUT=pass "$VERIFY" -- "$fixture/environment-check"
test "$(cat "$ENV_COUNT")" = 2
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/verification")" = 700
test "$(stat -c %a "$project_state")" = 700
test "$(stat -c %a "$success_file")" = 600

"$VERIFY" -- "$fixture/check" first
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 1

original_count=$COUNT
export COUNT=$fixture/mode-count
"$VERIFY" -- "$fixture/check" mode
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 1
chmod 0444 tracked
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 2
"$VERIFY" -- "$fixture/check" mode
test "$(cat "$COUNT")" = 2
chmod 0644 tracked
export COUNT=$original_count

export COUNT=$fixture/atomic-rewrite-count
"$VERIFY" -- "$fixture/check" atomic-rewrite
"$VERIFY" -- "$fixture/check" atomic-rewrite
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify did not cache the initial atomic-rewrite check' >&2
  exit 1
fi
tracked_inode=$(stat -c %i tracked)
printf 'tracked\n' >"$fixture/tracked-replacement"
chmod 0644 "$fixture/tracked-replacement"
mv -T "$fixture/tracked-replacement" tracked
test "$(stat -c %i tracked)" != "$tracked_inode"
"$VERIFY" -- "$fixture/check" atomic-rewrite
"$VERIFY" -- "$fixture/check" atomic-rewrite
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify invalidated identical content after an inode-only rewrite' >&2
  exit 1
fi

export COUNT=$fixture/symlink-count
"$VERIFY" -- "$fixture/check" symlink
"$VERIFY" -- "$fixture/check" symlink
test "$(cat "$COUNT")" = 1
ln -sfn link-target-two tracked-link
"$VERIFY" -- "$fixture/check" symlink
"$VERIFY" -- "$fixture/check" symlink
test "$(cat "$COUNT")" = 2

export COUNT=$fixture/missing-count
"$VERIFY" -- "$fixture/check" missing
"$VERIFY" -- "$fixture/check" missing
test "$(cat "$COUNT")" = 1
rm tracked-missing
"$VERIFY" -- "$fixture/check" missing
"$VERIFY" -- "$fixture/check" missing
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify did not cache an explicit missing tracked-path state' >&2
  exit 1
fi
printf 'tracked missing\n' > tracked-missing

git -C "$repo" -c protocol.file.allow=always submodule add -q "$gitlink_repo" tracked-gitlink
git -C "$repo" -c protocol.file.allow=always submodule update -q --init --recursive
export COUNT=$fixture/gitlink-clean-count
"$VERIFY" -- "$fixture/check" gitlink
"$VERIFY" -- "$fixture/check" gitlink
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify did not cache a clean gitlink state' >&2
  exit 1
fi

export COUNT=$fixture/gitlink-assume-unchanged-count
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked
printf 'changed\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
printf 'mutated\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
"$VERIFY" -- "$fixture/check" gitlink-assume-unchanged
if [ "$(cat "$COUNT")" != 5 ]; then
  echo 'verify reused a cache entry for assume-unchanged gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-assume-unchanged tracked
git -C tracked-gitlink checkout -q -- tracked

export COUNT=$fixture/gitlink-mode-count
git -C tracked-gitlink config core.fileMode false
"$VERIFY" -- "$fixture/check" gitlink-mode
"$VERIFY" -- "$fixture/check" gitlink-mode
test "$(cat "$COUNT")" = 1
chmod 0444 tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-mode
"$VERIFY" -- "$fixture/check" gitlink-mode
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for a gitlink mode-only change' >&2
  exit 1
fi
chmod 0644 tracked-gitlink/tracked
git -C tracked-gitlink config core.fileMode true

export COUNT=$fixture/gitlink-symlink-count
"$VERIFY" -- "$fixture/check" gitlink-symlink
"$VERIFY" -- "$fixture/check" gitlink-symlink
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked-link
ln -sfn link-target-two tracked-gitlink/tracked-link
"$VERIFY" -- "$fixture/check" gitlink-symlink
"$VERIFY" -- "$fixture/check" gitlink-symlink
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for an assume-unchanged gitlink symlink' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-assume-unchanged tracked-link
git -C tracked-gitlink checkout -q -- tracked-link

export COUNT=$fixture/gitlink-skip-missing-count
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --skip-worktree tracked-missing
rm tracked-gitlink/tracked-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
"$VERIFY" -- "$fixture/check" gitlink-skip-missing
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for a missing skip-worktree gitlink path' >&2
  exit 1
fi
git -C tracked-gitlink update-index --no-skip-worktree tracked-missing
git -C tracked-gitlink checkout -q -- tracked-missing

export COUNT=$fixture/gitlink-special-count
"$VERIFY" -- "$fixture/check" gitlink-special
"$VERIFY" -- "$fixture/check" gitlink-special
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink update-index --assume-unchanged tracked-special
rm tracked-gitlink/tracked-special
mkdir tracked-gitlink/tracked-special
"$VERIFY" -- "$fixture/check" gitlink-special
"$VERIFY" -- "$fixture/check" gitlink-special
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify cached an unverifiable special gitlink path' >&2
  exit 1
fi
rmdir tracked-gitlink/tracked-special
git -C tracked-gitlink update-index --no-assume-unchanged tracked-special
git -C tracked-gitlink checkout -q -- tracked-special

export COUNT=$fixture/gitlink-stage-conflict-count
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
test "$(cat "$COUNT")" = 1
gitlink_stage_oid=$(git -C tracked-gitlink rev-parse HEAD:tracked-special)
gitlink_zero_oid=${gitlink_stage_oid//?/0}
test "${#gitlink_zero_oid}" -eq "${#gitlink_stage_oid}"
{
  printf '0 %s\ttracked-special\n' "$gitlink_zero_oid"
  printf '100644 %s 1\ttracked-special\n' "$gitlink_stage_oid"
  printf '100644 %s 2\ttracked-special\n' "$gitlink_stage_oid"
  printf '100644 %s 3\ttracked-special\n' "$gitlink_stage_oid"
} | git -C tracked-gitlink update-index --index-info
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
"$VERIFY" -- "$fixture/check" gitlink-stage-conflict
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify cached an unmerged gitlink index' >&2
  exit 1
fi
git -C tracked-gitlink reset -q HEAD -- tracked-special

export COUNT=$fixture/gitlink-nested-count
"$VERIFY" -- "$fixture/check" gitlink-nested
"$VERIFY" -- "$fixture/check" gitlink-nested
test "$(cat "$COUNT")" = 1
git -C tracked-gitlink/nested update-index --assume-unchanged tracked
printf 'mutate\n' >tracked-gitlink/nested/tracked
"$VERIFY" -- "$fixture/check" gitlink-nested
"$VERIFY" -- "$fixture/check" gitlink-nested
if [ "$(cat "$COUNT")" != 3 ]; then
  echo 'verify reused a cache entry for nested gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink/nested update-index --no-assume-unchanged tracked
git -C tracked-gitlink/nested checkout -q -- tracked

export COUNT=$fixture/gitlink-tracked-dirty-count
printf 'changed\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
printf 'mutated\n' >tracked-gitlink/tracked
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-tracked-dirty
if [ "$(cat "$COUNT")" != 4 ]; then
  echo 'verify reused a cache entry for dirty gitlink content' >&2
  exit 1
fi
git -C tracked-gitlink checkout -q -- tracked

export COUNT=$fixture/gitlink-untracked-dirty-count
printf 'untracked\n' >tracked-gitlink/untracked
"$VERIFY" -- "$fixture/check" gitlink-untracked-dirty
"$VERIFY" -- "$fixture/check" gitlink-untracked-dirty
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for an untracked-dirty gitlink' >&2
  exit 1
fi
rm tracked-gitlink/untracked

export COUNT=$fixture/gitlink-unverifiable-count
mv tracked-gitlink/.git "$fixture/tracked-gitlink-dotgit"
"$VERIFY" -- "$fixture/check" gitlink-unverifiable
"$VERIFY" -- "$fixture/check" gitlink-unverifiable
if [ "$(cat "$COUNT")" != 2 ]; then
  echo 'verify reused a cache entry for an unverifiable gitlink' >&2
  exit 1
fi
mv "$fixture/tracked-gitlink-dotgit" tracked-gitlink/.git

export COUNT=$fixture/gitlink-layout-count
"$VERIFY" -- "$fixture/check" gitlink-layout
"$VERIFY" -- "$fixture/check" gitlink-layout
test "$(cat "$COUNT")" = 1
mkdir tracked-gitlink/.layout
"$VERIFY" -- "$fixture/check" gitlink-layout
"$VERIFY" -- "$fixture/check" gitlink-layout
if [ "$(cat "$COUNT")" != 1 ]; then
  echo 'verify fingerprint depended on gitlink directory layout metadata' >&2
  exit 1
fi

export COUNT=$fixture/special-count
"$VERIFY" -- "$fixture/check" special
"$VERIFY" -- "$fixture/check" special
test "$(cat "$COUNT")" = 1
rm tracked-special
mkdir tracked-special
"$VERIFY" -- "$fixture/check" special
"$VERIFY" -- "$fixture/check" special
test "$(cat "$COUNT")" = 3
rm -r tracked-special
printf 'tracked special\n' > tracked-special
export COUNT=$original_count

printf 'dirty\n' >> tracked
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 2

printf 'untracked-1\n' > new-file
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 3
printf 'untracked-2\n' > new-file
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 4

printf 'ignored-change\n' > ignored
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 4

RUSTFLAGS=-Cdebuginfo=0 "$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 5
"$VERIFY" -- "$fixture/check" second
test "$(cat "$COUNT")" = 6

set +e
CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" failure
first_failure=$?
CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" failure
second_failure=$?
set -e
test "$first_failure" -eq 7
test "$second_failure" -eq 7
test "$(cat "$COUNT")" = 8

printf 'new head\n' > committed
git add committed
git commit -qm second
"$VERIFY" -- "$fixture/check" first
test "$(cat "$COUNT")" = 9

cat > "$fixture/mutating-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$MUTATE_COUNT" || count=$(cat "$MUTATE_COUNT")
printf '%s\n' "$((count + 1))" > "$MUTATE_COUNT"
printf 'stable result\n' > tracked
SCRIPT
chmod +x "$fixture/mutating-check"
sed -i "1c#!$BASH" "$fixture/mutating-check"
export MUTATE_COUNT=$fixture/mutate-count
"$VERIFY" -- "$fixture/mutating-check"
"$VERIFY" -- "$fixture/mutating-check"
"$VERIFY" -- "$fixture/mutating-check"
test "$(cat "$MUTATE_COUNT")" = 2

test -n "$(find "$home/.cache/dotfiles-wsl/verification" -type f -name '*.success' -print -quit)"
test -z "$(find "$home/.cache/dotfiles-wsl/verification" -type f ! -name '*.success' -print -quit)"

outside=$fixture/outside
mkdir "$outside"
cd "$outside"
"$VERIFY" -- "$fixture/check" outside
"$VERIFY" -- "$fixture/check" outside
test "$(cat "$COUNT")" = 11
