set -euo pipefail
shopt -s nullglob dotglob lastpipe

die() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
  exit 70
}

note() {
  printf 'dotfiles-agent-project-cache-gc: %s\n' "$1" >&2
}

dry_run=false
usage() {
  printf '%s\n' \
    'usage: dotfiles-agent-project-cache-gc [--dry-run]' \
    '  no argument: reclaim agent cache by the retention policy' \
    '  --dry-run:   report on stdout what a run would retire or keep, and change nothing'
}
case "$#:${1-}" in
  0:) ;;
  1:--dry-run) dry_run=true ;;
  1:-h | 1:--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

report() {
  [ "$dry_run" = false ] || printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

# launcher は gc.lock を取らずに session を消すため、列挙の後の消失を不正とする検査は不可
gone_or_die() {
  local path=$1 vanished_ok=$2 message=$3
  if [ "$vanished_ok" = vanished-ok ] && absent "$path"; then
    return 1
  fi
  die "$message"
}

validate_managed_directory() {
  local path=$1 vanished_ok=${2-}
  test ! -L "$path" || die "managed path is a symlink: $path"
  test -d "$path" || gone_or_die "$path" "$vanished_ok" "managed path is not a directory: $path" || return 1
  test "$(stat -c %u "$path" 2>/dev/null)" = "$uid" \
    || gone_or_die "$path" "$vanished_ok" "managed path has another owner: $path" || return 1
  if [ "$dry_run" = true ]; then
    test "$(stat -c %a "$path" 2>/dev/null)" = 700 || note "managed directory mode is not 0700 and a run secures it: $path"
    return
  fi
  chmod 700 "$path" || gone_or_die "$path" "$vanished_ok" "cannot secure managed directory: $path" || return 1
  test "$(stat -c %a "$path" 2>/dev/null)" = 700 \
    || gone_or_die "$path" "$vanished_ok" "managed directory mode is not 0700: $path" || return 1
}

validate_managed_file() {
  local path=$1 description=$2 vanished_ok=${3-}
  test ! -L "$path" || die "$description is a symlink: $path"
  test -f "$path" || gone_or_die "$path" "$vanished_ok" "$description is not a regular file: $path" || return 1
  test "$(stat -c %u "$path" 2>/dev/null)" = "$uid" \
    || gone_or_die "$path" "$vanished_ok" "$description has another owner: $path" || return 1
  if [ "$dry_run" = true ]; then
    test "$(stat -c %a "$path" 2>/dev/null)" = 600 || note "$description mode is not 0600 and a run secures it: $path"
    return
  fi
  chmod 600 "$path" || gone_or_die "$path" "$vanished_ok" "cannot secure $description: $path" || return 1
  test "$(stat -c %a "$path" 2>/dev/null)" = 600 \
    || gone_or_die "$path" "$vanished_ok" "$description mode is not 0600: $path" || return 1
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
    state=scope
  fi
  printf '%s\n' "$state"
}

# session の削除は scratch の中の worktree を壊すため、worktree の判定を抜いた session の回収は不可
session_worktrees() {
  local -a options=(--nested-only)
  [ "$dry_run" = false ] || options+=(--preview)
  @sessionWorktreesCommand@ "${options[@]}" "$1"
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
  [ -e "$path" ] || {
    printf '0\n'
    return
  }
  # 計測中に live build が消した file による du の非ゼロ終了の許容。合計が減るだけで削除は増えない
  output=$(du -s -B1 -- "$path" 2>/dev/null) || true
  output=${output%%$'\t'*}
  if [[ ! "$output" =~ ^[0-9]+$ ]]; then
    [ ! -e "$path" ] || die "cannot measure allocated cache bytes: $path"
    output=0
  fi
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
  # lock を持ったままの再走査は実行中の Cargo を待たせるため dry-run の再走査は不可
  if [ "$dry_run" = true ]; then
    if ! lock_entry "$root" || entry_runs_executable "$entry"; then
      unlock_entry
      busy_entries[$entry]=1
      report keep cargo-entry - "$root" busy
      return
    fi
    unlock_entry
    for group in "${groups[@]}"; do
      finished_groups[$group]=1
      report retire "cargo-${group_kinds[group]}" "${group_bytes[group]}" "$root#${group_keys[group]}" "${group_reasons[group]}"
      total_bytes=$((total_bytes - group_bytes[group]))
      units_left=$((units_left - group_bytes[group]))
    done
    return
  fi
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
  local -a groups entries
  local -A by_entry=()
  for group in "$@"; do
    by_entry[${group_entries[group]}]+=" $group"
  done
  [ "${#by_entry[@]}" -gt 0 ] || return 0
  mapfile -t entries < <(printf '%s\n' "${!by_entry[@]}" | sort)
  for entry in "${entries[@]}"; do
    read -r -a groups <<<"${by_entry[$entry]}"
    reclaim_units "$entry" "${groups[@]}"
  done
}

# trash の中身は session からも launcher からも参照されない。中断した実行の残りも含めて消す。
empty_trash() {
  local entry
  for entry in "$trash_root"/*; do
    if [ "$dry_run" = true ]; then
      report retire trash "$(allocated_bytes "$entry")" "$entry" interrupted-removal
      continue
    fi
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

# verification-cache は scratch を cwd や fd に持たないため argv の script 名以外での生存判定は不可
# 戻り値は 0 が生存、1 が不在、2 が判断不能。読めない cmdline は消えた process と自分の uid の process を分ける
verification_runner_state() {
  local verdict path pid owner observed unverifiable=false
  local -a cmdlines=(/proc/[0-9]*/cmdline)
  if [ "${#cmdlines[@]}" -eq 0 ] || [ ! -r "/proc/$$/cmdline" ]; then
    return 2
  fi
  observed=$(awk -v runner="$verification_runner" '
    BEGIN { RS = "\0" }
    BEGINFILE { if (ERRNO != "") { print "unreadable", FILENAME; nextfile } }
    ENDFILE { if (ERRNO != "") print "unreadable", FILENAME }
    substr($0, length($0) - length(runner)) == "/" runner { print "alive"; exit }
  ' "${cmdlines[@]}" </dev/null 2>/dev/null) || return 2
  while IFS=' ' read -r verdict path; do
    case $verdict in
      alive) return 0 ;;
      unreadable)
        pid=${path#/proc/}
        pid=${pid%%/*}
        if ! owner=$(stat -c %u "/proc/$pid" 2>/dev/null); then
          [ ! -d "/proc/$pid" ] || unverifiable=true
          continue
        fi
        [ "$owner" != "$uid" ] || unverifiable=true
        ;;
    esac
  done <<<"$observed"
  [ "$unverifiable" = false ] || return 2
  return 1
}

# receipt と waiver と gate の session 記録は再開に使われるため verification root 全体の一括回収は不可
retire_verification_legacy() {
  local path record name bytes runner_state
  local -a scratch=() owned=() candidates=() records=() lines=()
  [ -e "$verification_root" ] || [ -L "$verification_root" ] || return 0
  validate_managed_directory "$verification_root"

  find "$verification_root" -mindepth 1 -maxdepth 1 -name '.fingerprint.*' -print0 | sort -z |
    mapfile -d '' -t scratch || die "cannot enumerate verification scratch: $verification_root"
  for path in "${scratch[@]}"; do
    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(stat -c %u "$path")" != "$uid" ]; then
      note "verification scratch is not a directory owned by this user: $path"
      report unresolved verification-scratch - "$path" not-owned-directory
      unresolved=true
      continue
    fi
    owned+=("$path")
  done
  runner_state=1
  if [ "${#owned[@]}" -gt 0 ]; then
    # snapshot より前の runner 確認では後から作られた scratch を回収するため不可
    runner_state=0
    verification_runner_state || runner_state=$?
  fi
  case $runner_state in
    0)
      for path in "${owned[@]}"; do
        report keep verification-scratch - "$path" runner-alive
      done
      ;;
    1)
      for path in "${owned[@]}"; do
        if [ "$dry_run" = true ]; then
          report retire verification-scratch "$(allocated_bytes "$path")" "$path" no-runner
        elif ! move_to_trash "$trash_root" "$path" verification && { [ -e "$path" ] || [ -L "$path" ]; }; then
          note "cannot move verification scratch to trash: $path"
          unresolved=true
        fi
      done
      ;;
    *)
      note "cannot tell whether a legacy verification-cache still runs, so its scratch is kept: $verification_root"
      unresolved=true
      for path in "${owned[@]}"; do
        report keep verification-scratch - "$path" runner-unverifiable
      done
      ;;
  esac

  find "$verification_root" -mindepth 2 -maxdepth 2 -type f -uid "$uid" -regextype posix-extended \
    -regex '.*/[0-9a-f]{64}/[0-9a-f]{64}\.success' -print0 | sort -z |
    mapfile -d '' -t candidates || die "cannot enumerate verification records: $verification_root"
  for record in "${candidates[@]}"; do
    name=${record##*/}
    name=${name%.success}
    mapfile -t lines <"$record" || continue
    if [ "${#lines[@]}" -eq 2 ] && [[ ${lines[0]} =~ ^version=[0-9]+$ ]] && [ "${lines[1]}" = "fingerprint=$name" ]; then
      records+=("$record")
    else
      report keep verification-success - "$record" unrecognized-record
    fi
  done
  [ "${#records[@]}" -gt 0 ] || return 0
  if [ "$dry_run" = true ]; then
    bytes=$({ du -s -B1 -- "${records[@]}" 2>/dev/null || true; } | awk '{ sum += $1 } END { print sum + 0 }')
    report retire verification-success "$bytes" "$verification_root" "legacy-record x${#records[@]}"
  elif ! printf '%s\0' "${records[@]}" | xargs -0 rm -f --; then
    note "cannot remove legacy verification records under: $verification_root"
    unresolved=true
  fi
}

report_summary() {
  report summary cache "$total_bytes" "before=$cache_bytes_before high=$high_bytes low=$low_bytes" "active-sessions=$active_session_count"
}

high_bytes=${DOTFILES_AGENT_GC_HIGH_BYTES:-@gcHighBytes@}
low_bytes=${DOTFILES_AGENT_GC_LOW_BYTES:-@gcLowBytes@}
case "$high_bytes:$low_bytes" in
  *[!0-9:]*|:*|*:) die 'GC byte thresholds must be non-negative integers' ;;
esac
test "$low_bytes" -le "$high_bytes" || die 'GC low watermark exceeds high watermark'

uid=$(id -u)
current_boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
cgroup_root=${DOTFILES_AGENT_CGROUP_ROOT:-/sys/fs/cgroup}
slice_cgroup="$cgroup_root/user.slice/user-$uid.slice/user@$uid.service/@sliceUnit@"
verification_runner=dotfiles-agent-verification-cache

cache_root="$HOME/@cacheRootRelative@"
sessions_root="$cache_root/sessions"
cargo_build_root="$cache_root/cargo-build"
trash_root="$cache_root/trash"
verification_root="$cache_root/verification"
shared_root="$cache_root/shared"
lock_file="$cache_root/gc.lock"

unresolved=false
if [ "$dry_run" = true ]; then
  for path in "$cache_root" "$sessions_root" "$cargo_build_root" "$trash_root"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      validate_managed_directory "$path"
    fi
  done
else
  mkdir -p "$HOME/.cache"
  for path in "$cache_root" "$sessions_root" "$cargo_build_root" "$trash_root"; do
    if ! mkdir -m 700 "$path" 2>/dev/null; then
      validate_managed_directory "$path"
    fi
  done
  if (set -o noclobber; : > "$lock_file") 2>/dev/null; then
    chmod 600 "$lock_file"
  fi
  validate_managed_file "$lock_file" 'GC lock'
  exec {lock_fd}<>"$lock_file"
fi

empty_trash

if [ "$dry_run" = false ]; then
  # launcher は共有 cache の marker を lock の下で検証するので、作成も lock の下で行う。
  flock -x "$lock_fd"
  shared_root=$(create_shared_cache "$cache_root")
  flock -u "$lock_fd"
fi

declare -A dead_sessions=()
declare -a dead_list=() unclaimed_sessions=() sessions=()
active_session_count=0

if [ -d "$sessions_root" ]; then
  find "$sessions_root" -mindepth 1 -maxdepth 1 -print0 | sort -z | mapfile -d '' -t sessions \
    || die 'cannot enumerate agent sessions'
fi
for session in "${sessions[@]}"; do
  session_id=${session##*/}
  metadata="$session/metadata.json"
  validate_managed_directory "$session" vanished-ok || continue
  if [ ! -e "$metadata" ] && [ ! -L "$metadata" ]; then
    unclaimed_sessions+=("$session")
    continue
  fi
  validate_managed_file "$metadata" 'session metadata' vanished-ok || continue
  if ! validate_session_metadata "$metadata" "$session_id"; then
    if absent "$metadata"; then
      continue
    fi
    # Invalid metadata no longer identifies the owner, so the session may still
    # be live. It is kept and blocks the shared cache purge, and the run fails.
    unresolved=true
    active_session_count=$((active_session_count + 1))
    note "invalid session metadata: $metadata"
    report unresolved session - "$session" invalid-metadata
    continue
  fi
  state=$(session_state "$session_id" "$metadata")
  if [ "$state" = orphan ]; then
    dead_sessions[$session]=1
    dead_list+=("$session")
  else
    active_session_count=$((active_session_count + 1))
    case $state in
      live) reason='owner-alive' ;;
      scope) reason='scope-occupied' ;;
      *) reason='owner-unverifiable' ;;
    esac
    report keep session - "$session" "$reason"
  fi
