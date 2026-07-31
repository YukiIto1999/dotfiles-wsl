#!/usr/bin/env bash
set -euo pipefail

if (( EUID == 0 )); then
  echo 'dotfiles-sops-verifier refuses to parse ciphertext as root' >&2
  exit 1
fi
[[ -n ${CREDENTIALS_DIRECTORY:-} ]] || {
  echo 'dotfiles-sops-verifier requires a systemd credential directory' >&2
  exit 1
}
identity=$CREDENTIALS_DIRECTORY/age.key
[[ ! -L $identity && -f $identity && -r $identity ]] || {
  echo 'dotfiles-sops-verifier cannot read the age credential' >&2
  exit 1
}

env -i \
  HOME=/var/empty \
  PATH=@sopsRuntimePath@ \
  SOPS_AGE_KEY_FILE="$identity" \
  sops decrypt \
    --input-type yaml \
    --filename-override secrets.yaml >/dev/null
