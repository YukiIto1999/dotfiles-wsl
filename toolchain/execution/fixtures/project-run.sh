#!/usr/bin/env bash
# project の devShell を開いて client を起動する入口を、起動された client が見る環境と、拒否された入口の後に
# 残る状態から読む。direnv と nix は sandbox にないため、direnv は承認状態を、nix は `nix develop` の
# 文書化された挙動(TMP 系の書換えと devShell の PATH を host の PATH の前に置く)を再現する。
# 実物の direnv と nix での確認は docs/operations/orca-launch.md の手順が受け持つ。
set -euo pipefail

fixture=$PWD/project-run-fixture
project="$fixture/project with space ユニコード"
mkdir -p "$project/sub" "$fixture/bin" "$fixture/host-bin" "$fixture/devshell-bin" "$fixture/shells"
: > "$project/.envrc"

# project の devShell だけが持つ tool と、host の PATH にも同名の client を置く。
printf '#!%s\nexit 0\n' "$BASH" > "$fixture/devshell-bin/project-tool"
printf '#!%s\n: > "%s/host-client-ran"\nexit 99\n' "$BASH" "$fixture" > "$fixture/host-bin/fake-client"
printf '#!%s\nprintf "host\\n"\n' "$BASH" > "$fixture/host-bin/project-tool"
cat > "$fixture/bin/fake-client" <<SCRIPT
#!$BASH
printf '%s\0' "\$@" > "$fixture/client.argv"
pwd -P > "$fixture/client.cwd"
command -v project-tool > "$fixture/client.tool"
for name in TMPDIR TMP TEMP TEMPDIR; do
  if [ "\${!name+x}" = x ]; then
    printf 'set:%s\n' "\${!name}"
  else
    printf 'unset\n'
  fi > "$fixture/client.\$name"
done
exit "\${CLIENT_STATUS:-0}"
SCRIPT
chmod +x "$fixture/devshell-bin/project-tool" "$fixture/host-bin/fake-client" \
  "$fixture/host-bin/project-tool" "$fixture/bin/fake-client"
client=$fixture/bin/fake-client

approval() {
  jq -n --argjson allowed "$1" --arg path "$2" \
    '{config: {}, state: {loadedRC: null, foundRC: {allowed: $allowed, path: $path}}}' \
    > "$fixture/direnv.json"
}

export FAKE_DIRENV_JSON=$fixture/direnv.json
export NIX_ARGV=$fixture/nix.argv
export FAKE_SHELL_ROOT=$fixture/shells
export DEVSHELL_BIN=$fixture/devshell-bin
export PATH="$fixture/host-bin:$PATH"

reset_observations() {
  rm -f "$fixture"/client.* "$fixture/nix.argv" "$fixture/host-client-ran"
}

# The entry runs in the directory below the approved project, with the caller's TMPDIR state
# chosen by the case.
entry() {
  (cd "$project/sub" && env -u TMPDIR -u TMP -u TEMP -u TEMPDIR "$@")
}

expect_refused() {
  local description=$1 status=0
  shift
  reset_observations
  entry "$@" >/dev/null 2>"$fixture/stderr" || status=$?
  test "$status" -ne 0 || {
    echo "$description: the entry succeeded" >&2
    exit 1
  }
  test ! -e "$fixture/client.argv" || {
    echo "$description: the client started" >&2
    exit 1
  }
  test ! -e "$fixture/host-client-ran" || {
    echo "$description: the host PATH client ran" >&2
    exit 1
  }
}

# An approved project: the devShell of the approved directory is opened without touching the lock,
# the client runs there by its absolute path with its own argv, and the project's tool wins.
approval 0 "$project/.envrc"
reset_observations
entry "$PROJECT_RUN" -- "$client" '' 'space arg' $'line\narg' 'ユニコード' A=B -u -- --attr x
mapfile -d '' -t argv < "$fixture/client.argv"
test "${#argv[@]}" -eq 9
test -z "${argv[0]}"
test "${argv[1]}" = 'space arg'
test "${argv[2]}" = $'line\narg'
test "${argv[3]}" = 'ユニコード'
test "${argv[4]}" = A=B
test "${argv[5]}" = -u
test "${argv[6]}" = --
test "${argv[7]}" = --attr
test "${argv[8]}" = x
test "$(cat "$fixture/client.cwd")" = "$(realpath "$project/sub")"
test "$(cat "$fixture/client.tool")" = "$fixture/devshell-bin/project-tool"
test ! -e "$fixture/host-client-ran"
mapfile -d '' -t nix_argv < "$fixture/nix.argv"
test "${nix_argv[0]}" = develop
test "${nix_argv[1]}" = --no-update-lock-file
test "${nix_argv[2]}" = --no-write-lock-file
test "${nix_argv[3]}" = "$project#default"
test "${nix_argv[4]}" = --command

