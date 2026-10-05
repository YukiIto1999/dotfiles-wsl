set -euo pipefail
shopt -s nullglob dotglob lastpipe

die() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
  exit 70
}

note() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
}

validate_managed_directory() {
  local path=$1
  test ! -L "$path" || die "managed path is a symlink: $path"
  test -d "$path" || die "managed path is not a directory: $path"
  test "$(stat -c %u "$path")" = "$uid" || die "managed path has another owner: $path"
  chmod 700 "$path" || die "cannot secure managed directory: $path"
  test "$(stat -c %a "$path")" = 700 || die "managed directory mode is not 0700: $path"
}

validate_managed_file() {
  local path=$1 description=$2
  test ! -L "$path" || die "$description is a symlink: $path"
  test -f "$path" || die "$description is not a regular file: $path"
  test "$(stat -c %u "$path")" = "$uid" || die "$description has another owner: $path"
  chmod 600 "$path" || die "cannot secure $description: $path"
  test "$(stat -c %a "$path")" = 600 || die "$description mode is not 0600: $path"
}

# lock の下では rename だけを行う。削除は GC が lock を解いてから trash に対して行い、
# lock を待つ側の時間を rename の長さに抑える。--no-copy は rename できないときに
# copy へ切り替えず失敗させる。
move_to_trash() {
  local trash_root=$1 source=$2 kind=$3
  mv --no-copy -T -- "$source" "$trash_root/$kind.${source##*/}.$$.${EPOCHREALTIME//[.,]/}"
}

validate_session_metadata() {
  local metadata=$1 session_id=$2
  jq --exit-status --arg session_id "$session_id" '
    keys == ["boot_id", "client", "owner_pid", "owner_start_time", "project_id", "session_id", "version"] and
    .version == 1 and
    .session_id == $session_id and
    ((.project_id + ".") as $prefix | .session_id | startswith($prefix)) and
    (.client | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.project_id | type == "string" and test("^[0-9a-f]{64}$")) and
    (.boot_id | type == "string" and test("^[A-Fa-f0-9-]+$")) and
    (.owner_pid | type == "number" and . > 0 and floor == .) and
    (.owner_start_time | type == "string" and test("^[0-9]+$"))
  ' "$metadata" >/dev/null 2>&1
}

session_owner_state() {
  local metadata=$1 metadata_boot_id owner_pid owner_start_time owner_uid owner_stat current_start_time
  metadata_boot_id=$(jq -r '.boot_id' "$metadata") || {
    printf 'unknown\n'
    return
  }
  if [ "$metadata_boot_id" != "$current_boot_id" ]; then
    printf 'orphan\n'
    return
  fi
  owner_pid=$(jq -r '.owner_pid' "$metadata") || {
    printf 'unknown\n'
    return
  }
  owner_start_time=$(jq -r '.owner_start_time' "$metadata") || {
    printf 'unknown\n'
    return
  }
  if [ ! -e "/proc/$owner_pid" ]; then
    printf 'orphan\n'
    return
  fi
  owner_uid=$(stat -c %u "/proc/$owner_pid" 2>/dev/null) || {
    printf 'unknown\n'
    return
  }
  if [ "$owner_uid" != "$uid" ]; then
    printf 'unknown\n'
    return
  fi
  owner_stat=$(<"/proc/$owner_pid/stat") || {
    printf 'unknown\n'
    return
  }
  current_start_time=$(awk '{print $20}' <<<"${owner_stat##*) }") || {
    printf 'unknown\n'
    return
  }
  if [ "$current_start_time" != "$owner_start_time" ]; then
    printf 'orphan\n'
    return
  fi
  printf 'live\n'
}

# launcher が SIGKILL で消えても、client は session の scope の中で動き続ける。
# scope の cgroup が残る間は session を生きているものとして扱う。
session_state() {
  local session_id=$1 metadata=$2 state
  state=$(session_owner_state "$metadata")
  if [ "$state" = orphan ] && [ -d "$slice_cgroup/dotfiles-agent-${session_id#*.}.scope" ]; then
    state=live
  fi
  printf '%s\n' "$state"
}

