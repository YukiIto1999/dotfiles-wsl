#!/usr/bin/env bash
set -euo pipefail

bootstrap=${1:?bootstrap script path is required}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# shellcheck source=/dev/null
source "$bootstrap"
trap - ERR

DOTFILES="$test_root/dotfiles-wsl"
SECRETS_FILE="$DOTFILES/secrets/secrets.yaml"
AGE_KEY="$test_root/var/lib/sops-nix/key.txt"
export TOTAL=1
export STEP=0

mkdir -p "$DOTFILES/.git" "$DOTFILES/secrets" "$(dirname -- "$AGE_KEY")"
touch "$DOTFILES/flake.nix" "$DOTFILES/flake.lock" "$SECRETS_FILE" "$AGE_KEY"

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