# The caller's TMPDIR state survives nix develop, which always rewrites it.
for name in TMPDIR TMP TEMP TEMPDIR; do
  test "$(cat "$fixture/client.$name")" = unset
done
reset_observations
entry TMPDIR= "$PROJECT_RUN" -- "$client"
test "$(cat "$fixture/client.TMPDIR")" = 'set:'
test "$(cat "$fixture/client.TMP")" = unset
reset_observations
entry TMPDIR=/explicit/tmp TEMP=/explicit/temp "$PROJECT_RUN" -- "$client"
test "$(cat "$fixture/client.TMPDIR")" = 'set:/explicit/tmp'
test "$(cat "$fixture/client.TEMP")" = 'set:/explicit/temp'
test "$(cat "$fixture/client.TMP")" = unset
test "$(cat "$fixture/client.TEMPDIR")" = unset

# The client's exit status is the entry's.
reset_observations
status=0
entry CLIENT_STATUS=31 "$PROJECT_RUN" -- "$client" || status=$?
test "$status" -eq 31

# A named devShell is opened instead of the default.
reset_observations
entry "$PROJECT_RUN" --attr agent -- "$client"
mapfile -d '' -t nix_argv < "$fixture/nix.argv"
test "${nix_argv[3]}" = "$project#agent"

# A missing or failing devShell leaves the client unstarted and does not fall back to the host PATH.
export FAKE_NIX_FAIL=1
expect_refused 'devShell evaluation failure' "$PROJECT_RUN" -- "$client"
test -e "$fixture/nix.argv"
unset FAKE_NIX_FAIL

# Only an approval that direnv reports as allowed opens the project: not unapproved, not denied
# (where direnv exec itself would return the base environment), not a missing or unreadable state.
approval 1 "$project/.envrc"
expect_refused 'unapproved project' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
approval 2 "$project/.envrc"
expect_refused 'denied project' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
jq -n '{config: {}, state: {loadedRC: null, foundRC: null}}' > "$fixture/direnv.json"
expect_refused 'project without .envrc' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
approval 0 "$project/.env"
expect_refused 'dotenv file' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
printf 'not json\n' > "$fixture/direnv.json"
expect_refused 'unreadable approval state' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
approval 0 "$project/.envrc"
expect_refused 'direnv failure' FAKE_DIRENV_FAIL=1 "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
mkdir -p "$fixture/pro#ject"
approval 0 "$fixture/pro#ject/.envrc"
expect_refused 'project root a flake reference would reinterpret' "$PROJECT_RUN" -- "$client"
test ! -e "$fixture/nix.argv"
approval 0 "$project/.envrc"

# Arguments the entry cannot pass on safely are refused before anything starts.
for attr in 'a#b' '-x' '' 'with space'; do
  expect_refused "devShell name '$attr'" "$PROJECT_RUN" --attr "$attr" -- "$client"
  test ! -e "$fixture/nix.argv"
done
expect_refused 'relative executable' "$PROJECT_RUN" -- bin/fake-client
expect_refused 'missing executable' "$PROJECT_RUN" -- "$fixture/bin/absent"
printf 'data\n' > "$fixture/bin/not-executable"
expect_refused 'non-executable file' "$PROJECT_RUN" -- "$fixture/bin/not-executable"
mkdir -p "$fixture/with=equals"
cp "$client" "$fixture/with=equals/fake-client"
expect_refused 'executable path with =' "$PROJECT_RUN" -- "$fixture/with=equals/fake-client"
test ! -e "$fixture/nix.argv"

# Usage errors run nothing.
status=0
entry "$PROJECT_RUN" "$client" 2>/dev/null || status=$?
test "$status" -eq 2
test ! -e "$fixture/client.argv"
