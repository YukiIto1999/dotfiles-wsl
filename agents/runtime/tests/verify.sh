#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/verify-fixture
home=$fixture/home
repo=$fixture/repo
mkdir -p "$home" "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$repo/tracked"
printf 'ignored\n' > "$repo/.gitignore"
git -C "$repo" add tracked .gitignore
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
