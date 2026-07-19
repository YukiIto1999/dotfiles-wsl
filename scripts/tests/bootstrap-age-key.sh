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
SECRETS_FILE="$DOTFILES/secrets/secrets.yaml"
AGE_KEY="$test_root/var/lib/sops-nix/key.txt"
export SUDO_USER
SUDO_USER=$(id -un)
export TOTAL=2
export STEP=0

mkdir -p "$DOTFILES/secrets" "$(dirname -- "$AGE_KEY")"
git -C "$DOTFILES" init -q
touch "$DOTFILES/flake.nix" "$DOTFILES/flake.lock" "$SECRETS_FILE" "$AGE_KEY"

as_user() {
  "$@"
}

operation_lock=$DOTFILES/.git/dotfiles-operation.lock
lock_target=$test_root/lock-target
printf '%s\n' 'preserve-lock-target' > "$lock_target"
ln -s "$lock_target" "$operation_lock"
if (acquire_operation_lock >/dev/null 2>&1); then
  echo 'bootstrap accepted a symlinked operation lock' >&2
  exit 1
fi
grep -Fqx 'preserve-lock-target' "$lock_target"
rm "$operation_lock"

exec 9> "$operation_lock"
chmod 0600 "$operation_lock"
flock -n 9
if (acquire_operation_lock >/dev/null 2>&1); then
  echo 'bootstrap ignored the shared dotfiles operation lock' >&2
  exit 1
fi
flock -u 9
acquire_operation_lock >/dev/null

mkdir -p -- "$DOTFILES/.git/dotfiles-sops-enroll"
touch "$DOTFILES/.git/dotfiles-sops-enroll/active.json"
if (reject_active_enrollment >/dev/null 2>&1); then
  echo 'bootstrap ignored an active SOPS enrollment transaction' >&2
  exit 1
fi
rm -r -- "$DOTFILES/.git/dotfiles-sops-enroll"
reject_active_enrollment >/dev/null

mkdir -p -- "$DOTFILES/.git/dotfiles-rebuild"
touch "$DOTFILES/.git/dotfiles-rebuild/active.json"
if (reject_active_rebuild >/dev/null 2>&1); then
  echo 'bootstrap ignored an active rebuild transaction' >&2
  exit 1
fi
rm -r -- "$DOTFILES/.git/dotfiles-rebuild"
reject_active_rebuild >/dev/null

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
  [[ $* == "build --no-link --print-out-paths --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.nixos.config.system.build.nixos-rebuild" ]]
  printf '%s\n' "$test_upstream_rebuild"
}
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
exec {DOTFILES_OPERATION_LOCK_FD}>&-
bootstrap_stage_log=$test_root/bootstrap-stages.log
bootstrap_rebuild_ready=$test_root/bootstrap-rebuild.ready
bootstrap_rebuild_release=$test_root/bootstrap-rebuild.release
export BOOTSTRAP_REBUILD_READY=$bootstrap_rebuild_ready
export BOOTSTRAP_REBUILD_RELEASE=$bootstrap_rebuild_release

eval "$(declare -f acquire_operation_lock | sed '1s/acquire_operation_lock/production_acquire_operation_lock/')"
record_bootstrap_stage() {
  printf '%s\n' "$1" >> "$bootstrap_stage_log"
}
ensure_root() { record_bootstrap_stage ensure_root; }
acquire_operation_lock() {
  record_bootstrap_stage acquire_operation_lock
  unset -f stat
  production_acquire_operation_lock >/dev/null
}
reject_active_enrollment() { record_bootstrap_stage reject_active_enrollment; }
reject_active_rebuild() { record_bootstrap_stage reject_active_rebuild; }
register_safe_directories() { record_bootstrap_stage register_safe_directories; }
preflight() { record_bootstrap_stage preflight; }
verify_tracked_flake_files() { record_bootstrap_stage verify_tracked_flake_files; }
verify_secrets() { record_bootstrap_stage verify_secrets; }
install_ai_clis() { record_bootstrap_stage install_ai_clis; }
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
if (exec 8< "$operation_lock"; flock -n 8); then
  echo 'bootstrap released the operation lock before activation completed' >&2
  exit 1
fi
: > "$bootstrap_rebuild_release"
wait "$bootstrap_pid"
bootstrap_pid=
(exec 8< "$operation_lock"; flock -n 8)
printf '%s\n' ensure_root "${BOOTSTRAP_STAGES[@]}" > "$test_root/expected-bootstrap-stages.log"
cmp "$test_root/expected-bootstrap-stages.log" "$bootstrap_stage_log"
