set -euo pipefail

die() {
  printf 'dotfiles-agent-runtime: %s\n' "$1" >&2
  exit 70
}

ensure_managed_directory() {
  local path=$1

  if ! mkdir -m 700 "$path" 2>/dev/null; then
    test ! -L "$path" || die "managed path is a symlink: $path"
    test -d "$path" || die "managed path is not a directory: $path"
    test "$(stat -c %u "$path")" = "$(id -u)" || die "managed path has another owner: $path"
  fi

  chmod 700 "$path" || die "cannot secure managed directory: $path"
  test "$(stat -c %a "$path")" = 700 || die "managed directory mode is not 0700: $path"
}

secure_managed_file() {
  local path=$1 description=$2
  test ! -L "$path" || die "$description is a symlink: $path"
  test -f "$path" || die "$description is not a regular file: $path"
  test "$(stat -c %u "$path")" = "$(id -u)" || die "$description has another owner: $path"
  chmod 600 "$path" || die "cannot secure $description: $path"
  test "$(stat -c %a "$path")" = 600 || die "$description mode is not 0600: $path"
}

project_identity() {
  local common_dir

  if common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    realpath -e -- "$common_dir"
  else
    pwd -P
  fi
}

project_has_cargo_target_dir() {
  local directory config_file
  directory=$(pwd -P)

  while :; do
    for config_file in "$directory/.cargo/config.toml" "$directory/.cargo/config"; do
      if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then
        continue
      fi

      # Cargo 自身へ判断を委ねるべき曖昧な設定は上書きしない。
      if [ -L "$config_file" ] || [ ! -f "$config_file" ]; then
        return 0
      fi
      if ! taplo lint --no-auto-config --no-schema "$config_file" >/dev/null 2>&1; then
        return 0
      fi
      if taplo get --file-path "$config_file" build.target-dir >/dev/null 2>&1; then
        return 0
      fi
    done

    [ "$directory" != / ] || break
    directory=${directory%/*}
    test -n "$directory" || directory=/
  done

  return 1
}

create_project_cache() {
  local builds_root=$1 project_id=$2 project_root marker marker_tmp created=false
  project_root="$builds_root/$project_id"
  marker="$project_root/.dotfiles-agent-cache.json"

  if mkdir -m 700 "$project_root" 2>/dev/null; then
    created=true
  else
    test ! -L "$project_root" || die "project cache is a symlink: $project_root"
    test -d "$project_root" || die "project cache is not a directory: $project_root"
    test "$(stat -c %u "$project_root")" = "$(id -u)" \
      || die "project cache has another owner: $project_root"
  fi
  chmod 700 "$project_root" || die "cannot secure project cache: $project_root"
  test "$(stat -c %a "$project_root")" = 700 \
    || die "project cache mode is not 0700: $project_root"

  if [ "$created" = true ]; then
    marker_tmp=$(mktemp "$project_root/.owner.XXXXXXXX")
    jq -cn --arg project_id "$project_id" \
      '{version: 1, project_id: $project_id}' > "$marker_tmp"
    chmod 600 "$marker_tmp"
    mv -T "$marker_tmp" "$marker"
  fi

  secure_managed_file "$marker" 'project cache marker'
  jq --exit-status --arg project_id "$project_id" \
    '. == {version: 1, project_id: $project_id}' "$marker" >/dev/null \
    || die "project cache marker is invalid: $marker"
  touch "$marker"

  printf '%s/cargo-target\n' "$project_root"
}

if [ "$#" -lt 2 ]; then
  die 'usage: dotfiles-agent-runtime CLIENT ABSOLUTE-UPSTREAM [ARG...]'
fi

client=$1
upstream=$2
shift 2

case "$client" in
  *[!A-Za-z0-9._-]*|'') die "invalid client id: $client" ;;
esac
case "$upstream" in
  /*) ;;
  *) die "upstream binary is not absolute: $upstream" ;;
esac
test -x "$upstream" || die "upstream binary is not executable: $upstream"

cache_root="$HOME/.cache/dotfiles-wsl"
sessions_root="$cache_root/sessions"
builds_root="$cache_root/builds"
mkdir -p "$HOME/.cache"
ensure_managed_directory "$cache_root"
ensure_managed_directory "$sessions_root"

lock_file="$cache_root/gc.lock"
if (set -o noclobber; : > "$lock_file") 2>/dev/null; then
  chmod 600 "$lock_file"
fi
secure_managed_file "$lock_file" 'GC lock'
exec {lock_fd}<>"$lock_file"
flock -x "$lock_fd"

canonical_project=$(project_identity) || die 'cannot derive project identity'
project_id=$(printf '%s' "$canonical_project" | sha256sum | cut -d ' ' -f 1)

if [ "${CARGO_TARGET_DIR+x}" != x ] && [ -n "${CARGO_TARGET_DIR-}" ]; then
  :
elif [ "${CARGO_TARGET_DIR+x}" = x ]; then
  # An explicitly empty value belongs to the caller as well.
  :
elif ! project_has_cargo_target_dir; then
  ensure_managed_directory "$builds_root"
  CARGO_TARGET_DIR=$(create_project_cache "$builds_root" "$project_id")
  export CARGO_TARGET_DIR
fi

boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
case "$boot_id" in
  *[!A-Fa-f0-9-]*|'') die 'invalid boot id' ;;
esac
owner_stat=$(<"/proc/$$/stat")
owner_start_time=$(awk '{print $20}' <<<"${owner_stat##*) }")
case "$owner_start_time" in
  *[!0-9]*|'') die 'cannot read owner process start time' ;;
esac

session_dir=$(mktemp -d "$sessions_root/${project_id}.${client}.$$.XXXXXXXX")
session_id=${session_dir##*/}
mkdir -m 700 "$session_dir/tmp"
metadata_tmp=$(mktemp "$session_dir/.metadata.XXXXXXXX")
jq -cn \
  --arg session_id "$session_id" \
  --arg client "$client" \
  --arg project_id "$project_id" \
  --arg boot_id "$boot_id" \
  --argjson owner_pid "$$" \
  --arg owner_start_time "$owner_start_time" \
  '{version: 1, session_id: $session_id, client: $client, project_id: $project_id,
    boot_id: $boot_id, owner_pid: $owner_pid, owner_start_time: $owner_start_time}' \
  > "$metadata_tmp"