done

# 持ち主の死んだ session は生き返らない。metadata の無い session は、launcher が
# lock を解く前に metadata を書くので、lock の下でもまだ無ければ持ち主がいない。
# lock を取る観測は launcher の登録を待たせるため dry-run の lock は不可
for session in "${dead_list[@]}" "${unclaimed_sessions[@]}"; do
  if absent "$session"; then
    continue
  fi
  if [ -n "${dead_sessions[$session]+x}" ]; then
    reason='owner-dead'
  else
    reason=unclaimed
  fi
  worktree_status=0
  retained_worktrees=$(session_worktrees "$session") || worktree_status=$?
  if [ "$worktree_status" -ne 0 ]; then
    note "cannot verify the worktree record of a session, so it is kept: $session"
    report unresolved session - "$session" worktree-record
    unresolved=true
    continue
  fi
  if [ -n "$retained_worktrees" ]; then
    report keep session - "$session" retained-worktree
    continue
  fi
  if [ "$dry_run" = true ]; then
    report retire session "$(allocated_bytes "$session")" "$session" "$reason"
    continue
  fi
  flock -x "$lock_fd"
  if [ ! -L "$session" ] && [ -d "$session" ] &&
    { [ -n "${dead_sessions[$session]+x}" ] ||
      { [ ! -e "$session/metadata.json" ] && [ ! -L "$session/metadata.json" ]; }; } &&
    ! move_to_trash "$trash_root" "$session" session && ! absent "$session"; then
    note "cannot move orphan session to trash: $session"
    unresolved=true
  fi
  flock -u "$lock_fd"
