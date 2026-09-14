#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true


die()     { trap - ERR; echo "FATAL: $*" >&2; exit 1; }
as_user() { sudo -u "${SUDO_USER}" "$@"; }
step()    { printf '[%d/%d] %s\n' "$((++STEP))" "${TOTAL}" "$*"; }

parse_target_host() {
  [[ $# -eq 2 && $1 == --host ]] || return 2
  [[ $2 =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || return 2
  printf '%s\n' "$2"
}

container_sync_required() {
  nix eval --raw --no-write-lock-file \
    "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.platform.containers.enabled" \
    --apply 'containers: if containers == [ ] then "false" else "true"'
}

print_completion() {
  local sync_required
  local sync_command=""

  sync_required=$(container_sync_required) \
    || die "failed to evaluate container Capability selection for ${TARGET_HOST}"
  if [[ ${sync_required} == true ]]; then
    sync_command=$'  dotfiles-sync-images\n'
  fi

  cat <<MSG

Bootstrap completed.

Restart this WSL distribution from PowerShell:

  wsl -t NixOS
  wsl -d NixOS

Then run:

${sync_command}  dotfiles-rebuild
  dotfiles-doctor

MSG
}

trap 'die "line ${LINENO}: ${BASH_COMMAND}"' ERR

ensure_root() {
  [[ ${EUID} -eq 0 ]]     || die "run as root (sudo bash bootstrap/impl/bootstrap.sh)"
  [[ -n ${SUDO_USER:-} ]] || die "SUDO_USER must be set (invoke via sudo from nixos)"
  [[ ${SUDO_USER} == "${TARGET_USER}" ]] || die "run via sudo from ${TARGET_USER}; current SUDO_USER=${SUDO_USER}"
}

preflight() {
  local f key_dir
  for f in \
    "${DOTFILES}/flake.nix" \
    "${DOTFILES}/flake.lock" \
    "${SOPS_CONFIG}" \
    "${SECRETS_FILE}" \
    "${AGE_KEY}"; do
    [[ -f ${f} ]] || die "${f} not found"
  done
  [[ -d ${DOTFILES}/.git ]] || die "${DOTFILES} is not a git repository"

  key_dir=$(dirname -- "${AGE_KEY}")
  [[ -d ${key_dir} && ! -L ${key_dir} ]] \
    || die "${key_dir} must be a directory, not a symlink"
  [[ ! -L ${AGE_KEY} ]] || die "${AGE_KEY} must not be a symlink"
  [[ $(stat -c '%u:%g' -- "${key_dir}") == 0:0 ]] \
    || die "${key_dir} must be owned by root:root"
  [[ $(stat -c '%a' -- "${key_dir}") == 700 ]] \
    || die "${key_dir} must have mode 0700"
  [[ $(stat -c '%u:%g' -- "${AGE_KEY}") == 0:0 ]] \
    || die "${AGE_KEY} must be owned by root:root"
  [[ $(stat -c '%a' -- "${AGE_KEY}") == 400 ]] \
    || die "${AGE_KEY} must have mode 0400"
  step "preflight complete"
}

register_safe_directories() {
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${DOTFILES}" \
    || git config --global --add safe.directory "${DOTFILES}"
  step "git safe.directory registered"
}

verify_tracked_flake_files() {
  # git+file の flake build では未追跡ファイルが見えない
  local untracked
  untracked=$(as_user git -C "${DOTFILES}" ls-files --others --exclude-standard)
  if [[ -n ${untracked} ]]; then
    printf '%s\n' "${untracked}" >&2
    die "untracked files block the flake build; git add them"
  fi
  step "no untracked files in flake tree"
}

verify_secrets() {
  SOPS_AGE_KEY_FILE="${AGE_KEY}" \
    nix shell "${FLAKE_REF}#sops" -c sops --config "${SOPS_CONFIG}" -d "${SECRETS_FILE}" >/dev/null \
    || die "${AGE_KEY} cannot decrypt ${SECRETS_FILE}"
  step "secrets decryption verified"
}

install_agent_clients() {
  as_user nix run "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.dotfiles.platform.cli.commands.installAgents"
  step "agent clients installed from upstream"
}

install_boot_generation() {
  local upstream_rebuild
  upstream_rebuild=$(nix build --no-link --print-out-paths --no-write-lock-file \
    "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.system.build.nixos-rebuild")
  [[ ${upstream_rebuild} != *$'\n'* && ${upstream_rebuild} == /nix/store/* &&
    -x ${upstream_rebuild}/bin/nixos-rebuild ]] \
    || die "failed to resolve the pinned nixos-rebuild"
  "${upstream_rebuild}/bin/nixos-rebuild" boot --no-reexec --flake "${FLAKE_REF}#${TARGET_HOST}" -L
  step "nixos-rebuild boot complete"
}

link_nixos() {
  local -r target=/etc/nixos
  local current=""
  local bak=""

  if [[ -L ${target} ]]; then
    current=$(readlink -f "${target}" || true)
    if [[ ${current} != "${DOTFILES}" ]]; then
      bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
      mv "${target}" "${bak}"
      echo "  moved existing ${target} symlink -> ${bak}"
    fi
  elif [[ -e ${target} ]]; then
    bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
    mv "${target}" "${bak}"
    echo "  moved existing ${target} -> ${bak}"
  fi

  ln -sfn "${DOTFILES}" "${target}"
  step "${target} -> ${DOTFILES}"
}

run_bootstrap_stages() {
  local stage

  ensure_root
  for stage in "${BOOTSTRAP_STAGES[@]}"; do
    "${stage}"
  done
}

declare -ar BOOTSTRAP_STAGES=(
  register_safe_directories
  preflight
  verify_tracked_flake_files
  verify_secrets
  install_agent_clients
  install_boot_generation
  link_nixos
)

main() {
  local TARGET_HOST
  TARGET_HOST=$(parse_target_host "$@") \
    || die "usage: sudo bash workstation/activation/rebuild/impl/bootstrap.sh --host <host-id>"
  readonly TARGET_HOST
  # config 生成前に実行するため dotfiles.workstation.username を参照できない。既定値と同じ "nixos" を使う
  local -r TARGET_USER="nixos"
  local -r USER_HOME="/home/${TARGET_USER}"
  local -r DOTFILES="${USER_HOME}/dotfiles-wsl"
  local -r SOPS_CONFIG="${DOTFILES}/secrets/sops/assets/.sops.yaml"
  local -r SECRETS_FILE="${DOTFILES}/secrets/sops/assets/secrets.json"
  local -r AGE_KEY="/var/lib/sops-nix/key.txt"
  local -r FLAKE_REF="git+file://${DOTFILES}"
  local -r TOTAL=${#BOOTSTRAP_STAGES[@]}
  local STEP=0

  run_bootstrap_stages

  print_completion
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
