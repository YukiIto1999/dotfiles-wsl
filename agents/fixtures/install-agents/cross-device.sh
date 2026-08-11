#!/usr/bin/env bash
set -euo pipefail

: "${INSTALL_AGENTS:?}"

fixture=${1:?}
archive=${2:?}
api=${3:?}
legacy_binary=${4:?}
declare -a mounted=()

cleanup_mounts() {
  local path

  for path in "${mounted[@]}"; do
    umount -l "$path" 2>/dev/null || true
  done
}
trap cleanup_mounts EXIT

prepare_cross_device_home() {
  local home=$1

  mkdir -p "$home/.local/bin" "$home/.local/share"
  mount -t tmpfs -o mode=0755,size=4m tmpfs "$home/.local/bin"
  mounted+=("$home/.local/bin")
  chmod 0755 "$home/.local/bin"
  test "$(stat -c %d -- "$home/.local/bin")" != "$(stat -c %d -- "$home/.local/share")"
}

configure_run() {
  local home=$1

  export HOME=$home
  export FIXTURE_ARCHIVE=$archive
  export FIXTURE_API_JSON=$api
  export FIXTURE_ARCH=x86_64
  export FIXTURE_CURL_LOG=$home/curl.log
  export FIXTURE_TAR_LOG=$home/tar.log
  : >"$FIXTURE_CURL_LOG"
  : >"$FIXTURE_TAR_LOG"
}

assert_no_residue() {
  local home=$1 root

  root=$home/.local/share/dotfiles/agents/codex

  test -z "$(find "$home/.local/bin" -mindepth 1 -maxdepth 1 \
    \( -name '.codex.next.*' -o -name '.atomic-quarantine.*' \) -print -quit)"
  if [[ -d $root ]]; then
    test -z "$(find "$root" -maxdepth 1 \
      \( -name '.stage.*' -o -name '.current.next.*' -o -name '.atomic-quarantine.*' \) \
      -print -quit)"
  fi
}

# A missing visible destination publishes without creating a cross-device backup.
home=$fixture/normal
prepare_cross_device_home "$home"
configure_run "$home"
"$INSTALL_AGENTS"
test "$(readlink -- "$home/.local/bin/codex")" \
  = '../share/dotfiles/agents/codex/current/bin/codex'
assert_no_residue "$home"

# A legacy regular file is quarantined and deleted within the visible parent filesystem.
home=$fixture/legacy
prepare_cross_device_home "$home"
install -m 0755 "$legacy_binary" "$home/.local/bin/codex"
configure_run "$home"
"$INSTALL_AGENTS"
test "$(readlink -- "$home/.local/bin/codex")" \
  = '../share/dotfiles/agents/codex/current/bin/codex'
assert_no_residue "$home"

# Failure after the visible exchange restores the legacy file and removes every known temp.
home=$fixture/rollback
prepare_cross_device_home "$home"
install -m 0755 "$legacy_binary" "$home/.local/bin/codex"
legacy_inode=$(stat -c %i -- "$home/.local/bin/codex")
configure_run "$home"
export FIXTURE_TRANSACTION_HOOK_EVENT=after-visible-switch
export FIXTURE_TRANSACTION_HOOK_ACTION=fail
export FIXTURE_TRANSACTION_HOOK_MARKER=$fixture/rollback.marker
if "$INSTALL_AGENTS" >"$fixture/rollback.stdout" 2>"$fixture/rollback.stderr"; then
  echo 'cross-device rollback unexpectedly succeeded' >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
test -f "$home/.local/bin/codex"
test ! -L "$home/.local/bin/codex"
test "$(stat -c %i -- "$home/.local/bin/codex")" = "$legacy_inode"
cmp -- "$legacy_binary" "$home/.local/bin/codex"
test ! -e "$home/.local/share/dotfiles/agents/codex/current"
test -z "$(find "$home/.local/share/dotfiles/agents/codex/releases" -mindepth 1 -print -quit)"
assert_no_residue "$home"