create_shared_cache() {
  local cache_root=$1 shared_root marker marker_tmp created=false
  shared_root="$cache_root/shared"
  marker="$shared_root/.dotfiles-agent-cache.json"

  if mkdir -m 700 "$shared_root" 2>/dev/null; then
    created=true
  else
    validate_managed_directory "$shared_root"
  fi
  if [ "$created" = true ]; then
    marker_tmp=$(mktemp "$shared_root/.owner.XXXXXXXX")
    jq -cn '{version: 1, kind: "shared-cache"}' > "$marker_tmp"
    chmod 600 "$marker_tmp"
    mv -T "$marker_tmp" "$marker"
  fi

  validate_managed_file "$marker" 'shared cache marker'
  jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$marker" >/dev/null 2>&1 \
    || die "shared cache marker is invalid: $marker"
  for path in "$shared_root/cargo-home" "$shared_root/xdg-cache"; do
    if ! mkdir -m 700 "$path" 2>/dev/null; then
      validate_managed_directory "$path"
    fi
  done

  printf '%s\n' "$shared_root"
}

validate_shared_cache() {
  local shared_root=$1 marker="$1/.dotfiles-agent-cache.json"
  validate_managed_directory "$shared_root"
  validate_managed_file "$marker" 'shared cache marker'
  jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$marker" >/dev/null 2>&1 \
    || die "shared cache marker is invalid: $marker"
  validate_managed_directory "$shared_root/cargo-home"
  validate_managed_directory "$shared_root/xdg-cache"
}

allocated_bytes() {
  local path=$1 output
  # 計測中に live build が消した file による du の非ゼロ終了の許容。合計が減るだけで削除は増えない
  output=$(du -s -B1 -- "$path" 2>/dev/null) || true
  output=${output%%$'\t'*}
  [[ "$output" =~ ^[0-9]+$ ]] || die "cannot measure allocated cache bytes: $path"
  printf '%s\n' "$output"
}

# Cargo 1.95 の .cargo-lock と 1.98 の .cargo-build-lock はどちらも build の間だけ [<target>/]<profile>/ に置く排他 flock のため entry ごとに一つの lock file での判定は不可
lock_entry() {
  local lock fd
  for lock in "$1"/*/.cargo-build-lock "$1"/*/*/.cargo-build-lock "$1"/*/.cargo-lock "$1"/*/*/.cargo-lock; do
    [ -f "$lock" ] || return 1
    exec {fd}<"$lock" || return 1
    entry_lock_fds+=("$fd")
    flock -n -x "$fd" || return 1
  done
}

unlock_entry() {
  local fd
  for fd in "${entry_lock_fds[@]}"; do
    exec {fd}<&-
  done
  entry_lock_fds=()
}

