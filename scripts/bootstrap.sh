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
  git config --global --add safe.directory "${DOTFILES}" || true

  if [[ -f "${DOTFILES}/.gitmodules" ]]; then
    while read -r path; do
      [[ -n ${path:-} ]] || continue
      git config --global --add safe.directory "${DOTFILES}/${path}" || true
    done < <(as_user git -C "${DOTFILES}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
  fi

  step "git safe.directory registered"
}

verify_tracked_flake_files() {
  local f missing=0
  local -a required=(
    flake.nix
    flake.lock
    .gitmodules
    secrets/secrets.yaml
    secrets/.sops.yaml
    etc/nixos/configuration.nix
    etc/nixos/home.nix
    etc/agentgateway/config.yaml
    templates/account-target.yaml
    templates/agentmemory.yaml
    templates/agent-claude.md
    templates/agent-codex.toml
    templates/agent-opencode.md
    templates/agent-gemini.md
    templates/gh-user.yml
    templates/searxng-settings.yml
    home/nixos/.claude/CLAUDE.md
    home/nixos/.claude/settings.json
    home/nixos/.codex/AGENTS.md
    home/nixos/.codex/config.toml
    home/nixos/.config/opencode/AGENTS.md
    home/nixos/.config/opencode/opencode.json
    home/nixos/.gemini/GEMINI.md
    home/nixos/.gemini/settings.json
    home/nixos/.config/git/ignore
    home/nixos/.config/git/hooks/pre-commit
    home/nixos/.config/git/hooks/commit-msg
    share/AGENTS.md
    services/context7-mcp/default.nix
    services/context7-mcp/package-lock.json
    services/github-mcp/default.nix
    services/probe-mcp/default.nix
    scripts/bootstrap.sh
    scripts/doctor.sh
    scripts/cleanup-local.sh
    scripts/fetch-mcp-info.sh
    scripts/install-ai-clis.sh
    .github/workflows/check.yml
  )

  for f in "${required[@]}"; do
    if ! as_user git -C "${DOTFILES}" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      echo "untracked required file: $f" >&2
      missing=1
    fi
  done
  [[ ${missing} -eq 0 ]] || die "stage required files before running bootstrap: git add <files>"
  step "required flake files are tracked"
}

list_sparse_specs() {
  as_user git -C "${DOTFILES}" config -f .gitmodules --get-regexp '\.sparse-checkout$' || true
}

apply_sparse() {
  local key patterns name path abs
  while read -r key patterns; do
    [[ -n ${key:-} ]] || continue
    name=${key%.sparse-checkout}
    name=${name#submodule.}
    path=$(as_user git -C "${DOTFILES}" config -f .gitmodules --get "submodule.${name}.path")
    abs=$(readlink -m "${DOTFILES}/${path}")
    [[ ${abs} == "${DOTFILES}/upstream/"* ]] \
      || die "submodule path escapes \$DOTFILES/upstream/: ${path}"
    # shellcheck disable=SC2086
    as_user git -C "${abs}" sparse-checkout set -- ${patterns}
  done
}

sync_submodules() {
  as_user git -C "${DOTFILES}" submodule update --init --recursive
  set -f
  list_sparse_specs | apply_sparse
  set +f
  step "submodules synced + sparse-checkout applied"
}

verify_secrets() {
  SOPS_AGE_KEY_FILE="${AGE_KEY}" \
    nix shell "${FLAKE_REF}#sops" -c sops -d "${SECRETS_FILE}" >/dev/null \
    || die "${AGE_KEY} cannot decrypt ${SECRETS_FILE}"
  step "secrets decryption verified"
}

install_ai_clis() {
  as_user nix shell "${FLAKE_REF}#ai-cli-install-tools" -c "${DOTFILES}/scripts/install-ai-clis.sh"
  step "Claude Code / Codex CLI installed from upstream"
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
  local -r FLAKE_REF="git+file://${DOTFILES}?submodules=1"
  local -ra stages=(
    register_safe_directories
    preflight
    verify_tracked_flake_files
    sync_submodules
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
