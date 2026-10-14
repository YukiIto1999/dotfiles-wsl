set -euo pipefail

# Nix store 内の client として起動される。観測した事実を CAPTURE へ書き、AGENT_ACTION で任意の子や孫を残し、
# HOLD_READY と HOLD_RELEASE で外から終了を制御する。
session_dir=${DOTFILES_AGENT_WORKTREE_RECORD%/worktrees}
printf '%s\n' "$0" > "$CAPTURE/argv0"
printf '%s\0' "$@" > "$CAPTURE/argv"
pwd -P > "$CAPTURE/cwd"
printf '%s\n' "$DOTFILES_AGENT_SESSION_ID" > "$CAPTURE/session-id"
printf '%s\n' "$DOTFILES_AGENT_CLIENT" > "$CAPTURE/client"
printf '%s\n' "$DOTFILES_AGENT_PROJECT_ID" > "$CAPTURE/project-id"
printf '%s\n' "$PPID" > "$CAPTURE/supervisor-pid"
printf '%s\n' "$$" > "$CAPTURE/agent-pid"
printf '%s\n' "$session_dir" > "$CAPTURE/session-dir"
for name in TMPDIR CARGO_HOME CARGO_BUILD_BUILD_DIR CARGO_TARGET_DIR XDG_CACHE_HOME; do
  if [ "${!name+x}" = x ]; then
    printf 'set:%s\n' "${!name}"
  else
    printf 'unset\n'
  fi > "$CAPTURE/env-$name"
done
command -v git > "$CAPTURE/git-command"
command -v nix > "$CAPTURE/nix-command" || printf 'none\n' > "$CAPTURE/nix-command"
command -v nix-build > "$CAPTURE/nix-build-command" || printf 'none\n' > "$CAPTURE/nix-build-command"
cp "$session_dir/metadata.json" "$CAPTURE/metadata.json"
stat -c %a "$session_dir" > "$CAPTURE/session-mode"
stat -c %a "$session_dir/metadata.json" > "$CAPTURE/metadata-mode"
stat -c %a "$HOME/.cache/dotfiles-wsl/gc.lock" > "$CAPTURE/lock-mode"
ls -A "$session_dir" > "$CAPTURE/session-listing"
if [ -d "$session_dir/tmp" ]; then
  stat -c %a "$session_dir/tmp" > "$CAPTURE/tmp-mode"
fi
for root in "$session_dir/roots"/*; do
  [ -L "$root" ] || continue
  printf '%s %s\n' "${root##*/}" "$(readlink "$root")"
done | sort > "$CAPTURE/roots"
if [ -n "${AGENT_ACTION-}" ]; then
  "$BASH" -c "$AGENT_ACTION"
fi
if [ -n "${HOLD_READY-}" ] && [ -n "${HOLD_RELEASE-}" ]; then
  : > "$HOLD_READY"
  while [ ! -e "$HOLD_RELEASE" ]; do
    sleep 0.02
  done
fi
if [ -n "${FAKE_SIGNAL-}" ]; then
  kill -s "$FAKE_SIGNAL" "$$"
fi
exit "${FAKE_STATUS:-0}"