done

# No cache is removed until every managed root and entry has passed validation.
if [ -e "$shared_root" ] || [ -L "$shared_root" ]; then
  validate_shared_cache "$shared_root"
fi
total_bytes=$(($(allocated_bytes "$shared_root") + $(allocated_bytes "$cargo_build_root")))
cache_bytes_before=$total_bytes

units_judgeable=true
build_root_real=$cargo_build_root
if [ -d "$cargo_build_root" ]; then
  build_root_real=$(realpath -e -- "$cargo_build_root") || die "cannot resolve $cargo_build_root"
  # noatime では fresh な build の読み込みが atime を動かさず使用が見えないため atime を更新しない mount での unit の回収は不可
  mount_options=$(findmnt -n -o OPTIONS --target "$cargo_build_root") || mount_options=''
  case ",$mount_options," in
    ,,|*,noatime,*)
      note "cannot judge when Cargo units were used: $cargo_build_root does not update atime (mount options: ${mount_options:-unknown})"
      unresolved=true
      units_judgeable=false
      ;;
  esac
fi

declare -a group_kinds=() group_used=() group_used_exact=() group_bytes=() group_entries=() group_reasons=()
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
  if [ "${group_kinds[group]}" = orphan ]; then
    group_reasons[group]=orphan
    inactive_groups+=("$group")
  elif [ "${group_used[group]}" -lt "$inactive_before" ]; then
    group_reasons[group]=inactive
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
      group_reasons[group]=pressure
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

