#!/usr/bin/env bash
set -euo pipefail

bootstrap=${1:?bootstrap script path is required}
test_upstream_rebuild=${2:?test nixos-rebuild package is required}
test_root=$(cd -- "$(mktemp -d)" && pwd -P)
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

DOTFILES="$test_root/dotfiles-wsl"
# bootstrap は自分の置き場所から checkout を決めるので、checkout 内と同じ配置で読み込む
checkout_bootstrap="$DOTFILES/workstation/activation/rebuild/impl/bootstrap.sh"
mkdir -p "$(dirname -- "$checkout_bootstrap")"
cp -- "$bootstrap" "$checkout_bootstrap"

# shellcheck source=/dev/null
source "$checkout_bootstrap"
trap - ERR

[[ $(checkout_root "$checkout_bootstrap") == "$DOTFILES" ]]
SOPS_CONFIG="$DOTFILES/sops/assets/.sops.yaml"
SECRETS_FILE="$DOTFILES/sops/assets/secrets.json"
AGE_KEY="$test_root/var/lib/sops-nix/key.txt"
TARGET_HOST=tcs-a295
export SUDO_USER
SUDO_USER=$(id -un)
export TOTAL=2
export STEP=0

[[ $(parse_target_host --host "$TARGET_HOST") == "$TARGET_HOST" ]]
if parse_target_host --host TCS-A295 >/dev/null 2>&1; then
  printf 'bootstrap accepted an invalid host name\n' >&2
  exit 1
fi
if parse_target_host "$TARGET_HOST" >/dev/null 2>&1; then
  printf 'bootstrap accepted a positional host name\n' >&2
  exit 1
fi

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
  elif [[ $1 == run ]]; then
    [[ $* == "run ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.platform.cli.commands.installAgents" ]]
    : > "$test_root/install-agents-called"
  elif [[ $1 == eval ]]; then
    case $* in
      "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.workstation.username")
        printf '%s' "${HOST_USERNAME:-$SUDO_USER}"
        ;;
      "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.workstation.dotfilesDir")
        printf '%s' "${HOST_DOTFILES_DIR:-$DOTFILES}"
        ;;
      *)
        [[ $* == "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.platform.containers.enabled --apply containers: if containers == [ ] then \"false\" else \"true\"" ]]
        [[ ${CONTAINERS_ENABLED:-true} != error ]] || return 1
        printf '%s\n' "${CONTAINERS_ENABLED:-true}"
        ;;
    esac
  else
    [[ $* == "build --no-link --print-out-paths --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.system.build.nixos-rebuild" ]]
    printf '%s\n' "$test_upstream_rebuild"
  fi
}
verify_secrets
[[ -e $test_root/sops-verify-called ]]
install_agent_clients >/dev/null
[[ -e $test_root/install-agents-called ]]
install_boot_generation >/dev/null
grep -Fqx "boot --no-reexec --flake ${FLAKE_REF}#${TARGET_HOST} -L " "$bootstrap_call_log"

verify_host_identity >/dev/null
if (HOST_USERNAME=someone-else; verify_host_identity >/dev/null 2>&1); then
  printf 'bootstrap accepted a sudo user that the host does not declare\n' >&2
  exit 1
fi
if (HOST_DOTFILES_DIR=$test_root/elsewhere; verify_host_identity >/dev/null 2>&1); then
  printf 'bootstrap accepted a checkout outside the declared path\n' >&2
  exit 1
fi

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

# main と同じ stage runner が、宣言した順に全 stage を実行する。
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
verify_host_identity() { record_bootstrap_stage verify_host_identity; }
preflight() { record_bootstrap_stage preflight; }
verify_tracked_flake_files() { record_bootstrap_stage verify_tracked_flake_files; }
verify_secrets() { record_bootstrap_stage verify_secrets; }
install_agent_clients() { record_bootstrap_stage install_agent_clients; }
install_boot_generation() {
  record_bootstrap_stage install_boot_generation
  "$test_upstream_rebuild/bin/nixos-rebuild" boot --no-reexec --flake "${FLAKE_REF}#${TARGET_HOST}" -L
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
containerless_output=$test_root/bootstrap-containerless-output.log
run_bootstrap_stages() { :; }

CONTAINERS_ENABLED=true main --host "$TARGET_HOST" > "$bootstrap_output"
terminate_line=$(grep -nFx '  wsl -t NixOS' "$bootstrap_output" | cut -d: -f1)
launch_line=$(grep -nFx '  wsl -d NixOS' "$bootstrap_output" | cut -d: -f1)
sync_line=$(grep -nFx '  dotfiles-sync-images' "$bootstrap_output" | cut -d: -f1)
rebuild_line=$(grep -nFx '  dotfiles-rebuild' "$bootstrap_output" | cut -d: -f1)
doctor_line=$(grep -nFx '  dotfiles-doctor' "$bootstrap_output" | cut -d: -f1)
[[ $terminate_line -lt $launch_line && $launch_line -lt $sync_line &&
  $sync_line -lt $rebuild_line && $rebuild_line -lt $doctor_line ]]

CONTAINERS_ENABLED=false main --host "$TARGET_HOST" > "$containerless_output"
if grep -Fxq '  dotfiles-sync-images' "$containerless_output"; then
  printf 'containerless bootstrap requested image synchronization\n' >&2
  exit 1
fi
launch_line=$(grep -nFx '  wsl -d NixOS' "$containerless_output" | cut -d: -f1)
rebuild_line=$(grep -nFx '  dotfiles-rebuild' "$containerless_output" | cut -d: -f1)
doctor_line=$(grep -nFx '  dotfiles-doctor' "$containerless_output" | cut -d: -f1)
[[ $launch_line -lt $rebuild_line && $rebuild_line -lt $doctor_line ]]

if (CONTAINERS_ENABLED=error; print_completion >/dev/null 2>&1); then
  printf 'bootstrap ignored a failed container Capability evaluation\n' >&2
  exit 1
fi
