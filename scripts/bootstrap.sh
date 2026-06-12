#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

die()     { trap - ERR; echo "FATAL: $*" >&2; exit 1; }
as_user() { sudo -u "${SUDO_USER}" "$@"; }
step()    { printf '[%d/%d] %s\n' "$((++STEP))" "${TOTAL}" "$*"; }

trap 'die "line ${LINENO}: ${BASH_COMMAND}"' ERR

ensure_root() {
  [[ ${EUID} -eq 0 ]]     || die "run as root (sudo bash scripts/bootstrap.sh)"
  [[ -n ${SUDO_USER:-} ]] || die "SUDO_USER must be set (invoke via sudo from nixos)"
  [[ ${SUDO_USER} == "${TARGET_USER}" ]] || die "run via sudo from ${TARGET_USER}; current SUDO_USER=${SUDO_USER}"
}

preflight() {
  local f
  for f in "${DOTFILES}/flake.nix" "${DOTFILES}/flake.lock" "${SECRETS_FILE}" "${AGE_KEY}"; do
    [[ -f ${f} ]] || die "${f} not found"
  done
  [[ -d ${DOTFILES}/.git ]] || die "${DOTFILES} is not a git repository"
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
    nix shell "${FLAKE_REF}#sops" -c sops -d "${SECRETS_FILE}" >/dev/null \
    || die "${AGE_KEY} cannot decrypt ${SECRETS_FILE}"
  step "secrets decryption verified"
}

install_ai_clis() {
  as_user nix shell "${FLAKE_REF}#ai-cli-install-tools" -c "${DOTFILES}/scripts/install-ai-clis.sh"
  step "AI CLIs installed from upstream"
}

install_boot_generation() {
  nixos-rebuild boot --flake "${FLAKE_REF}#nixos" -L
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

main() {
  local -r TARGET_USER="nixos"
  local -r USER_HOME="/home/${TARGET_USER}"
  local -r DOTFILES="${USER_HOME}/dotfiles-wsl"
  local -r SECRETS_FILE="${DOTFILES}/secrets/secrets.yaml"
  local -r AGE_KEY="/var/lib/sops-nix/key.txt"
  local -r FLAKE_REF="git+file://${DOTFILES}"
  local -ra stages=(
    register_safe_directories
    preflight
    verify_tracked_flake_files
    verify_secrets
    install_ai_clis
    install_boot_generation
    link_nixos
  )
  local -r TOTAL=${#stages[@]}
  local STEP=0

  ensure_root

  local stage
  for stage in "${stages[@]}"; do
    "${stage}"
  done

  cat <<MSG

Bootstrap completed.

Restart this WSL distribution from PowerShell:

  wsl -t NixOS
  wsl -d NixOS

Then run:

  ~/dotfiles-wsl/scripts/doctor.sh

MSG
}

main "$@"
