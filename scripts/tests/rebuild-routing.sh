#!/usr/bin/env bash
set -euo pipefail

rebuild_source=${1:?rebuild source path is required}
bash_path=${2:?bash path is required}
fakeroot_path=${3:?fakeroot path is required}
operation_lock_source=${4:?operation lock source path is required}
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
sed "s|@dotfilesDir@|$repo|g" "$rebuild_source" \
  | sed "/@operationLockFunctions@/ { r $operation_lock_source
    d
  }" > "$rebuild"
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
    if [[ ${1:-} == -C && ${3:-} == rev-parse ]]; then
      printf '%s\n' "$TEST_COMMON_GIT_DIR"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --name-only ]]; then
      printf '%s' "${TEST_CHANGED_PATHS:-}"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --cached ]]; then
      exit "${TEST_STAGED_STATUS:-0}"
    elif [[ ${1:-} == -C && ${3:-} == diff && ${4:-} == --check ]]; then
      exit "${TEST_DIFF_CHECK_STATUS:-0}"
    else
      printf '%s' "${TEST_UNTRACKED:-}"
    fi
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
export TEST_COMMON_GIT_DIR=$repo/.git

run_rebuild() {
  : > "$call_log"
  : > "$stdout_log"
  : > "$stderr_log"
  export TEST_EFFECT=$1
  export TEST_UNTRACKED=${2:-}
  export TEST_FAIL_AT=${3:-}
  export TEST_CHANGED_PATHS=${TEST_CHANGED_PATHS:-}
  export TEST_STAGED_STATUS=${TEST_STAGED_STATUS:-0}
  export TEST_DIFF_CHECK_STATUS=${TEST_DIFF_CHECK_STATUS:-0}
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
  require_exact_call "git -C $repo rev-parse --path-format=absolute --git-common-dir"
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

  assert_before "git -C $repo rev-parse" "git -C $repo ls-files"
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

lock_target=$test_root/lock-target
printf '%s\n' 'preserve-lock-target' > "$lock_target"
ln -s "$lock_target" "$repo/.git/dotfiles-operation.lock"
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'lock must be a regular file' "$stderr_log" > /dev/null
grep -Fqx 'preserve-lock-target' "$lock_target"
reject_call 'nix flake archive'
rm "$repo/.git/dotfiles-operation.lock"

exec 9> "$repo/.git/dotfiles-operation.lock"
chmod 0600 "$repo/.git/dotfiles-operation.lock"
flock -n 9
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'another dotfiles state transition is running' "$stderr_log" > /dev/null
reject_call 'nix flake archive'
flock -u 9

marker_dir=$repo/.git/dotfiles-sops-enroll
marker=$marker_dir/active.json
mkdir -m 0700 -- "$marker_dir"
cat > "$marker" <<EOF
{"version":2,"transactionId":"0123456789abcdef0123456789abcdef","hostId":"fixture-nixos",
 "worktree":"$repo","phase":"prepared","oldConfigHash":null,"oldSecretsHash":null,
 "newConfigHash":null,"newSecretsHash":null}
EOF
chmod 0600 "$marker"
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'an enrollment transaction blocks normal rebuild' "$stderr_log" > /dev/null
reject_call 'nix flake archive'

mkdir -p -- "$repo/secrets"
printf '%s\n' 'config' > "$repo/secrets/.sops.yaml"
printf '%s\n' 'ciphertext' > "$repo/secrets/secrets.yaml"
config_hash=$(sha256sum "$repo/secrets/.sops.yaml" | cut -d ' ' -f 1)
secrets_hash=$(sha256sum "$repo/secrets/secrets.yaml" | cut -d ' ' -f 1)
jq -n \
  --arg worktree "$repo" \
  --arg configHash "$config_hash" \
  --arg secretsHash "$secrets_hash" '
    {version: 2, transactionId: "0123456789abcdef0123456789abcdef", hostId: "fixture-nixos",
     worktree: $worktree, phase: "generation-pending",
     oldConfigHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
     oldSecretsHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     newConfigHash: $configHash, newSecretsHash: $secretsHash}
  ' > "$marker"
chmod 0600 "$marker"
TEST_CHANGED_PATHS=$'secrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' '' --plan
[[ $rebuild_status -eq 0 ]]
assert_snapshot_pipeline
reject_call 'nixos-rebuild'

TEST_CHANGED_PATHS=$'README.md\nsecrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'only the prepared SOPS files may differ' "$stderr_log" > /dev/null
reject_call 'nix flake archive'

jq '.phase = "generation-checking"' "$marker" > "$marker.tmp"
mv "$marker.tmp" "$marker"
chmod 0600 "$marker"
TEST_CHANGED_PATHS=$'secrets/.sops.yaml\nsecrets/secrets.yaml\n'
run_rebuild switch '' ''
[[ $rebuild_status -ne 0 ]]
grep -F 'an enrollment transaction blocks normal rebuild' "$stderr_log" > /dev/null
reject_call 'nix flake archive'
unset TEST_CHANGED_PATHS
rm -r -- "$marker_dir"

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