# Cargo は fresh な build で何も書かず各 unit の .fingerprint/<package>-<hash>/ の hash file を読むだけのため mtime や invoked.timestamp での最終使用の測定は不可
# test runner は Cargo を介さず成果物を実行し fingerprint を読まないため fingerprint の file だけでの最終使用の測定は不可
# GC 自身が file を読むと atime が最終使用を表さなくなるため stat 以外での file の参照は不可
# GC 自身の走査が directory の atime を動かすため directory の atime での最終使用の測定は不可
# Cargo は fingerprint の JSON を build し直す unit でだけ読むため JSON の atime での最終使用の測定は不可
# 同じ crate の別の build も同じ名前の接頭辞を持つため crate 名での成果物の照合は不可
# 名前に hash を持たない成果物は持ち主の unit を決められないため回収は不可
# rustc は incremental の directory に unit とは別の hash を付けるため fingerprint との照合は不可
scan_units() {
  local base=$cargo_build_root prefix='' lock_depth=4 item_depth=3 with_members=1
  if [ "$#" -gt 0 ]; then
    base=$cargo_build_root/$1 prefix=$1/ lock_depth=2 item_depth=1 with_members=0
  fi
  awk -v with_members="$with_members" '
    BEGIN { RS = "\0" }
    ARGIND == 1 {
      if (match($0, /^([0-9a-f]{2}\/[0-9a-f]{14})\/(.+)\/\.cargo-(build-)?lock$/, lock)) {
        profiles[lock[1], lock[2]] = 1
      }
      next
    }
    match($0, /^([0-9]+) ([0-9]+) ([0-9.]+) ([0-9.]+) (.) ([0-9a-f]{2}\/[0-9a-f]{14})\/(.+)$/, f) {
      entry = f[6]
      count = split(f[7], part, "/")
      if ((entry, part[1]) in profiles) {
        depth = 2
        profile = part[1]
      } else if (count > 1 && (entry, part[1] "/" part[2]) in profiles) {
        depth = 3
        profile = part[1] "/" part[2]
      } else {
        next
      }
      if (count <= depth) next
      category = part[depth]
      name = part[depth + 1]
      member = profile "/" category "/" name
      used = f[4] + 0
      if (f[5] == "f" && part[count] !~ /\.json$/ && f[3] + 0 > used) used = f[3] + 0
      if (category == "incremental") {
        group = entry SUBSEP "incremental" SUBSEP member
        if (!(group in last) || used > last[group]) last[group] = used
      } else {
        if (category == "deps" && name == "artifact") {
          if (count <= depth + 1) next
          name = part[depth + 2]
          member = member "/" name
          pattern = "-([0-9a-f]{16})$"
        } else if (category == ".fingerprint") {
          pattern = "-([0-9a-f]{16})$"
        } else if (category == "deps" || category == "build" || category == "examples") {
          pattern = "-([0-9a-f]{16})(\\.|$)"
        } else {
          next
        }
        if (!match(name, pattern, hash)) next
        group = entry SUBSEP "unit" SUBSEP hash[1]
        if (category == ".fingerprint") fingerprinted[entry, hash[1]] = 1
        if (f[5] == "f" && (!(group in last) || used > last[group])) last[group] = used
      }
      if (f[5] == "f" && (!(group in touched) || used > touched[group])) touched[group] = used
      members[group][member] = 1
      if (f[7] == member) identity[group, member] = f[1]
      if (!(f[1] in counted)) {
        counted[f[1]] = 1
        size[group] += f[2] * 512
      }
    }
    END {
      PROCINFO["sorted_in"] = "@ind_str_asc"
      for (group in members) {
        split(group, id, SUBSEP)
        kind = id[2]
        used = (group in last) ? last[group] : touched[group]
        if (kind == "unit" && !((id[1], id[3]) in fingerprinted)) kind = "orphan"
        ident = ""
        for (member in members[group]) {
          ident = ident (((group, member) in identity) ? identity[group, member] : "-") ","
        }
        printf "G %s %d %.9f %d %s %s %s%c", kind, used, used, size[group], id[1], id[3], ident, 0
        if (with_members) {
          for (member in members[group]) printf "M %s/%s%c", id[1], member, 0
        }
      }
    }
  ' \
    <(find "$base" -mindepth "$lock_depth" -maxdepth "$((lock_depth + 1))" -type f \
      \( -name .cargo-build-lock -o -name .cargo-lock \) -printf "$prefix%P\\0" 2>/dev/null) \
    <(find "$base" -mindepth "$item_depth" -printf "%i %b %A@ %T@ %y $prefix%P\\0" 2>/dev/null)
}

# 走査の後に directory が symlink へ置き換わると cd が build-dir の外を指すため検証の無い移動は不可
move_members() {
  local trash=$1 directory=$2 path=$cargo_build_root component
  local -a components names
  IFS=/ read -r -a components <<<"$directory"
  for component in "${components[@]}"; do
    path=$path/$component
    if [ -L "$path" ]; then
      note "build-dir path is a symlink: $path"
      unresolved=true
      return
    fi
  done
  mapfile -t names <<<"${3%$'\n'}"
  if ! printf '%s\0' "${names[@]}" |
    (cd -- "$cargo_build_root/$directory" && xargs -0 mv --no-copy -t "$trash/$directory" --); then
    note "cannot move build units to trash: $cargo_build_root/$directory"
    unresolved=true
  fi
}

