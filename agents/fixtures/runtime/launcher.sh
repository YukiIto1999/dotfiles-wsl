#!/usr/bin/env bash
set -euo pipefail

fixture=$PWD/launcher-fixture
fixture_home=$fixture/home
capture=$fixture/capture
mkdir -p "$fixture_home/.local/bin" "$fixture/bin" "$capture"

cat > "$fixture/bin/dotfiles-agent-resource" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  begin-session)
    test -d "$TMPDIR"
    test -f "${TMPDIR%/tmp}/metadata.json"
    test "$DOTFILES_AGENT_SESSION_ID" = "$2"
    test "$DOTFILES_AGENT_CLIENT" = fixture-client
    test "$DOTFILES_AGENT_BOOT_ID" = "$(cat /proc/sys/kernel/random/boot_id)"
    test "$DOTFILES_AGENT_OWNER_START_TIME" = "$(awk '{print $22}' "/proc/$DOTFILES_AGENT_OWNER_PID/stat")"
    printf 'begin:%s\n' "$2" >> "$HOOK_LOG"
    ;;
  cleanup-session)
    test ! -e "$TMPDIR"
    test "$DOTFILES_AGENT_SESSION_ID" = "$2"
    test "$DOTFILES_AGENT_CLIENT" = fixture-client
    test "$DOTFILES_AGENT_BOOT_ID" = "$(cat /proc/sys/kernel/random/boot_id)"
    test "$DOTFILES_AGENT_OWNER_START_TIME" = "$(awk '{print $22}' "/proc/$DOTFILES_AGENT_OWNER_PID/stat")"
    printf 'cleanup:%s\n' "$2" >> "$HOOK_LOG"
    ;;
  *)
    exit 64
    ;;
esac
test "${HOOK_FAIL:-0}" != 1
SCRIPT
chmod +x "$fixture/bin/dotfiles-agent-resource"
sed -i "1c#!$BASH" "$fixture/bin/dotfiles-agent-resource"

cat > "$fixture_home/.local/bin/fake-agent" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
test -d "$TMPDIR"
test "${CARGO_HOME+x}" = x
test "${XDG_CACHE_HOME+x}" = x
printf '%s\n' "$DOTFILES_AGENT_SESSION_ID" > "$CAPTURE/session-id"
printf '%s\n' "$DOTFILES_AGENT_CLIENT" > "$CAPTURE/client"
printf '%s\n' "$DOTFILES_AGENT_PROJECT_ID" > "$CAPTURE/project-id"
printf '%s\n' "$DOTFILES_AGENT_OWNER_PID" > "$CAPTURE/owner-pid"
printf '%s\n' "$DOTFILES_AGENT_OWNER_START_TIME" > "$CAPTURE/owner-start-time"
printf '%s\n' "$DOTFILES_AGENT_BOOT_ID" > "$CAPTURE/boot-id"
printf '%s\n' "$TMPDIR" > "$CAPTURE/tmpdir"
printf '%s\n' "$CARGO_HOME" > "$CAPTURE/cargo-home"
printf '%s\n' "$XDG_CACHE_HOME" > "$CAPTURE/xdg-cache-home"
printf '%s\n' "${CARGO_TARGET_DIR-unset}" > "$CAPTURE/cargo-target"
if [ "${PROBE_CACHE_WRITES:-0}" = 1 ]; then
  test -n "$CARGO_HOME"
  test -n "$XDG_CACHE_HOME"
  mkdir -p "$CARGO_HOME/fixture-write"
  printf 'cargo\n' > "$CARGO_HOME/fixture-write/probe"
  mkdir -p "$XDG_CACHE_HOME/fixture-write"
  printf 'xdg\n' > "$XDG_CACHE_HOME/fixture-write/probe"
fi
command -v nix > "$CAPTURE/nix-command"
command -v git > "$CAPTURE/git-command"
printf '%s\0' "$@" > "$CAPTURE/argv"
cp "${TMPDIR%/tmp}/metadata.json" "$CAPTURE/metadata.json"
stat -c %a "$TMPDIR" > "$CAPTURE/tmp-mode"
stat -c %a "${TMPDIR%/tmp}" > "$CAPTURE/session-mode"
stat -c %a "${TMPDIR%/tmp}/metadata.json" > "$CAPTURE/metadata-mode"
stat -c %a "$HOME/.cache/dotfiles-wsl/gc.lock" > "$CAPTURE/lock-mode"
exit "${FAKE_STATUS:-0}"
SCRIPT
chmod +x "$fixture_home/.local/bin/fake-agent"
sed -i "1c#!$BASH" "$fixture_home/.local/bin/fake-agent"

