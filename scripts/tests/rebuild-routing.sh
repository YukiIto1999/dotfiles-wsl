#!/usr/bin/env bash
set -euo pipefail

rebuild_source=${1:?rebuild source path is required}
bash_path=${2:?bash path is required}
fakeroot_path=${3:?fakeroot path is required}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

repo=$test_root/dotfiles-wsl
fake_bin=$test_root/fake-bin
call_log=$test_root/calls.log
stdout_log=$test_root/stdout.log
stderr_log=$test_root/stderr.log
source_path=/nix/store/test-dotfiles-source
candidate=$test_root/nix/store/test-system
rebuild=$test_root/dotfiles-rebuild

mkdir -p "$repo/.git" "$fake_bin" "$candidate/sw/bin"
sed "s|@dotfilesDir@|$repo|g" "$rebuild_source" > "$rebuild"
chmod +x "$rebuild"

cat > "$fake_bin/command-stub" <<'STUB'
#!@bash@
set -euo pipefail

name=${0##*/}
printf -v call '%s' "$name"
for argument in "$@"; do
  printf -v quoted ' %q' "$argument"
  call+=$quoted
done
printf '%s\n' "$call" >> "$CALL_LOG"

case "${TEST_FAIL_AT:-}:$name:${1:-}:${2:-}" in
  archive:nix:flake:archive | check:nix:flake:check | build:nix:build:--no-link | nvd:nvd:* | helper:dotfiles-wsl-restart-required:*)
    exit 70
    ;;
esac

case $name in
  git)
    printf '%s' "${TEST_UNTRACKED:-}"
    ;;
  nix)
    case "${1:-} ${2:-}" in
      "flake archive") printf '{"path":"%s"}\n' "$TEST_SOURCE_PATH" ;;
      "flake check") ;;
      "build --no-link") printf '%s\n' "$TEST_CANDIDATE" ;;
      *) exit 64 ;;
    esac
    ;;
  nom)
    cat > /dev/null
    ;;
  nvd)
    ;;
  dotfiles-wsl-restart-required)
    printf '%s\n' "$TEST_EFFECT"
    ;;
  nixos-rebuild | sudo)
    ;;
  *)
    exit 64
    ;;
esac
STUB
sed -i "1s|@bash@|$bash_path|" "$fake_bin/command-stub"
chmod +x "$fake_bin/command-stub"

for command in git nix nom nvd dotfiles-wsl-restart-required nixos-rebuild sudo; do
  ln -s command-stub "$fake_bin/$command"
done

cat > "$candidate/sw/bin/dotfiles-doctor" <<'DOCTOR'
#!@bash@
set -euo pipefail
printf 'dotfiles-doctor\n' >> "$CALL_LOG"
DOCTOR
sed -i "1s|@bash@|$bash_path|" "$candidate/sw/bin/dotfiles-doctor"
chmod +x "$candidate/sw/bin/dotfiles-doctor"

export CALL_LOG=$call_log
export TEST_SOURCE_PATH=$source_path
export TEST_CANDIDATE=$candidate

run_rebuild() {
  : > "$call_log"
  : > "$stdout_log"
  : > "$stderr_log"
  export TEST_EFFECT=$1
  export TEST_UNTRACKED=${2:-}
  export TEST_FAIL_AT=${3:-}
  shift 3 || true

  set +e
  PATH="$fake_bin:$PATH" bash "$rebuild" "$@" > "$stdout_log" 2> "$stderr_log"
  rebuild_status=$?
  set -e
}

