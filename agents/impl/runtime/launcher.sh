# shellcheck disable=SC2329 # run_bounded と trap が関数を名前で呼ぶ。
set -euo pipefail

# 台帳の I/O と reaper の gc.lock のために起動と後始末が増やしてよい待ち。使用中の資源を回収して縮めない。
ledger_wait_seconds=5
# 終了を始めてから SIGKILL までの猶予と、SIGKILL 後に終了を確認する猶予。期限の到達は完了ではない。
term_grace_seconds=10
kill_grace_seconds=5
# supervisor が先に消えた後に scope の残存 process を kill してから、空になるのを見届ける猶予。
scope_settle_seconds=10

session_dir=''
supervisor_pid=''
launched=false
cancel_requested=false
cancel_status=0
protected_dependencies=()

die() {
  printf 'dotfiles-agent-runtime: %s\n' "$1" >&2
  exit 70
}

note() {
  printf 'dotfiles-agent-runtime: %s\n' "$1" >&2
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


now_microseconds() {
  printf '%s\n' "${EPOCHREALTIME//[.,]/}"
}

# 期限(マイクロ秒)までの残りを flock の -w が読める秒で出す。残りが無ければ最短の待ちにする。
seconds_until() {
  local remaining
  remaining=$(($1 - $(now_microseconds)))
  [ "$remaining" -gt 0 ] || remaining=1000
  printf '%d.%06d\n' "$((remaining / 1000000))" "$((remaining % 1000000))"
}

# function を subshell で期限まで実行する。期限を過ぎたら 124 を返し、停止した I/O の終了を待たない。
run_bounded() {
  local deadline=$1 pid
  shift
  ("$@") &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(now_microseconds)" -ge "$deadline" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.02
  done
  wait "$pid"
}

# shellcheck disable=SC2329 # run_bounded が名前で呼ぶ。
register_session() {
  # 台帳の登録は lock を握る親の下で行い、停止した I/O が親の lock の解放を引き延ばさないよう fd は渡さない。
  exec {lock_fd}>&-
  mkdir -m 700 "$session_dir" || die "cannot create the session directory: $session_dir"
  mkdir -m 700 "$session_dir/roots"
  if [ "$managed_tmp" = true ]; then
    mkdir -m 700 "$session_dir/tmp"
  fi
  local shared_root="$cache_root/shared" marker marker_tmp created=false
  marker="$shared_root/.dotfiles-agent-cache.json"
  if mkdir -m 700 "$shared_root" 2>/dev/null; then
    created=true
  else
    test ! -L "$shared_root" || die "shared cache is a symlink: $shared_root"
    test -d "$shared_root" || die "shared cache is not a directory: $shared_root"
    test "$(stat -c %u "$shared_root")" = "$(id -u)" \
      || die "shared cache has another owner: $shared_root"
  fi
  chmod 700 "$shared_root" || die "cannot secure shared cache: $shared_root"
  test "$(stat -c %a "$shared_root")" = 700 \
    || die "shared cache mode is not 0700: $shared_root"
  if [ "$created" = true ]; then
    marker_tmp=$(mktemp "$shared_root/.owner.XXXXXXXX")
    jq -cn '{version: 1, kind: "shared-cache"}' > "$marker_tmp"
    chmod 600 "$marker_tmp"
    mv -T "$marker_tmp" "$marker"
  fi
  secure_managed_file "$marker" 'shared cache marker'
  jq --exit-status '. == {version: 1, kind: "shared-cache"}' "$marker" >/dev/null \
    || die "shared cache marker is invalid: $marker"
  ensure_managed_directory "$shared_root/cargo-home"
  ensure_managed_directory "$shared_root/xdg-cache"
  local metadata_tmp
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
}

# shellcheck disable=SC2329 # run_bounded が名前で呼ぶ。
remove_session_directory() {
  rm -rf --one-file-system -- "$session_dir"
}

# session 中に git worktree add で作った worktree のうち、HEAD が作成時のままのものを削除する。
# git worktree remove は変更、untracked file、lock を持つ worktree を拒むので、それらは残る。
# Orca が作った worktree は記録されず、寿命は Orca が持つ。
remove_session_worktrees() {
  local record=$1 index path head
  local -a fields=()

  if [ ! -f "$record" ] || [ -L "$record" ]; then
    return 0
  fi
  mapfile -d '' -t fields <"$record" || return 0
  for ((index = 0; index + 1 < ${#fields[@]}; index += 2)); do
    path=${fields[index]}
    head=${fields[index + 1]}
    if [ "$(git -C "$path" rev-parse --verify --quiet HEAD 2>/dev/null)" = "$head" ]; then
      git -C "$path" worktree remove -- "$path" >/dev/null 2>&1 || true
    fi
  done
}

managed_session_directory() {
  [ -n "$session_dir" ] \
    && [[ "$session_dir" == "$sessions_root/"* ]] \
    && [ ! -L "$session_dir" ] \
    && [ -d "$session_dir" ]
}

# 起動前の失敗と取消では、clientも子も存在しない。作った台帳だけを戻す。
# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup_unstarted() {
  local status=$?
  trap - EXIT HUP INT TERM QUIT
  if [ "$launched" = false ] && managed_session_directory; then
    run_bounded "$(($(now_microseconds) + ledger_wait_seconds * 1000000))" remove_session_directory || true
  fi
  exit "$status"
}

# shellcheck disable=SC2329 # signal traps invoke this function indirectly.
on_cancel() {
  cancel_status=$1
  cancel_requested=true
  if [ -n "$supervisor_pid" ]; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
  fi
}

abort_if_cancelled() {
  if [ "$cancel_requested" = true ]; then
    note 'cancelled before the client started'
    exit "$cancel_status"
  fi
}

# --protect の依存と、profile から解決した実行 file を、client を起動する前に session の GC root へ置く。
while [ "${1-}" = --protect ]; do
  [ "$#" -ge 2 ] || die 'usage: dotfiles-agent-runtime [--protect STORE-PATH]... CLIENT ABSOLUTE-EXECUTABLE [ARG...]'
  case "$2" in
    /nix/store/*) ;;
    *) die "protected dependency is not a store path: $2" ;;
  esac
  protected_dependencies+=("$2")
  shift 2
done
if [ "$#" -lt 2 ]; then
  die 'usage: dotfiles-agent-runtime [--protect STORE-PATH]... CLIENT ABSOLUTE-EXECUTABLE [ARG...]'
fi

client=$1
upstream=$2
shift 2

case "$client" in
  *[!A-Za-z0-9._-]*|''|-*) die "invalid client id: $client" ;;
esac
case "$upstream" in
  /*) ;;
  *) die "executable is not absolute: $upstream" ;;
esac
test -x "$upstream" || die "executable is not runnable: $upstream"
test -f "$upstream" || die "executable is not a file: $upstream"

trap cleanup_unstarted EXIT
trap 'on_cancel 129' HUP
trap 'on_cancel 130' INT
trap 'on_cancel 143' TERM

cache_root="$HOME/@cacheRootRelative@"
sessions_root="$cache_root/sessions"
cargo_build_root="$cache_root/cargo-build"
mkdir -p "$HOME/.cache"
ensure_managed_directory "$cache_root"
ensure_managed_directory "$sessions_root"
ensure_managed_directory "$cargo_build_root"

lock_file="$cache_root/gc.lock"
if (set -o noclobber; : > "$lock_file") 2>/dev/null; then
  chmod 600 "$lock_file"
fi
secure_managed_file "$lock_file" 'GC lock'

canonical_project=$(project_identity) || die 'cannot derive project identity'
project_id=$(printf '%s' "$canonical_project" | sha256sum | cut -d ' ' -f 1)

boot_id=$(cat /proc/sys/kernel/random/boot_id) || die 'cannot read boot id'
case "$boot_id" in
  *[!A-Fa-f0-9-]*|'') die 'invalid boot id' ;;
esac
owner_stat=$(<"/proc/$$/stat")
owner_start_time=$(awk '{print $20}' <<<"${owner_stat##*) }")
case "$owner_start_time" in
  *[!0-9]*|'') die 'cannot read owner process start time' ;;
esac

# 管理 scratch を与えるのは TMPDIR が未指定のときだけで、明示値(空文字列を含む)は利用者のものである。
# 外側の session が与えた scratch を引き継いだだけの TMPDIR は、明示値ではなく未指定として扱う。
managed_tmp=false
if [ "${TMPDIR+x}" != x ]; then
  managed_tmp=true
elif [ -n "${DOTFILES_AGENT_SESSION_ID-}" ] \
  && [ "$TMPDIR" = "$sessions_root/$DOTFILES_AGENT_SESSION_ID/tmp" ]; then
  managed_tmp=true
fi

session_suffix=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
session_id="${project_id}.${client}.$$.${session_suffix}"
session_dir="$sessions_root/$session_id"
scope_unit="dotfiles-agent-${session_id#"$project_id".}"

abort_if_cancelled

# lock の待ちと台帳の書込みを合わせて ledger_wait_seconds までにする。超えたら client を起動せず拒否する。
ledger_deadline=$(($(now_microseconds) + ledger_wait_seconds * 1000000))
exec {lock_fd}<>"$lock_file"
flock -w "$(seconds_until "$ledger_deadline")" -x "$lock_fd" \
  || die "gc.lock was not released within ${ledger_wait_seconds}s; the client was not started"
register_status=0
run_bounded "$ledger_deadline" register_session || register_status=$?
flock -u "$lock_fd" || true
exec {lock_fd}>&-
case "$register_status" in
  0) ;;
  124) die "the session ledger did not accept the session within ${ledger_wait_seconds}s; the client was not started" ;;
  *) exit "$register_status" ;;
esac
abort_if_cancelled

# 起動前の保護。root を取れない依存があれば、実行 file を一度も起動せずに拒否する。
launcher_path=$(realpath -e -- "${BASH_SOURCE[0]}")
protected=("$launcher_path" "${protected_dependencies[@]}")
upstream_physical=$(realpath -e -- "$upstream") || die "cannot resolve the executable: $upstream"
upstream_is_pinned=false
case "$upstream_physical" in
  /nix/store/*)
    upstream_is_pinned=true
    protected+=("$upstream")
    ;;
esac
if ! protected_output=$(@protectCommand@ --resolved "$session_dir/roots" "${protected[@]}"); then
  die 'cannot protect the execution dependencies; the client was not started'
fi
mapfile -t resolved_paths <<<"$protected_output"
[ "${#resolved_paths[@]}" -eq "${#protected[@]}" ] \
  || die 'the protection of the execution dependencies is incomplete; the client was not started'
# 保護した物理 path をそのまま起動し、保護と起動の間に profile が動いても別の版を実行しない。
# 起動した file が受け取る argv[0] は公開 path のままにする。symlink の名前で動作を選ぶ multi-call binary がある。
upstream_name=$upstream
if [ "$upstream_is_pinned" = true ]; then
  upstream=${resolved_paths[${#resolved_paths[@]} - 1]}
fi
abort_if_cancelled

export DOTFILES_AGENT_SESSION_ID=$session_id
export DOTFILES_AGENT_CLIENT=$client
export DOTFILES_AGENT_PROJECT_ID=$project_id
export DOTFILES_AGENT_WORKTREE_RECORD="$session_dir/worktrees"
if [ "$managed_tmp" = true ]; then
  export TMPDIR="$session_dir/tmp"
fi
export PATH="@gitShimDirectory@:$PATH"

uid=$(id -u)
scope_cgroup="${DOTFILES_AGENT_CGROUP_ROOT:-/sys/fs/cgroup}/user.slice/user-$uid.slice/user@$uid.service/@sliceUnit@/$scope_unit.scope"

scope_has_processes() {
  [ -r "$scope_cgroup/cgroup.procs" ] && read -r _ <"$scope_cgroup/cgroup.procs"
}

# 一つの操作の取消(SIGINT、SIGQUIT)は client の中の入力であり、session の終了ではない。
trap ':' INT QUIT

# supervisor が自分の scope の中で client を一度だけ起動し、子孫の終了を見届けてから返る。
# scope を作れなければ supervisor も client も起動しない。systemd-run は既定で引数の $ を展開するため、展開を止める。
result_file="$session_dir/supervisor.json"
exec 3<&0
launched=true
@systemdRunCommand@ --user --scope --quiet --collect --expand-environment=no \
  --slice=@sliceUnit@ --unit="$scope_unit.scope" \
  -- @superviseCommand@ --term-grace "$term_grace_seconds" --kill-grace "$kill_grace_seconds" \
  --result "$result_file" --argv0 "$upstream_name" -- "$upstream" "$@" 0<&3 3<&- &
supervisor_pid=$!
exec 3<&-

set +e
while :; do
  wait "$supervisor_pid"
  supervisor_status=$?
  kill -0 "$supervisor_pid" 2>/dev/null || break
done
set -e
supervisor_pid=''

started=false
final_status=$supervisor_status
if [ -s "$result_file" ] && jq -e '.phase != null' "$result_file" >/dev/null 2>&1; then
  started=true
elif [ "$cancel_requested" = true ]; then
  note 'cancelled before the client started'
  final_status=$cancel_status
else
  note 'the scope could not be created; the client was not started'
  final_status=70
fi

# 子の終了は supervisor の報告と scope の cgroup の両方で確かめる。scope が残る間は supervisor が消えていても
# client の子が動いているため、残りを止めて空になるのを見届けるまで roots と scratch を解かない。
drained=true
if [ "$started" = true ]; then
  drained=false
  if [ "$(jq -r '.phase' "$result_file")" = finished ] && [ "$(jq -r '.drained' "$result_file")" = true ]; then
    drained=true
  else
    note 'the supervisor did not confirm that every session process had ended'
  fi
  if [ -d "$scope_cgroup" ]; then
    if scope_has_processes; then
      note "the session scope still holds processes: $scope_unit.scope"
      @systemctlCommand@ --user kill --kill-whom=all --signal=SIGKILL "$scope_unit.scope" >/dev/null 2>&1 || true
      settle_deadline=$(($(now_microseconds) + scope_settle_seconds * 1000000))
      while scope_has_processes && [ "$(now_microseconds)" -lt "$settle_deadline" ]; do
        sleep 0.05
      done
    fi
    if scope_has_processes; then
      note "the session scope did not become empty: $scope_unit.scope"
      drained=false
    else
      drained=true
    fi
  fi
fi

# 全子の終了を確認した後だけ、worktree、GC root、管理 scratch を解放する。確認できなければ GC に残す。
if [ "$drained" = true ]; then
  remove_session_worktrees "$DOTFILES_AGENT_WORKTREE_RECORD"
  if managed_session_directory; then
    cleanup_deadline=$(($(now_microseconds) + ledger_wait_seconds * 1000000))
    cleanup_status=0
    run_bounded "$cleanup_deadline" remove_session_directory || cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ] || [ -e "$session_dir" ]; then
      note "cannot release the session resources; the reaper will reclaim them: $session_dir"
      drained=false
    fi
  fi
else
  note "the session resources stay with the reaper until the processes end: $session_dir"
fi

# client の終了値を保ち、後始末の失敗を成功へ畳まない。
if [ "$drained" = false ] && [ "$final_status" -eq 0 ]; then
  final_status=70
fi
trap - EXIT
exit "$final_status"