repo=$fixture/repo
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'tracked\n' > "$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -qm initial

export HOME=$fixture_home
export CAPTURE=$capture
export HOOK_LOG=$capture/hooks
export PATH="$fixture/bin:$PATH"
unset CARGO_HOME CARGO_TARGET_DIR XDG_CACHE_HOME
mkdir -p "$HOME/.cache/dotfiles-wsl/sessions" "$HOME/.cache/dotfiles-wsl/builds"
chmod 0777 "$HOME/.cache/dotfiles-wsl" \
  "$HOME/.cache/dotfiles-wsl/sessions" \
  "$HOME/.cache/dotfiles-wsl/builds"

set +e
(
  cd "$repo"
  PROBE_CACHE_WRITES=1 FAKE_STATUS=23 \
    "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent" \
    'space arg' 'line
arg'
)
status=$?
set -e
test "$status" -eq 23
test "$(cat "$capture/client")" = fixture-client
test "$(jq -r '.client' "$capture/metadata.json")" = fixture-client
test "$(jq -r '.project_id' "$capture/metadata.json")" = "$(cat "$capture/project-id")"
test "$(jq -r '.boot_id' "$capture/metadata.json")" = "$(cat /proc/sys/kernel/random/boot_id)"
test "$(jq -r '.owner_pid | type' "$capture/metadata.json")" = number
test "$(jq -r '.owner_start_time | type' "$capture/metadata.json")" = string
test "$(jq -r '.owner_pid' "$capture/metadata.json")" = "$(cat "$capture/owner-pid")"
test "$(jq -r '.owner_start_time' "$capture/metadata.json")" = "$(cat "$capture/owner-start-time")"
test "$(jq -r '.boot_id' "$capture/metadata.json")" = "$(cat "$capture/boot-id")"
test "$(cat "$capture/nix-command")" = "$AGENT_SHIM_DIR/bin/nix"
test "$(cat "$capture/git-command")" = "$AGENT_SHIM_DIR/bin/git"
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/sessions")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/builds")" = 700
test "$(cat "$capture/cargo-home")" = "$HOME/.cache/dotfiles-wsl/shared/cargo-home"
test "$(cat "$capture/xdg-cache-home")" = "$HOME/.cache/dotfiles-wsl/shared/xdg-cache"
test "$(cat "$HOME/.cache/dotfiles-wsl/shared/cargo-home/fixture-write/probe")" = cargo
test "$(cat "$HOME/.cache/dotfiles-wsl/shared/xdg-cache/fixture-write/probe")" = xdg
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/shared")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/shared/cargo-home")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/shared/xdg-cache")" = 700
test "$(stat -c %a "$HOME/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json")" = 600
jq --exit-status '. == {version: 1, kind: "shared-cache"}' \
  "$HOME/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json" > /dev/null
test "$(cat "$capture/tmp-mode")" = 700
test "$(cat "$capture/session-mode")" = 700
test "$(cat "$capture/metadata-mode")" = 600
test "$(cat "$capture/lock-mode")" = 600
test ! -e "$(cat "$capture/tmpdir")"
test "$(sed -n '1s/:.*//p' "$capture/hooks")" = begin
test "$(sed -n '2s/:.*//p' "$capture/hooks")" = cleanup
test "$(sed -n '1s/^[^:]*://p' "$capture/hooks")" = "$(cat "$capture/session-id")"
test "$(sed -n '2s/^[^:]*://p' "$capture/hooks")" = "$(cat "$capture/session-id")"
mapfile -d '' -t argv < "$capture/argv"
test "${#argv[@]}" -eq 2
test "${argv[0]}" = 'space arg'
test "${argv[1]}" = $'line\narg'