# 走査の後に始まる test は一度きりの走査に現れないため Cargo の lock を取る前の /proc の確認は不可
entry_runs_executable() {
  local executable
  while IFS= read -r -d '' executable; do
    [[ $executable != "$build_root_real/$1"/* ]] || return 0
  done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%l\0' 2>/dev/null)
  return 1
}

# lock を待つ Cargo は開いた lock file の inode を lock するため lock file や unit の無くなった entry の移動は不可
# launcher は build-dir に触れないため unit の rename の間の gc.lock の保持は不要
# 走査の後に別の Cargo が unit を使い直すため走査の時点の最終使用だけでの回収は不可
reclaim_units() {
  local entry=$1 root=$cargo_build_root/$1 trash group index member record kind used_exact bytes key ident
  local -a groups=("${@:2}") moving=()
  local -A current=() current_bytes=() by_directory=() trash_directories=()
  trash=$(mktemp -d "$trash_root/units.XXXXXXXX") || die "cannot create a trash entry for $root"
  for group in "${groups[@]}"; do
    for ((index = group_first[group]; index < group_first[group] + group_count[group]; index++)); do
      trash_directories[$trash/${group_members[index]%/*}]=1
    done
  done
  mkdir -p -- "${!trash_directories[@]}"
  # test は実行中に別の unit の OUT_DIR を読むため実行中の file の属する unit だけの保護は不可
  if ! lock_entry "$root" || entry_runs_executable "$entry"; then
    unlock_entry
    busy_entries[$entry]=1
    return
  fi
  while IFS= read -r -d '' record; do
    read -r _tag kind _used used_exact bytes _entry key ident <<<"$record"
    current[$kind/$key]="$used_exact $ident"
    current_bytes[$kind/$key]=$bytes
  done < <(scan_units "$entry")
  for group in "${groups[@]}"; do
    finished_groups[$group]=1
    [ "${current[${group_kinds[group]}/${group_keys[group]}]-}" = \
      "${group_used_exact[group]} ${group_idents[group]}" ] || continue
    moving+=("$group")
    for ((index = group_first[group]; index < group_first[group] + group_count[group]; index++)); do
      member=${group_members[index]}
      [[ $member != *$'\n'* ]] || continue
      [ -e "$cargo_build_root/$member" ] || [ -L "$cargo_build_root/$member" ] || continue
      by_directory[${member%/*}]+=${member##*/}$'\n'
    done
  done
  for directory in "${!by_directory[@]}"; do
    move_members "$trash" "$directory" "${by_directory[$directory]}"
  done
  for group in "${moving[@]}"; do
    for ((index = group_first[group]; index < group_first[group] + group_count[group]; index++)); do
      member=$cargo_build_root/${group_members[index]}
      if [ -e "$member" ] || [ -L "$member" ]; then
        continue 2
      fi
    done
    total_bytes=$((total_bytes - current_bytes[${group_kinds[group]}/${group_keys[group]}]))
    units_left=$((units_left - group_bytes[group]))
  done
  unlock_entry
}

reclaim_groups() {
  local group entry
  local -a groups
  local -A by_entry=()
  for group in "$@"; do
    by_entry[${group_entries[group]}]+=" $group"
  done
  for entry in "${!by_entry[@]}"; do
    read -r -a groups <<<"${by_entry[$entry]}"
    reclaim_units "$entry" "${groups[@]}"
  done
}

# trash の中身は session からも launcher からも参照されない。中断した実行の残りも含めて消す。
empty_trash() {
  local entry
  for entry in "$trash_root"/*; do
    if ! find -P "$entry" -xdev -type d -uid "$EUID" ! -perm -u=rwx \
      -exec chmod u+rwx -- {} \; \
      || ! rm -rf --one-file-system -- "$entry"; then
      note "cannot remove trash entry: $entry"
      unresolved=true
    fi
  done
}

any_session() {
  local session
  for session in "$sessions_root"/*; do
    [ -n "${dead_sessions[$session]+x}" ] || return 0
  done
  return 1
}

high_bytes=${DOTFILES_AGENT_GC_HIGH_BYTES:-@gcHighBytes@}
low_bytes=${DOTFILES_AGENT_GC_LOW_BYTES:-@gcLowBytes@}
case "$high_bytes:$low_bytes" in
  *[!0-9:]*|:*|*:) die 'GC byte thresholds must be non-negative integers' ;;
esac
test "$low_bytes" -le "$high_bytes" || die 'GC low watermark exceeds high watermark'

uid=$(id -u)
current_boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
cgroup_root=${DOTFILES_AGENT_GC_CGROUP_ROOT:-/sys/fs/cgroup}
slice_cgroup="$cgroup_root/user.slice/user-$uid.slice/user@$uid.service/@sliceUnit@"

cache_root="$HOME/@cacheRootRelative@"
sessions_root="$cache_root/sessions"
cargo_build_root="$cache_root/cargo-build"
trash_root="$cache_root/trash"
mkdir -p "$HOME/.cache"
for path in "$cache_root" "$sessions_root" "$cargo_build_root" "$trash_root"; do
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

unresolved=false
empty_trash

# launcher は共有 cache の marker を lock の下で検証するので、作成も lock の下で行う。
flock -x "$lock_fd"
shared_root=$(create_shared_cache "$cache_root")
flock -u "$lock_fd"

declare -A dead_sessions=()
declare -a unclaimed_sessions=()
active_session_count=0

find "$sessions_root" -mindepth 1 -maxdepth 1 -print0 | mapfile -d '' -t sessions \
  || die 'cannot enumerate agent sessions'
for session in "${sessions[@]}"; do
  session_id=${session##*/}
  metadata="$session/metadata.json"
  validate_managed_directory "$session"
  if [ ! -e "$metadata" ] && [ ! -L "$metadata" ]; then
    unclaimed_sessions+=("$session")
    continue
  fi
  validate_managed_file "$metadata" 'session metadata'
  if ! validate_session_metadata "$metadata" "$session_id"; then
    # Invalid metadata no longer identifies the owner, so the session may still
    # be live. It is kept and blocks the shared cache purge, and the run fails.
    unresolved=true
    note "invalid session metadata: $metadata"
    continue
  fi
  if [ "$(session_state "$session_id" "$metadata")" = orphan ]; then
    dead_sessions[$session]=1
  else
    active_session_count=$((active_session_count + 1))
  fi
done

# 持ち主の死んだ session は生き返らない。metadata の無い session は、launcher が
# lock を解く前に metadata を書くので、lock の下でもまだ無ければ持ち主がいない。
for session in "${!dead_sessions[@]}" "${unclaimed_sessions[@]}"; do
  flock -x "$lock_fd"
  if [ ! -L "$session" ] && [ -d "$session" ] &&
    { [ -n "${dead_sessions[$session]+x}" ] ||
      { [ ! -e "$session/metadata.json" ] && [ ! -L "$session/metadata.json" ]; }; } &&
    ! move_to_trash "$trash_root" "$session" session; then
    note "cannot move orphan session to trash: $session"
    unresolved=true
  fi
  flock -u "$lock_fd"
done

# No cache is removed until every managed root and entry has passed validation.
validate_shared_cache "$shared_root"
total_bytes=$(($(allocated_bytes "$shared_root") + $(allocated_bytes "$cargo_build_root")))
build_root_real=$(realpath -e -- "$cargo_build_root") || die "cannot resolve $cargo_build_root"

# noatime では fresh な build の読み込みが atime を動かさず使用が見えないため atime を更新しない mount での unit の回収は不可
units_judgeable=true
mount_options=$(findmnt -n -o OPTIONS --target "$cargo_build_root") || mount_options=''
case ",$mount_options," in
  ,,|*,noatime,*)
    note "cannot judge when Cargo units were used: $cargo_build_root does not update atime (mount options: ${mount_options:-unknown})"
    unresolved=true
    units_judgeable=false
    ;;
