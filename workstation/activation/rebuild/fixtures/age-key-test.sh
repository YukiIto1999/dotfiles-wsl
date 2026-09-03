#!/usr/bin/env bash
set -euo pipefail

bootstrap=${1:?bootstrap script path is required}
test_upstream_rebuild=${2:?test nixos-rebuild package is required}
test_root=$(mktemp -d)
bootstrap_pid=
bootstrap_rebuild_release=
cleanup() {
  local status=$?

  if [[ -n ${bootstrap_rebuild_release} ]]; then
    : > "$bootstrap_rebuild_release"
  fi
  if [[ -n ${bootstrap_pid} ]]; then
    kill "$bootstrap_pid" 2>/dev/null || true
    wait "$bootstrap_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$bootstrap"
trap - ERR

DOTFILES="$test_root/dotfiles-wsl"
SOPS_CONFIG="$DOTFILES/sops/assets/.sops.yaml"
SECRETS_FILE="$DOTFILES/sops/assets/secrets.yaml"
AGE_KEY="$test_root/var/lib/sops-nix/key.txt"
export SUDO_USER
SUDO_USER=$(id -un)
export TOTAL=2
export STEP=0

mkdir -p "$DOTFILES/sops/assets" "$(dirname -- "$AGE_KEY")"
git -C "$DOTFILES" init -q
touch "$DOTFILES/flake.nix" "$DOTFILES/flake.lock" "$SOPS_CONFIG" "$SECRETS_FILE" "$AGE_KEY"

as_user() {
  "$@"
}


STAT_PROFILE=valid
stat() {
  local format path
  [[ $1 == -c ]]
  format=$2
  shift 2
  [[ ${1:-} == -- ]] && shift
  path=$1

  case "$format:$path:$STAT_PROFILE" in
    "%u:%g:$(dirname -- "$AGE_KEY"):bad-dir-owner") printf '%s\n' 1000:100 ;;
    "%a:$(dirname -- "$AGE_KEY"):bad-dir-mode") printf '%s\n' 755 ;;
    "%u:%g:$AGE_KEY:bad-key-owner") printf '%s\n' 1000:100 ;;
    "%a:$AGE_KEY:bad-key-mode") printf '%s\n' 600 ;;
    "%u:%g:"*) printf '%s\n' 0:0 ;;
    "%a:$(dirname -- "$AGE_KEY"):"*) printf '%s\n' 700 ;;
    "%a:$AGE_KEY:"*) printf '%s\n' 400 ;;
    *) return 1 ;;
  esac
}

preflight >/dev/null

mv "$SOPS_CONFIG" "$SOPS_CONFIG.missing"
if (preflight >/dev/null 2>&1); then
  printf 'preflight accepted a missing SOPS config\n' >&2
  exit 1
fi
mv "$SOPS_CONFIG.missing" "$SOPS_CONFIG"

for profile in bad-dir-owner bad-dir-mode bad-key-owner bad-key-mode; do
  if (STAT_PROFILE=$profile; preflight >/dev/null 2>&1); then
    printf 'preflight accepted invalid profile: %s\n' "$profile" >&2
    exit 1
  fi
done

bootstrap_call_log=$test_root/bootstrap-calls.log
export BOOTSTRAP_CALL_LOG=$bootstrap_call_log
FLAKE_REF="git+file://$DOTFILES"
nix() {
  if [[ $1 == shell ]]; then
    [[ ${SOPS_AGE_KEY_FILE:-} == "$AGE_KEY" ]]
    [[ $* == "shell ${FLAKE_REF}#sops -c sops --config ${SOPS_CONFIG} -d ${SECRETS_FILE}" ]]
    : > "$test_root/sops-verify-called"
  else
    [[ $* == "build --no-link --print-out-paths --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.nixos.config.system.build.nixos-rebuild" ]]
    printf '%s\n' "$test_upstream_rebuild"
  fi
}
verify_secrets
[[ -e $test_root/sops-verify-called ]]
install_boot_generation >/dev/null
grep -Fqx "boot --no-reexec --flake ${FLAKE_REF}#nixos -L " "$bootstrap_call_log"