set +e
(
  cd "$repo"
  HOOK_FAIL=1 FAKE_STATUS=19 "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
hook_failure_status=$?
set -e
test "$hook_failure_status" -eq 19

project_id=$(cat "$capture/project-id")
expected_target="$fixture_home/.cache/dotfiles-wsl/builds/$project_id/cargo-target"
test "$(cat "$capture/cargo-target")" = "$expected_target"
jq --exit-status \
  --arg project_id "$project_id" \
  '. == {version: 1, project_id: $project_id}' \
  "$fixture_home/.cache/dotfiles-wsl/builds/$project_id/.dotfiles-agent-cache.json" > /dev/null
test "$(stat -c %a "$fixture_home/.cache/dotfiles-wsl/builds/$project_id")" = 700
test "$(stat -c %a "$fixture_home/.cache/dotfiles-wsl/builds/$project_id/.dotfiles-agent-cache.json")" = 600

expect_shared_cache_failure() {
  local bad_home=$1 status
  set +e
  HOME=$bad_home CAPTURE=$capture HOOK_LOG=$capture/hooks \
    "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
  status=$?
  set -e
  test "$status" -eq 70
}

symlink_home=$fixture/symlink-home
mkdir -p "$symlink_home/.cache/dotfiles-wsl/sessions" \
  "$symlink_home/.cache/dotfiles-wsl/builds"
ln -s "$repo" "$symlink_home/.cache/dotfiles-wsl/shared"
expect_shared_cache_failure "$symlink_home"

wrong_type_home=$fixture/wrong-type-home
mkdir -p "$wrong_type_home/.cache/dotfiles-wsl/sessions" \
  "$wrong_type_home/.cache/dotfiles-wsl/builds"
printf 'not a directory\n' > "$wrong_type_home/.cache/dotfiles-wsl/shared"
expect_shared_cache_failure "$wrong_type_home"

malformed_home=$fixture/malformed-home
mkdir -p "$malformed_home/.cache/dotfiles-wsl/sessions" \
  "$malformed_home/.cache/dotfiles-wsl/builds" \
  "$malformed_home/.cache/dotfiles-wsl/shared/cargo-home" \
  "$malformed_home/.cache/dotfiles-wsl/shared/xdg-cache"
printf '{}\n' > "$malformed_home/.cache/dotfiles-wsl/shared/.dotfiles-agent-cache.json"
expect_shared_cache_failure "$malformed_home"

(
  cd "$repo"
  CARGO_HOME=/explicit-cargo XDG_CACHE_HOME=/explicit-xdg \
    "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
test "$(cat "$capture/cargo-home")" = /explicit-cargo
test "$(cat "$capture/xdg-cache-home")" = /explicit-xdg

(
  cd "$repo"
  CARGO_HOME='' XDG_CACHE_HOME='' \
    "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
test -z "$(cat "$capture/cargo-home")"
test -z "$(cat "$capture/xdg-cache-home")"

(
  cd "$repo"
  CARGO_TARGET_DIR=/explicit "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
test "$(cat "$capture/cargo-target")" = /explicit

mkdir -p "$repo/.cargo"
printf '[build]\ntarget-dir = "project-target"\n' > "$repo/.cargo/config.toml"
(
  cd "$repo"
  unset CARGO_TARGET_DIR
  "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
test "$(cat "$capture/cargo-target")" = unset

rm "$repo/.cargo/config.toml"
git -C "$repo" worktree add -qb linked "$fixture/linked"
(
  cd "$repo"
  "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
main_project_id=$(cat "$capture/project-id")
main_cargo_home=$(cat "$capture/cargo-home")
main_xdg_cache_home=$(cat "$capture/xdg-cache-home")
(
  cd "$fixture/linked"
  "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
test "$(cat "$capture/project-id")" = "$main_project_id"
test "$(cat "$capture/cargo-home")" = "$main_cargo_home"
test "$(cat "$capture/xdg-cache-home")" = "$main_xdg_cache_home"

mkdir -p "$fixture/outside"
(
  cd "$fixture/outside"
  "$LAUNCHER" fixture-client "$fixture_home/.local/bin/fake-agent"
)
outside_project_id=$(cat "$capture/project-id")
test "$outside_project_id" != "$main_project_id"
test "${#outside_project_id}" -eq 64
test "$(cat "$capture/cargo-home")" = "$main_cargo_home"
test "$(cat "$capture/xdg-cache-home")" = "$main_xdg_cache_home"