esac

declare -a group_kinds=() group_used=() group_used_exact=() group_bytes=() group_entries=()
declare -a group_keys=() group_idents=() group_first=() group_count=() group_members=()
declare -a entry_lock_fds=()
while IFS= read -r -d '' record; do
  case $record in
    'G '*)
      read -r _tag kind used used_exact bytes entry key ident <<<"$record"
      group=${#group_kinds[@]}
      group_kinds+=("$kind")
      group_used+=("$used")
      group_used_exact+=("$used_exact")
      group_bytes+=("$bytes")
      group_entries+=("$entry")
      group_keys+=("$key")
      group_idents+=("$ident")
      group_first+=("${#group_members[@]}")
      group_count+=(0)
      ;;
    'M '*)
      group_members+=("${record#M }")
      group_count[group]=$((group_count[group] + 1))
      ;;
  esac
done < <([ "$units_judgeable" = false ] || scan_units)
units_left=0
for bytes in "${group_bytes[@]}"; do
  units_left=$((units_left + bytes))
done

now=$(date +%s)
# Cargo は invocation の開始時だけ hash file を読み relatime はその atime を最大 24 時間古いまま残すため 24 時間までの invocation が使う unit に 48 時間より短い保護は不可
recent_before=$((now - 48 * 60 * 60))
inactive_before=$((now - @gcInactiveDays@ * 24 * 60 * 60))
declare -A finished_groups=() busy_entries=()
declare -a inactive_groups=() pressure_groups=()