chmod 600 "$metadata_tmp"
mv -T "$metadata_tmp" "$session_dir/metadata.json"

export DOTFILES_AGENT_SESSION_ID=$session_id
export DOTFILES_AGENT_CLIENT=$client
export DOTFILES_AGENT_PROJECT_ID=$project_id
export DOTFILES_AGENT_OWNER_PID=$$
export DOTFILES_AGENT_OWNER_START_TIME=$owner_start_time
export DOTFILES_AGENT_BOOT_ID=$boot_id
export TMPDIR="$session_dir/tmp"
export PATH="@agentShimDirectory@:$PATH"
flock -u "$lock_fd"
exec {lock_fd}>&-

# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [ -n "${session_dir-}" ] \
    && [[ "$session_dir" == "$sessions_root/"* ]] \
    && [ ! -L "$session_dir" ] \
    && [ -d "$session_dir" ]; then
    rm -rf --one-file-system -- "$session_dir" || true
  fi
  if resource_command=$(command -v dotfiles-agent-resource 2>/dev/null); then
    "$resource_command" cleanup-session "$DOTFILES_AGENT_SESSION_ID" || true
  fi

  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if resource_command=$(command -v dotfiles-agent-resource 2>/dev/null); then
  "$resource_command" begin-session "$DOTFILES_AGENT_SESSION_ID" || true
fi

set +e
"$upstream" "$@"
status=$?
set -e
exit "$status"