real_key="$AGE_KEY.real"
mv "$AGE_KEY" "$real_key"
ln -s "$real_key" "$AGE_KEY"
if (preflight >/dev/null 2>&1); then
  printf 'preflight accepted a symlinked age key\n' >&2
  exit 1
fi
rm "$AGE_KEY"
mv "$real_key" "$AGE_KEY"

key_dir=$(dirname -- "$AGE_KEY")
real_key_dir="$key_dir.real"
mv "$key_dir" "$real_key_dir"
ln -s "$real_key_dir" "$key_dir"
if (preflight >/dev/null 2>&1); then
  printf 'preflight accepted a symlinked age key directory\n' >&2
  exit 1
fi

# main と同じ stage runner が operation lock を activation 完了まで保持する。
[[ -z ${DOTFILES_OPERATION_DIRECTORY_LOCK_FD:-} &&
  -z ${DOTFILES_OPERATION_LEGACY_LOCK_FD:-} ]]
bootstrap_stage_log=$test_root/bootstrap-stages.log
bootstrap_rebuild_ready=$test_root/bootstrap-rebuild.ready
bootstrap_rebuild_release=$test_root/bootstrap-rebuild.release
export BOOTSTRAP_REBUILD_READY=$bootstrap_rebuild_ready
export BOOTSTRAP_REBUILD_RELEASE=$bootstrap_rebuild_release

record_bootstrap_stage() {
  printf '%s\n' "$1" >> "$bootstrap_stage_log"
}
ensure_root() { record_bootstrap_stage ensure_root; }
register_safe_directories() { record_bootstrap_stage register_safe_directories; }
preflight() { record_bootstrap_stage preflight; }
verify_tracked_flake_files() { record_bootstrap_stage verify_tracked_flake_files; }
verify_secrets() { record_bootstrap_stage verify_secrets; }
install_agent_clients() { record_bootstrap_stage install_agent_clients; }
install_boot_generation() {
  record_bootstrap_stage install_boot_generation
  "$test_upstream_rebuild/bin/nixos-rebuild" boot --no-reexec --flake "${FLAKE_REF}#nixos" -L
}
link_nixos() { record_bootstrap_stage link_nixos; }

run_bootstrap_stages >/dev/null &
bootstrap_pid=$!
for _ in {1..500}; do
  [[ -e $bootstrap_rebuild_ready ]] && break
  kill -0 "$bootstrap_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -e $bootstrap_rebuild_ready ]]
: > "$bootstrap_rebuild_release"
wait "$bootstrap_pid"
bootstrap_pid=
printf '%s\n' ensure_root "${BOOTSTRAP_STAGES[@]}" > "$test_root/expected-bootstrap-stages.log"
cmp "$test_root/expected-bootstrap-stages.log" "$bootstrap_stage_log"

# bootstrap は初回 boot 後の収束順を一つの continuation として表示する。
bootstrap_output=$test_root/bootstrap-output.log
run_bootstrap_stages() { :; }
main > "$bootstrap_output"
terminate_line=$(grep -nFx '  wsl -t NixOS' "$bootstrap_output" | cut -d: -f1)
launch_line=$(grep -nFx '  wsl -d NixOS' "$bootstrap_output" | cut -d: -f1)
sync_line=$(grep -nFx '  dotfiles-sync-images' "$bootstrap_output" | cut -d: -f1)
rebuild_line=$(grep -nFx '  dotfiles-rebuild' "$bootstrap_output" | cut -d: -f1)
doctor_line=$(grep -nFx '  dotfiles-doctor' "$bootstrap_output" | cut -d: -f1)
[[ $terminate_line -lt $launch_line && $launch_line -lt $sync_line &&
  $sync_line -lt $rebuild_line && $rebuild_line -lt $doctor_line ]]