for group in "${!group_kinds[@]}"; do
  [ "${group_used[group]}" -lt "$recent_before" ] || continue
  if [ "${group_kinds[group]}" = orphan ] || [ "${group_used[group]}" -lt "$inactive_before" ]; then
    inactive_groups+=("$group")
  fi
done
reclaim_groups "${inactive_groups[@]}"

# lock を取れない entry と走査の後に使われた unit は選んだ後に分かるため選んだ時点の bytes での停止は不可
if [ "$total_bytes" -gt "$high_bytes" ]; then
  while [ "$total_bytes" -gt "$low_bytes" ]; do
    pressure_groups=()
    projected_bytes=$total_bytes
    while IFS=' ' read -r _used group; do
      [ "$projected_bytes" -gt "$low_bytes" ] || break
      pressure_groups+=("$group")
      projected_bytes=$((projected_bytes - group_bytes[group]))
    done < <(
      for group in "${!group_kinds[@]}"; do
        if [ -z "${finished_groups[$group]+x}" ] && [ -z "${busy_entries[${group_entries[group]}]+x}" ] &&
          [ "${group_used[group]}" -lt "$recent_before" ]; then
          printf '%s %s\n' "${group_used[group]}" "$group"
        fi
      done | sort -k1,1n -k2,2n
    )
    [ "${#pressure_groups[@]}" -gt 0 ] || break
    reclaim_groups "${pressure_groups[@]}"
  done
fi

empty_trash

if [ "$total_bytes" -gt "$high_bytes" ] && [ "$active_session_count" -eq 0 ]; then
  purged=false
  flock -x "$lock_fd"
  if ! any_session; then
    validate_shared_cache "$shared_root"
    if ! move_to_trash "$trash_root" "$shared_root/cargo-home" shared ||
      ! move_to_trash "$trash_root" "$shared_root/xdg-cache" shared; then
      die "cannot move the shared cache to trash: $shared_root"
    fi
    mkdir -m 700 "$shared_root/cargo-home" "$shared_root/xdg-cache"
    validate_shared_cache "$shared_root"
    purged=true
  fi
  flock -u "$lock_fd"
  if [ "$purged" = true ]; then
    empty_trash
    total_bytes=$(($(allocated_bytes "$shared_root") + $(allocated_bytes "$cargo_build_root")))
    # 48 時間の保護と lock で見送った unit による超過は時間で解消するため共有 cache を空にした後の上限超過だけでの失敗は不可
    test "$((total_bytes - units_left))" -le "$high_bytes" \
      || die "cache content the GC cannot reclaim stays above the high watermark after shared purge"
  fi
fi

if [ "$total_bytes" -gt "$high_bytes" ]; then
  note "allocated cache bytes remain above the high watermark: $total_bytes > $high_bytes"
fi

if [ "$unresolved" = true ]; then
  die 'agent cache entries remain unresolved'
fi
