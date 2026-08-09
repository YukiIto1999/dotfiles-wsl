set -euo pipefail

die() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
  exit 70
}

validate_managed_directory() {
  local path=$1
  test ! -L "$path" || die "managed path is a symlink: $path"
  test -d "$path" || die "managed path is not a directory: $path"
  test "$(stat -c %u "$path")" = "$(id -u)" || die "managed path has another owner: $path"
  chmod 700 "$path" || die "cannot secure managed directory: $path"
  test "$(stat -c %a "$path")" = 700 || die "managed directory mode is not 0700: $path"
}

validate_managed_file() {
  local path=$1 description=$2
  test ! -L "$path" || die "$description is a symlink: $path"
  test -f "$path" || die "$description is not a regular file: $path"
  test "$(stat -c %u "$path")" = "$(id -u)" || die "$description has another owner: $path"
  chmod 600 "$path" || die "cannot secure $description: $path"
  test "$(stat -c %a "$path")" = 600 || die "$description mode is not 0600: $path"
}

validate_project_cache() {
  local path=$1 project_id=$2 marker
  marker="$path/.dotfiles-agent-cache.json"

  test ! -L "$path" || return 1
  test -d "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 700 "$path" || return 1
  test "$(stat -c %a "$path")" = 700 || return 1
  test ! -L "$marker" || return 1
  test -f "$marker" || return 1
  test "$(stat -c %u "$marker")" = "$(id -u)" || return 1
  chmod 600 "$marker" || return 1
  test "$(stat -c %a "$marker")" = 600 || return 1
  jq --exit-status --arg project_id "$project_id" \
    '. == {version: 1, project_id: $project_id}' "$marker" >/dev/null 2>&1
}

high_bytes=${DOTFILES_AGENT_GC_HIGH_BYTES:-68719476736}
low_bytes=${DOTFILES_AGENT_GC_LOW_BYTES:-51539607552}
case "$high_bytes:$low_bytes" in
  *[!0-9:]*|:*|*:) die 'GC byte thresholds must be non-negative integers' ;;
esac
test "$low_bytes" -le "$high_bytes" || die 'GC low watermark exceeds high watermark'

cache_root="$HOME/.cache/dotfiles-wsl"
sessions_root="$cache_root/sessions"
builds_root="$cache_root/builds"
mkdir -p "$HOME/.cache"
for path in "$cache_root" "$sessions_root" "$builds_root"; do
  if ! mkdir -m 700 "$path" 2>/dev/null; then
    validate_managed_directory "$path"
  fi
done

lock_file="$cache_root/gc.lock"
if (set -o noclobber; : > "$lock_file") 2>/dev/null; then
  chmod 600 "$lock_file"
fi
validate_managed_file "$lock_file" 'GC lock'
exec {lock_fd}<>"$lock_file"
flock -x "$lock_fd"

scan_file=$(mktemp "$cache_root/.gc-scan.XXXXXXXX")
# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup_scan() {
  local status=$?
  trap - EXIT
  if [[ "$scan_file" == "$cache_root/"* ]] && [ ! -L "$scan_file" ] && [ -f "$scan_file" ]; then
    rm -f -- "$scan_file" || true
  fi
  exit "$status"
}
trap cleanup_scan EXIT

current_boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
declare -A active_projects=()

find "$sessions_root" -mindepth 1 -maxdepth 1 -print0 > "$scan_file" \
  || die 'cannot enumerate agent sessions'
while IFS= read -r -d '' session; do
  session_id=${session##*/}
  metadata="$session/metadata.json"
  validate_managed_directory "$session"
  validate_managed_file "$metadata" 'session metadata'
  jq --exit-status --arg session_id "$session_id" '
    keys == ["boot_id", "client", "owner_pid", "owner_start_time", "project_id", "session_id", "version"] and
    .version == 1 and
    .session_id == $session_id and
    (.client | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.project_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.boot_id | type == "string" and test("^[A-Fa-f0-9-]+$")) and
    (.owner_pid | type == "number" and . > 0 and floor == .) and
    (.owner_start_time | type == "string" and test("^[0-9]+$"))
  ' "$metadata" >/dev/null 2>&1 || die "session metadata is invalid: $metadata"

  metadata_boot_id=$(jq -r '.boot_id' "$metadata")
  test "$metadata_boot_id" = "$current_boot_id" || continue
  owner_pid=$(jq -r '.owner_pid' "$metadata")
  owner_start_time=$(jq -r '.owner_start_time' "$metadata")
  project_id=$(jq -r '.project_id' "$metadata")
  if ! kill -0 "$owner_pid" 2>/dev/null; then
    continue
  fi
  test -r "/proc/$owner_pid/stat" || die "live session process cannot be inspected: $session_id"
  test "$(stat -c %u "/proc/$owner_pid")" = "$(id -u)" || continue
  owner_stat=$(<"/proc/$owner_pid/stat")
  current_start_time=$(awk '{print $20}' <<<"${owner_stat##*) }")
  test "$current_start_time" = "$owner_start_time" || continue
  active_projects[$project_id]=1
done < "$scan_file"

declare -a cache_ids=() cache_paths=() cache_sizes=() cache_mtimes=()
total_bytes=0
: > "$scan_file"
find "$builds_root" -mindepth 1 -maxdepth 1 -print0 > "$scan_file" \
  || die 'cannot enumerate project caches'
while IFS= read -r -d '' cache; do
  project_id=${cache##*/}
  if [[ ! "$project_id" =~ ^[0-9a-f]{64}$ ]] || ! validate_project_cache "$cache" "$project_id"; then
    printf 'dotfiles-agent-project-cache-gc: preserving unowned cache path: %s\n' "$cache" >&2
    continue
  fi

  size=$(du -sb -- "$cache" | cut -f 1) || die "cannot measure project cache: $cache"
  mtime=$(stat -c %Y "$cache/.dotfiles-agent-cache.json") \
    || die "cannot read project cache age: $cache"
  cache_ids+=("$project_id")
  cache_paths+=("$cache")
  cache_sizes+=("$size")
  cache_mtimes+=("$mtime")
  total_bytes=$((total_bytes + size))
done < "$scan_file"

now=$(date +%s)
inactive_before=$((now - 30 * 24 * 60 * 60))
declare -A removed=()

remove_cache() {
  local index=$1 project_id cache
  project_id=${cache_ids[$index]}
  cache=${cache_paths[$index]}
  test -z "${active_projects[$project_id]+x}" || return 0
  validate_project_cache "$cache" "$project_id" || return 0
  rm -rf --one-file-system -- "$cache"
  removed[$index]=1
  total_bytes=$((total_bytes - cache_sizes[index]))
}

for index in "${!cache_ids[@]}"; do
  if [ "${cache_mtimes[$index]}" -lt "$inactive_before" ]; then
    remove_cache "$index"
  fi
done

if [ "$total_bytes" -gt "$high_bytes" ]; then
  while IFS=' ' read -r _mtime _project_id index; do
    test "$total_bytes" -gt "$low_bytes" || break
    test -z "${removed[$index]+x}" || continue
    remove_cache "$index"
  done < <(
    for index in "${!cache_ids[@]}"; do
      printf '%s %s %s\n' "${cache_mtimes[$index]}" "${cache_ids[$index]}" "$index"
    done | sort -n -k1,1 -k2,2
  )
fi
