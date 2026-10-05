#!/usr/bin/env bash
set -euo pipefail

bootstrap=${1:?bootstrap script path is required}
test_upstream_rebuild=${2:?test nixos-rebuild package is required}
test_root=$(cd -- "$(mktemp -d)" && pwd -P)
cleanup() {
  local status=$?

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
SOPS_CONFIG="$DOTFILES/secrets/sops/assets/.sops.yaml"
SECRETS_FILE="$DOTFILES/secrets/sops/assets/secrets.json"
AGE_KEY="$test_root/var/lib/sops-nix/key.txt"
TARGET_HOST=tcs-a295
export SUDO_USER
SUDO_USER=$(id -un)
export TOTAL=${#BOOTSTRAP_STAGES[@]}
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

mkdir -p "$DOTFILES/secrets/sops/assets" "$(dirname -- "$AGE_KEY")"
chmod 0700 "$(dirname -- "$AGE_KEY")"
git -C "$DOTFILES" init -q
git -C "$DOTFILES" config user.name 'Bootstrap fixture'
git -C "$DOTFILES" config user.email 'fixture@example.invalid'
touch "$DOTFILES/flake.nix" "$DOTFILES/flake.lock"
age-keygen -o "$AGE_KEY" 2>/dev/null
chmod 0400 "$AGE_KEY"
recipient=$(age-keygen -y "$AGE_KEY")
printf 'creation_rules:\n  - age: %s\n' "$recipient" > "$SOPS_CONFIG"
printf '{"fixture":"bootstrap"}\n' | sops --encrypt --age "$recipient" \
  --input-type json --output-type json /dev/stdin > "$SECRETS_FILE"

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
    "%a:"*) command stat -c "$format" -- "$path" ;;
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
  [[ $1 == --extra-experimental-features && $2 == 'nix-command flakes' ]]
  shift 2
  if [[ $1 == shell ]]; then
    [[ ${SOPS_AGE_KEY_FILE:-} == "$AGE_KEY" ]]
    [[ $* == "shell ${FLAKE_REF}#sops -c sops --config ${SOPS_CONFIG} -d ${SECRETS_FILE}" ]]
    : > "$test_root/sops-verify-called"
    shift 3
    "$@"
  elif [[ $1 == run ]]; then
    printf 'native CLI runtime is unavailable before the first boot\n' >&2
    return 127
  elif [[ $1 == eval ]]; then
    case $* in
      "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.workstation.username")
        printf '%s' "${HOST_USERNAME:-$SUDO_USER}"
        ;;
      "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.workstation.dotfilesDir")
        printf '%s' "${HOST_DOTFILES_DIR:-$DOTFILES}"
        ;;
      "eval --raw --no-write-lock-file ${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.workstation.wsl.distroName")
        [[ ${HOST_DISTRO_NAME:-Fixture Distro} != error ]] || return 1
        printf '%s' "${HOST_DISTRO_NAME:-Fixture Distro}"
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
age-keygen -o "$test_root/wrong-key" 2>/dev/null
if (AGE_KEY="$test_root/wrong-key"; verify_secrets >/dev/null 2>&1); then
  printf 'bootstrap accepted a key that cannot decrypt the enrolled secrets\n' >&2
  exit 1
fi

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

rm "$key_dir"
mv "$real_key_dir" "$key_dir"

git -C "$DOTFILES" add .
git -C "$DOTFILES" commit -qm initial
printf '# enrolled host\n' >> "$SOPS_CONFIG"
SOPS_AGE_KEY_FILE="$AGE_KEY" sops --config "$SOPS_CONFIG" set "$SECRETS_FILE" \
  '["fixture"]' '"enrolled"'
export HOME="$test_root/home"
mkdir -p "$HOME"
ensure_root() { :; }
: > "$bootstrap_call_log"
link_nixos() {
  [[ -s $bootstrap_call_log ]]
  printf '%s\n' "$DOTFILES" > "$test_root/etc-nixos-link"
}
run_bootstrap_stages > "$test_root/bootstrap-stages-output"
[[ $(cat "$test_root/etc-nixos-link") == "$DOTFILES" ]]
[[ -n $(git -C "$DOTFILES" status --porcelain --untracked-files=no) ]]

bootstrap_output=$test_root/bootstrap-output.log
containerless_output=$test_root/bootstrap-containerless-output.log
CONTAINERS_ENABLED=true print_completion > "$bootstrap_output"

dotfiles-install-agents() { :; }
dotfiles-sync-images() { :; }
dotfiles-rebuild() {
  [[ -z $(git status --porcelain --untracked-files=no) ]]
  [[ $(git show --pretty=format: --name-only HEAD | sort) == \
    $'secrets/sops/assets/.sops.yaml\nsecrets/sops/assets/secrets.json' ]]
}
dotfiles-doctor() { :; }
(
  cd "$DOTFILES"
  while IFS= read -r line; do
    case $line in
      '  cd '*|'  git '*|'  dotfiles-'*) eval "${line#  }" ;;
    esac
  done < "$bootstrap_output"
) > "$test_root/continuation-output"

CONTAINERS_ENABLED=false print_completion > "$containerless_output"
if grep -Fxq '  dotfiles-sync-images' "$containerless_output"; then
  printf 'containerless bootstrap requested image synchronization\n' >&2
  exit 1
fi

if (CONTAINERS_ENABLED=error; print_completion >/dev/null 2>&1); then
  printf 'bootstrap ignored a failed container Capability evaluation\n' >&2
  exit 1
fi
if (HOST_DISTRO_NAME=error; print_completion >/dev/null 2>&1); then
  printf 'bootstrap ignored a failed distribution name evaluation\n' >&2
  exit 1
fi