require_call() {
  grep -F -- "$1" "$call_log" > /dev/null || {
    printf 'missing call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  }
}

require_exact_call() {
  grep -Fqx -- "$1" "$call_log" || {
    printf 'missing exact call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  }
}

reject_call() {
  if grep -F -- "$1" "$call_log" > /dev/null; then
    printf 'unexpected call: %s\n' "$1" >&2
    sed 's/^/  /' "$call_log" >&2
    exit 1
  fi
}

call_line() {
  grep -nF -- "$1" "$call_log" | head -n 1 | cut -d: -f1
}

assert_before() {
  local earlier later
  earlier=$(call_line "$1")
  later=$(call_line "$2")
  [[ $earlier -lt $later ]] || {
    printf 'call order is invalid: %s must precede %s\n' "$1" "$2" >&2
    exit 1
  }
}

assert_snapshot_pipeline() {
  require_exact_call "git -C $repo ls-files --others --exclude-standard"
  require_exact_call "nix flake archive --json --no-write-lock-file git+file://$repo"
  require_exact_call "nix flake check --no-write-lock-file --log-format internal-json -v path:$source_path"
  require_exact_call 'nom --json'
  require_exact_call "nix build --no-link --print-out-paths --no-write-lock-file path:$source_path#nixosConfigurations.nixos.config.system.build.toplevel"
  require_exact_call "nvd diff /run/current-system $candidate"
  require_exact_call "dotfiles-wsl-restart-required --plan $candidate"

  [[ $(grep -c '^nix flake archive --json' "$call_log") -eq 1 ]]
  [[ $(grep -c "^nix flake check .*path:$source_path" "$call_log") -eq 1 ]]
  [[ $(grep -c "^nix build .*path:$source_path#nixosConfigurations" "$call_log") -eq 1 ]]

  assert_before "git -C $repo ls-files" 'nix flake archive --json'
  assert_before 'nix flake archive --json' 'nix flake check'
  assert_before 'nix flake check' 'nix build'
  assert_before 'nix build' 'nvd diff'
  assert_before 'nvd diff' 'dotfiles-wsl-restart-required'
}

assert_apply() {
  local action=$1
  require_exact_call "nixos-rebuild $action --sudo --no-reexec --store-path $candidate -L"
  [[ $(grep -c '^nixos-rebuild ' "$call_log") -eq 1 ]]
  reject_call 'sudo nixos-rebuild'
}

require_instruction() {
  grep -F -- "$1" "$stdout_log" > /dev/null || {
    printf 'missing instruction: %s\n' "$1" >&2
    exit 1
  }
}

require_exact_instruction() {
  grep -Fqx -- "$1" "$stdout_log" || {
    printf 'missing exact instruction: %s\n' "$1" >&2
    exit 1
  }
}

reject_instruction() {
  if grep -F -- "$1" "$stdout_log" > /dev/null; then
    printf 'unexpected instruction: %s\n' "$1" >&2
    exit 1
  fi
}

unset DOTFILES_REBUILD_ALLOW_ROOT
: > "$call_log"
: > "$stdout_log"
: > "$stderr_log"
set +e
PATH="$fake_bin:$PATH" "$fakeroot_path" -- "$bash_path" "$rebuild" \
  > "$stdout_log" 2> "$stderr_log"
root_status=$?
set -e
[[ $root_status -eq 2 ]]
[[ ! -s $call_log ]]
grep -F 'run dotfiles-rebuild as the regular user' "$stderr_log" > /dev/null
export DOTFILES_REBUILD_ALLOW_ROOT=1

run_rebuild switch '' ''
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
assert_apply switch
require_call 'dotfiles-doctor'
reject_instruction 'wsl -t NixOS'

run_rebuild switch-restart '' ''
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
assert_apply switch
reject_call 'dotfiles-doctor'
require_exact_instruction '  wsl -t NixOS'
require_exact_instruction '  wsl -d NixOS'
require_instruction 'dotfiles-doctor'
[[ $(grep -Fxc '  wsl -t NixOS' "$stdout_log") -eq 1 ]]

run_rebuild boot-restart '' ''
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
assert_apply boot
reject_call 'dotfiles-doctor'
require_exact_instruction '  wsl -t NixOS'
require_exact_instruction '  wsl -d NixOS'
require_instruction 'dotfiles-doctor'
[[ $(grep -Fxc '  wsl -t NixOS' "$stdout_log") -eq 1 ]]

run_rebuild boot-two-stage '' ''
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
assert_apply boot
reject_call 'dotfiles-doctor'
require_exact_instruction '  wsl -d NixOS --user root exit'
require_exact_instruction '  wsl -d NixOS'
require_instruction 'dotfiles-doctor'
[[ $(grep -Fxc '  wsl -t NixOS' "$stdout_log") -eq 2 ]]

run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'
reject_call 'dotfiles-doctor'

run_rebuild invalid '' ''
[[ $rebuild_status -eq 2 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'
reject_call 'dotfiles-doctor'

run_rebuild switch $'untracked-file\n' ''
[[ $rebuild_status -ne 0 ]]
require_call "git -C $repo ls-files --others --exclude-standard"
reject_call 'nix flake archive'
reject_call 'nix flake check'
reject_call 'nixos-rebuild'

for failure in archive check build nvd helper; do
  run_rebuild switch '' "$failure"
  [[ $rebuild_status -ne 0 ]]
  reject_call 'nixos-rebuild'
  reject_call 'dotfiles-doctor'
done