retire_verification_legacy

[ "$dry_run" = true ] || empty_trash

if [ "$total_bytes" -gt "$high_bytes" ] && [ "$active_session_count" -eq 0 ]; then
  purged=false
  if [ "$dry_run" = true ]; then
    if [ -d "$shared_root/cargo-home" ]; then
      shared_bytes=$(($(allocated_bytes "$shared_root/cargo-home") + $(allocated_bytes "$shared_root/xdg-cache")))
      report retire shared-cache "$shared_bytes" "$shared_root" over-high-without-session
      total_bytes=$((total_bytes - shared_bytes))
      purged=true
    fi
  else
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
  fi
  if [ "$purged" = true ]; then
    if [ "$dry_run" = false ]; then
      empty_trash
      total_bytes=$(($(allocated_bytes "$shared_root") + $(allocated_bytes "$cargo_build_root")))
    fi
    # 48 時間の保護と lock で見送った unit による超過は時間で解消するため共有 cache を空にした後の上限超過だけでの失敗は不可
    if [ "$((total_bytes - units_left))" -gt "$high_bytes" ]; then
      report_summary
      die "cache content the GC cannot reclaim stays above the high watermark after shared purge"
    fi
  fi
elif [ "$total_bytes" -gt "$high_bytes" ]; then
  report keep shared-cache - "$shared_root" active-session
fi

if [ "$total_bytes" -gt "$high_bytes" ]; then
  note "allocated cache bytes remain above the high watermark: $total_bytes > $high_bytes"
fi
report_summary

if [ "$unresolved" = true ]; then
  die 'agent cache entries remain unresolved'
fi
