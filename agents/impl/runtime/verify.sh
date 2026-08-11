set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verify -- COMMAND [ARG...]\n' >&2
  exit 64
}

if [ "${1-}" = -- ]; then
  shift
fi
test "$#" -gt 0 || usage

if ! repo_top=$(git rev-parse --show-toplevel 2>/dev/null) \
  || ! common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || ! repo_top=$(realpath -e -- "$repo_top") \
  || ! common_dir=$(realpath -e -- "$common_dir"); then
  exec "$@"
fi

project_id=$(printf '%s' "$common_dir" | sha256sum | cut -d ' ' -f 1)
verification_root="$HOME/@cacheRootRelative@/verification"
project_state="$verification_root/$project_id"
mkdir -p "$HOME/.cache"

ensure_state_directory() {
  local path=$1
  if mkdir -m 700 "$path" 2>/dev/null; then
    return
  fi
  test ! -L "$path" || return 1
  test -d "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 700 "$path" || return 1
  test "$(stat -c %a "$path")" = 700
}

prepare_success_file() {
  local path=$1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  test ! -L "$path" || return 1
  test -f "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 600 "$path" || return 1
  test "$(stat -c %a "$path")" = 600
}

if ! ensure_state_directory "$HOME/@cacheRootRelative@" \
  || ! ensure_state_directory "$verification_root" \
  || ! ensure_state_directory "$project_state"; then
  exec "$@"
fi

scratch=$(mktemp -d "$verification_root/.fingerprint.XXXXXXXX")
# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$scratch" == "$verification_root/"* ]] && [ ! -L "$scratch" ] && [ -d "$scratch" ]; then
    rm -rf --one-file-system -- "$scratch" || true
  fi
  exit "$status"
}
trap cleanup EXIT

write_command_identity() {
  local executable
  if [[ "$1" == */* ]]; then
    executable=$1
  else
    executable=$(command -v -- "$1" 2>/dev/null) || return 1
  fi

  if [ -f "$executable" ]; then
    executable=$(realpath -e -- "$executable") || return 1
    printf 'executable-path\0%s\0executable-content\0' "$executable"
    sha256sum -- "$executable"
  else
    printf 'shell-command\0%s\0bash-version\0%s\0' "$executable" "$BASH_VERSION"
  fi
}

fingerprint() {
  local untracked=$scratch/untracked path mode relative_cwd head link_target
  head=$(git -C "$repo_top" rev-parse --verify HEAD 2>/dev/null) || return 1
  relative_cwd=$(realpath --relative-to "$repo_top" "$(pwd -P)") || return 1
  git -C "$repo_top" ls-files --others --exclude-standard -z > "$untracked" || return 1

  {
    printf 'dotfiles-agent-verify-v1\0common-dir\0%s\0repo-head\0%s\0cwd\0%s\0' \
      "$common_dir" "$head" "$relative_cwd"
    printf 'tracked-diff\0'
    git -C "$repo_top" -c color.ui=false diff \
      --binary --full-index --no-ext-diff --no-textconv HEAD -- || return 1
    printf '\0untracked\0'
    while IFS= read -r -d '' path; do
      printf 'path\0%s\0' "$path"
      if [ -L "$repo_top/$path" ]; then
        link_target=$(readlink -- "$repo_top/$path") || return 1
        printf 'symlink\0%s\0' "$link_target"
      elif [ -f "$repo_top/$path" ]; then
        mode=$(stat -c %a "$repo_top/$path") || return 1
        printf 'regular\0%s\0' "$mode"
        sha256sum -- "$repo_top/$path" || return 1
      else
        return 1
      fi
    done < "$untracked"
    printf 'argv\0'
    printf '%s\0' "$@"
    write_command_identity "$1" || return 1
    printf 'environment\0'
    env -0 | LC_ALL=C sort -z || return 1
  } | sha256sum | cut -d ' ' -f 1
}

if ! before=$(fingerprint "$@"); then
  trap - EXIT
  rm -rf --one-file-system -- "$scratch"
  exec "$@"
fi

success_file="$project_state/$before.success"
expected_record=$(printf 'version=1\nfingerprint=%s\n' "$before")
success_file_is_safe=false
if prepare_success_file "$success_file"; then
  success_file_is_safe=true
fi
if [ "$success_file_is_safe" = true ] \
  && [ ! -L "$success_file" ] \
  && [ -f "$success_file" ] \
  && [ "$(stat -c %u "$success_file")" = "$(id -u)" ] \
  && [ "$(cat "$success_file")" = "$expected_record" ]; then
  exit 0
fi

set +e
"$@"
status=$?
set -e

if [ "$status" -eq 0 ] \
  && [ "$success_file_is_safe" = true ] \
  && after=$(fingerprint "$@") \
  && [ "$before" = "$after" ] \
  && prepare_success_file "$success_file"; then
  record_tmp=$(mktemp "$project_state/.success.XXXXXXXX")
  printf '%s' "$expected_record" > "$record_tmp"
  chmod 600 "$record_tmp"
  mv -T "$record_tmp" "$success_file" || rm -f -- "$record_tmp"
fi

exit "$status"
