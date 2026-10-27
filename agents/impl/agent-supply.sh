manifest=$(cat <<'DOTFILES_AGENT_SUPPLY_MANIFEST'
@manifest@
DOTFILES_AGENT_SUPPLY_MANIFEST
)

if [[ ${1:-} == "manifest" || ${1:-} == "--print-manifest" ]]; then
  jq . <<<"$manifest"
  exit 0
fi

usage() {
  cat <<'USAGE'
usage: dotfiles-agent-supply init
       dotfiles-agent-supply update [--automatic] [CLIENT...]
       dotfiles-agent-supply rollback CLIENT
       dotfiles-agent-supply status [--json] [CLIENT...]
       dotfiles-agent-supply manifest

The only writer of the per-client native Nix profiles of the adopted agent clients.
init creates a missing profile from the locked baseline and never moves an existing one.
update builds and probes the latest supply revision and publishes only a probed success.
rollback switches one profile to its previous generation without fetching or building.
Run as the target user, not root.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

source_ref=@sourceRef@
system_name=@system@
home_dir=@homeDir@
profile_root_relative=@profileRootRelative@
legacy_root_relative=@legacyRootRelative@
store_dir=@nixStoreDir@
transaction_hook=@transactionHook@

probe_timeout_seconds=10
probe_kill_grace_seconds=2
probe_path=/usr/bin:/bin
rejected_limit=8

fail() { echo "FATAL: $*" >&2; exit 1; }
usage_error() { echo "dotfiles-agent-supply: $*" >&2; usage >&2; exit 64; }
log() { printf '== %s\n' "$*"; }

[[ ${EUID} -ne 0 ]] || fail "run as the target user, not root"
[[ ${HOME:-} == "$home_dir" ]] || fail "HOME must be the declared home directory: $home_dir"

for command in cut date env find flock head id jq mkdir mktemp mv nix nix-env readlink realpath rm sort stat timeout; do
  command -v "$command" >/dev/null 2>&1 || fail "$command not found in PATH"
done

uid=$(id -u)
profile_root=$HOME/$profile_root_relative
legacy_root=$HOME/$legacy_root_relative

# client ごとの処理の文脈。worker と status だけが設定する
client=
binary=
package=
baseline=
client_root=
profile=
candidate=
receipt=
lock_fd=
legacy_fd=
work_dir=
candidate_pending=0
receipt_temporary=
probe_version=
latest_revision=
current_generation=
declare -a version_args=()
declare -a bound_paths=()
declare -a bound_ids=()
declare -a generations=()

# cancellation の状態。外部取消は実行中の子の終了を待ち、次の client を始めない
cancelled=0
cancel_status=0
child_pid=
child_cancellable=0
child_signalled=0

client_fail() {
  printf '%s: %s\n' "${client:-dotfiles-agent-supply}" "$*" >&2
  exit 1
}

foreign_object() {
  client_fail "foreign or unowned object in the client profile root, refusing to touch it: $1"
}

check_cancelled() {
  if ((cancelled)); then
    exit "$cancel_status"
  fi
}

worker_signal() {
  cancelled=1
  cancel_status=$1
  if [[ -n $child_pid && $child_cancellable == 1 && $child_signalled == 0 ]]; then
    child_signalled=1
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
}

# 取消方式に従う子処理の開始と実際の終了結果の回収
# 引数 $1: TERM を転送する cancellable か開始済みの完了を待つ critical
# 引数 $2以降: 子として起動する command と引数
# 戻り値: 回収した子の終了 status
# 失敗: 開始前か子の非0終了時に記録済みの取消での取消 status による worker 終了
# 失敗: 回収結果を取得できない子に対する127
run_child() {
  local mode=$1 reaped='' status
  # trap は開始確認から pid 登録までにも入るため親側の開始前確認だけでの取消同期は不可
  check_cancelled
  shift
  child_cancellable=0
  if [[ $mode == cancellable ]]; then
    child_cancellable=1
  fi
  child_signalled=0
  (
    check_cancelled
    exec "$@"
  ) &
  child_pid=$!
  if ((cancelled)); then
    worker_signal "$cancel_status"
  fi
  # 中断された wait の 128 + signal は子自身の終了 status と区別できないため $? による完了の判定は不可
  # 子として知らない pid の wait は reaped を空のまま 127 を返し続けるため reaped だけの終了判定は不可
  while :; do
    status=0
    wait -p reaped "$child_pid" || status=$?
    if [[ -n ${reaped-} || $status == 127 ]]; then
      break
    fi
  done
  child_pid=
  if [[ -n ${reaped-} && $status != 0 ]]; then
    check_cancelled
  fi
  return "$status"
}

run_hook() {
  "$transaction_hook" "$1" "$client" "$client_root" || client_fail "transaction hook failed at $1"
}

valid_store_path() {
  [[ $1 =~ ^"$store_dir"/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+$ ]]
}

is_adopted() {
  jq -e --arg name "$1" 'any(.[]; .name == $name)' <<<"$manifest" >/dev/null
}

adopted_names() {
  jq -r '.[].name' <<<"$manifest"
}

automatic_names() {
  jq -r '.[] | select(.automatic) | .name' <<<"$manifest"
}

owned_real_directory() {
  local path=$1 label=$2 owner mode

  [[ -d $path && ! -L $path ]] || client_fail "$label must be a real directory: $path"
  owner=$(stat -c %u -- "$path") || client_fail "cannot read owner for $label: $path"
  [[ $owner == "$uid" ]] || client_fail "$label has a foreign owner: $path"
  mode=$(stat -c %a -- "$path") || client_fail "cannot read mode for $label: $path"
  [[ $mode =~ ^[0-7]{3,4}$ ]] || client_fail "invalid mode for $label: $path"
  (( (8#$mode & 0022) == 0 )) || client_fail "$label is group/other writable: $path"
}

ensure_owned_directory() {
  local path=$1 mode=$2 label=$3

  if [[ -e $path || -L $path ]]; then
    owned_real_directory "$path" "$label"
    return
  fi
  if ! mkdir -m "$mode" -- "$path" 2>/dev/null; then
    [[ -e $path || -L $path ]] || client_fail "cannot create $label: $path"
  fi
  owned_real_directory "$path" "$label"
}

bind_directory() {
  bound_paths+=("$1")
  bound_ids+=("$(stat -c '%d:%i' -- "$1")")
}

# path で確認した directory を identity で束縛し、更新の前後で同じ object であることを照合する。
# nix-env は path を受けるため fd 経由では呼べず、同一 UID の悪意ある差替えまでは防がない
verify_bindings() {
  local index
  for index in "${!bound_paths[@]}"; do
    [[ -d ${bound_paths[index]} && ! -L ${bound_paths[index]} ]] \
      || client_fail "supply directory was replaced: ${bound_paths[index]}"
    [[ $(stat -c '%d:%i' -- "${bound_paths[index]}") == "${bound_ids[index]}" ]] \
      || client_fail "supply directory identity changed: ${bound_paths[index]}"
  done
}

describe_client() {
  local record
  is_adopted "$1" || usage_error "client is not adopted: $1"
  record=$(jq -ec --arg name "$1" '.[] | select(.name == $name)' <<<"$manifest")
  client=$1
  binary=$(jq -r '.binary' <<<"$record")
  package=$(jq -r '.package' <<<"$record")
  baseline=$(jq -r '.baseline' <<<"$record")
  mapfile -d '' -t version_args < <(jq --join-output '.versionArgs[] | ., "\u0000"' <<<"$record")
  client_root=$profile_root/$client
  profile=$client_root/profile
  candidate=$client_root/candidate
  receipt=$client_root/receipt.json
}

prepare_roots() {
  bound_paths=()
  bound_ids=()
  owned_real_directory "$HOME" "HOME"
  bind_directory "$HOME"
  ensure_owned_directory "$HOME/.local" 0755 "managed directory"
  bind_directory "$HOME/.local"
  ensure_owned_directory "$HOME/.local/share" 0755 "managed directory"
  bind_directory "$HOME/.local/share"
  ensure_owned_directory "$HOME/.local/share/dotfiles" 0755 "managed directory"
  bind_directory "$HOME/.local/share/dotfiles"
  ensure_owned_directory "$profile_root" 0700 "agent profile root"
  bind_directory "$profile_root"
  ensure_owned_directory "$client_root" 0700 "client profile root"
  bind_directory "$client_root"
}

# 同じ client の writer は一つだけにする。供給方式の切替で戻した旧 release writer も
# client root の lock を取るため、旧 root が残る間は同じ client で並走しない
acquire_lock() {
  exec {lock_fd}<"$client_root" || client_fail "cannot open the client profile root for locking"
  [[ $(stat -L -c '%d:%i' -- "/proc/self/fd/$lock_fd") == "${bound_ids[-1]}" ]] \
    || client_fail "client profile root changed while opening it"
  flock -n "$lock_fd" || client_fail "another supply operation owns this profile"
  if [[ -d $legacy_root/$client && ! -L $legacy_root/$client \
    && $(stat -c %u -- "$legacy_root/$client") == "$uid" ]]; then
    exec {legacy_fd}<"$legacy_root/$client" || client_fail "cannot open the legacy release root"
    flock -n "$legacy_fd" || client_fail "the legacy release writer owns this client"
  fi
}

# 前回が強制終了した場合の receipt の一時 file の除去
# 前提: client root の lock の保持
# 副作用: client root 直下で .receipt.XXXXXX の名前と自分の所有と mode 0600 を満たす通常 file の削除
# 名前だけでの一括除去は利用者の file を巻込むため型と所有と mode の照合が必須
discard_stale_receipt_temporaries() {
  LC_ALL=C find "$client_root" -mindepth 1 -maxdepth 1 -type f -uid "$uid" -perm 600 \
    -regextype posix-extended -regex '.*/\.receipt\.[A-Za-z0-9]{6}' -delete \
    || client_fail "cannot remove an abandoned receipt temporary"
}

validate_generation_link() {
  local link=$1 target
  [[ -L $link ]] || foreign_object "$link"
  [[ $(stat -c %u -- "$link") == "$uid" ]] || foreign_object "$link"
  target=$(readlink -- "$link") || foreign_object "$link"
  valid_store_path "$target" || foreign_object "$link"
}

# profile と世代 link を全て検証する。更新と削除は、ここで検証した object にだけ触れる
load_profile_state() {
  local entry name target number
  local -a numbers=()
  generations=()
  current_generation=
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    [[ $name =~ ^profile-[0-9]+-link$ ]] || continue
    [[ $name =~ ^profile-([1-9][0-9]*)-link$ ]] || foreign_object "$entry"
    number=${BASH_REMATCH[1]}
    validate_generation_link "$entry"
    numbers+=("$number")
  done < <(find "$client_root" -mindepth 1 -maxdepth 1 -name 'profile-*-link' -print0)
  if ((${#numbers[@]} > 0)); then
    mapfile -t generations < <(printf '%s\n' "${numbers[@]}" | sort -n)
  fi
  read_receipt >/dev/null
  if [[ -e $profile || -L $profile ]]; then
    [[ -L $profile ]] || foreign_object "$profile"
    [[ $(stat -c %u -- "$profile") == "$uid" ]] || foreign_object "$profile"
    target=$(readlink -- "$profile") || foreign_object "$profile"
    [[ $target =~ ^profile-([1-9][0-9]*)-link$ ]] || foreign_object "$profile"
    current_generation=${BASH_REMATCH[1]}
    [[ " ${generations[*]} " == *" $current_generation "* ]] || foreign_object "$profile"
  fi
}

generation_store_path() {
  readlink -- "$client_root/profile-$1-link"
}

previous_generation() {
  local number previous=
  for number in "${generations[@]}"; do
    if ((number < current_generation)); then
      previous=$number
    fi
  done
  printf '%s' "$previous"
}

prepare_work() {
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-agent-supply.XXXXXX") \
    || client_fail "cannot create a scratch directory"
}

worker_cleanup() {
  if ((candidate_pending == 1)) && [[ -L $candidate && $(stat -c %u -- "$candidate") == "$uid" ]]; then
    rm -f -- "$candidate"
  fi
  if [[ -n $receipt_temporary ]]; then
    rm -f -- "$receipt_temporary"
  fi
  if [[ -n $work_dir && -d $work_dir && ! -L $work_dir ]]; then
    rm -rf -- "$work_dir"
  fi
}

# 版の観測は空環境で、期限付きで行う。公開前の候補と、戻し先の世代の両方に使う
probe_store_path() {
  local store_path=$1 executable=$1/bin/$binary home status=0
  [[ -f $executable && -x $executable ]] || return 1
  home=$work_dir/probe-home
  mkdir -m 0700 -- "$home" || return 1
  run_child cancellable timeout --kill-after="$probe_kill_grace_seconds" "$probe_timeout_seconds" \
    env -i HOME="$home" PATH="$probe_path" LC_ALL=C "$executable" "${version_args[@]}" \
    >"$work_dir/probe.out" 2>"$work_dir/probe.err" </dev/null || status=$?
  rm -rf -- "$home"
  ((status == 0)) || return 1
  probe_version=$(head -n 1 "$work_dir/probe.out" | cut -c 1-200)
}

read_receipt() {
  if [[ -e $receipt || -L $receipt ]]; then
    [[ -f $receipt && ! -L $receipt && $(stat -c %u -- "$receipt") == "$uid" ]] \
      || foreign_object "$receipt"
    jq -ec . <"$receipt" || foreign_object "$receipt"
  else
    printf '{}\n'
  fi
}

write_receipt() {
  receipt_temporary=$(mktemp -p "$client_root" '.receipt.XXXXXX') \
    || client_fail "cannot create the receipt"
  printf '%s\n' "$1" >"$receipt_temporary"
  mv -T -- "$receipt_temporary" "$receipt" || client_fail "cannot publish the receipt"
  receipt_temporary=
}

record_generation() {
  local number=$1 event=$2 revision=$3 store_path=$4 version=$5 now document
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  document=$(read_receipt)
  document=$(jq -c --arg client "$client" --arg number "$number" --arg path "$store_path" \
    --arg event "$event" --arg revision "$revision" --arg version "$version" \
    --arg source "$source_ref" --arg at "$now" '
      .schema = 1 | .client = $client
      | .generations[$number] = {
          storePath: $path, event: $event, revision: $revision,
          version: $version, source: $source, at: $at
        }
    ' <<<"$document")
  write_receipt "$document"
}

# 直近の拒否版による更新時の再公開抑止の記録
# 引数 $1: rollback で拒否した版の store path
# 副作用: 当該 client の receipt への直近8件の拒否順での確定
# 戻り値: receipt の確定成功時の0
reject_store_path() {
  local document
  document=$(read_receipt)
  document=$(jq -c --arg path "$1" --argjson limit "$rejected_limit" '
    .rejected = ((.rejected // []) - [$path] + [$path] | .[(0 - $limit):])
  ' <<<"$document")
  write_receipt "$document"
}

prune_receipt() {
  local document keep='[]'
  document=$(read_receipt)
  if ((${#generations[@]} > 0)); then
    keep=$(printf '%s\n' "${generations[@]}" | jq -R . | jq -sc .)
  fi
  document=$(jq -c --argjson keep "$keep" '
    .generations |= ((. // {}) | with_entries(select(.key as $key | $keep | index($key) != null)))
  ' <<<"$document")
  write_receipt "$document"
}

# 世代を native profile の契約で切り替える。切替後は解決先まで確認し、確認できない公開を成功にしない
switch_profile() {
  local store_path=$1 resolved
  run_hook before-publish
  verify_bindings
  load_profile_state
  run_child critical nix-env --profile "$profile" --quiet --set "$store_path" \
    || client_fail "nix-env could not publish the candidate"
  load_profile_state
  resolved=$(readlink -f -- "$profile") || client_fail "the published profile does not resolve"
  [[ $resolved == "$store_path" ]] \
    || client_fail "the published profile resolves to $resolved, not to the candidate"
  verify_bindings
  run_hook after-publish
}

delete_generations() {
  local -a doomed=("$@")
  if ((${#doomed[@]} == 0)); then
    return 0
  fi
  run_hook before-retention
  verify_bindings
  run_child critical nix-env --profile "$profile" --quiet --delete-generations "${doomed[@]}" \
    || client_fail "nix-env could not delete generations: ${doomed[*]}"
  load_profile_state
  run_hook after-retention
}

# current より新しい世代は、切替前に中断した公開か戻し済みの世代であり、検証済みの版ではない。
# 次の「直前の世代」にしないよう除く
drop_unpublished_generations() {
  local number
  local -a doomed=()
  for number in "${generations[@]}"; do
    if ((number > current_generation)); then
      doomed+=("$number")
    fi
  done
  delete_generations "${doomed[@]}"
  load_profile_state
}

# current と直前の世代だけを残す
retain_generations() {
  local previous number
  local -a doomed=()
  load_profile_state
  drop_unpublished_generations
  previous=$(previous_generation)
  for number in "${generations[@]}"; do
    if [[ $number != "$current_generation" && $number != "$previous" ]]; then
      doomed+=("$number")
    fi
  done
  delete_generations "${doomed[@]}"
  load_profile_state
  prune_receipt
}

discard_candidate() {
  if [[ -L $candidate ]]; then
    [[ $(stat -c %u -- "$candidate") == "$uid" ]] || foreign_object "$candidate"
    rm -f -- "$candidate"
  elif [[ -e $candidate ]]; then
    foreign_object "$candidate"
  fi
  candidate_pending=0
}

# 前回が強制終了した場合の古い候補 root は、自分の symlink だけ除く
prepare_candidate_root() {
  discard_candidate
  candidate_pending=1
}

initialize_locked() {
  local store_path=$baseline
  valid_store_path "$store_path" || client_fail "the locked baseline is not a store path: $store_path"
  [[ -d $store_path && ! -L $store_path ]] \
    || client_fail "the locked baseline is not present in the store: $store_path"
  probe_store_path "$store_path" || client_fail "the locked baseline failed its version probe"
  switch_profile "$store_path"
  record_generation "$current_generation" init baseline "$store_path" "$probe_version"
  retain_generations
  log "$client: initialized from the locked baseline ($probe_version)"
}

op_init() {
  describe_client "$1"
  prepare_roots
  acquire_lock
  discard_stale_receipt_temporaries
  prepare_work
  load_profile_state
  if [[ -n $current_generation ]]; then
    log "$client: profile exists, keeping it"
    return 0
  fi
  initialize_locked
}

resolve_latest_revision() {
  run_child cancellable nix flake metadata --refresh --json "$source_ref" >"$work_dir/metadata.json" \
    || return 1
  latest_revision=$(jq -er '.locked.rev | select(type == "string" and test("^[0-9a-f]{40}$"))' \
    "$work_dir/metadata.json") || return 1
}

op_update() {
  local installable built current_path document recorded
  describe_client "$1"
  prepare_roots
  acquire_lock
  discard_stale_receipt_temporaries
  prepare_work
  load_profile_state
  if [[ -z $current_generation ]]; then
    initialize_locked
  else
    drop_unpublished_generations
  fi
  check_cancelled

  if ! resolve_latest_revision; then
    check_cancelled
    client_fail "cannot resolve the latest supply revision of $source_ref"
  fi
  current_path=$(generation_store_path "$current_generation")
  document=$(read_receipt)
  recorded=$(jq -r --arg number "$current_generation" '.generations[$number].revision // ""' <<<"$document")
  if [[ $recorded == "$latest_revision" ]]; then
    log "$client: already at supply revision $latest_revision"
    return 0
  fi

  installable="$source_ref/$latest_revision#packages.$system_name.$package"
  prepare_candidate_root
  log "$client: building $installable"
  if ! run_child cancellable nix build --no-write-lock-file --out-link "$candidate" "$installable"; then
    check_cancelled
    client_fail "build failed for supply revision $latest_revision, keeping the current version"
  fi
  check_cancelled
  built=$(readlink -- "$candidate") || client_fail "the build produced no candidate root"
  valid_store_path "$built" || client_fail "the candidate is not a store path: $built"
  [[ $(realpath -e -- "$built") == "$built" ]] \
    || client_fail "the candidate is not a plain store directory: $built"
  run_hook candidate-built

  if [[ $built == "$current_path" ]]; then
    log "$client: supply revision $latest_revision builds the current version"
    discard_candidate
    return 0
  fi
  if jq -e --arg path "$built" '(.rejected // []) | index($path) != null' <<<"$document" >/dev/null; then
    log "$client: supply revision $latest_revision builds a version that was rolled back, keeping the current version"
    discard_candidate
    return 0
  fi
  if ! probe_store_path "$built"; then
    check_cancelled
    client_fail "the candidate from supply revision $latest_revision failed its version probe, keeping the current version"
  fi
  check_cancelled

  switch_profile "$built"
  record_generation "$current_generation" update "$latest_revision" "$built" "$probe_version"
  discard_candidate
  retain_generations
  log "$client: published supply revision $latest_revision ($probe_version)"
}

op_rollback() {
  local previous previous_path abandoned
  describe_client "$1"
  prepare_roots
  acquire_lock
  discard_stale_receipt_temporaries
  prepare_work
  load_profile_state
  [[ -n $current_generation ]] || client_fail "no profile to roll back"
  previous=$(previous_generation)
  [[ -n $previous ]] || client_fail "no previous generation is retained"
  abandoned=$(generation_store_path "$current_generation")
  previous_path=$(generation_store_path "$previous")
  [[ -d $previous_path ]] \
    || client_fail "the previous generation is no longer present in the store: $previous_path"
  probe_store_path "$previous_path" || client_fail "the previous generation failed its version probe"

  run_hook before-publish
  verify_bindings
  run_child critical nix-env --profile "$profile" --quiet --switch-generation "$previous" \
    || client_fail "nix-env could not switch to generation $previous"
  load_profile_state
  [[ $(readlink -f -- "$profile") == "$previous_path" ]] \
    || client_fail "the profile does not resolve to the previous generation after switching"
  verify_bindings
  run_hook after-publish

  # 戻した版を次の更新が同じ store path で再公開しないよう記録し、戻し済みの世代を除く
  reject_store_path "$abandoned"
  drop_unpublished_generations
  prune_receipt
  log "$client: rolled back to generation $current_generation ($probe_version)"
}

# 親の set +e を継がず、errexit と後片付けの trap を自前で持ち直す
worker_main() {
  local operation=$1 name=$2
  set -e
  client=$name
  trap 'worker_signal 130' INT
  trap 'worker_signal 143' TERM HUP
  trap worker_cleanup EXIT
  case $operation in
    init) op_init "$name" ;;
    update) op_update "$name" ;;
    rollback) op_rollback "$name" ;;
    *) client_fail "unknown operation: $operation" ;;
  esac
}

worker_pid=
parent_signal() {
  cancelled=1
  cancel_status=$1
  if [[ -n $worker_pid ]]; then
    kill -TERM "$worker_pid" 2>/dev/null || true
  fi
}

# subshell に閉じた client 一件の処理の起動と実際の終了結果の回収
# 引数 $1: worker が実行する operation の init・update・rollback
# 引数 $2: worker が処理する client 名
# 戻り値: 回収した worker の実際の終了 status
# 副作用: 取消の記録後に起動した worker の client 処理前での終了
# 副作用: 起動から pid 登録までに記録した取消の worker への転送
# 失敗: 回収結果を取得できない worker に対する127
run_worker() {
  local reaped='' status
  # trap は run_each の確認から fork までにも入るため run_each の開始前確認だけでの取消同期は不可
  ( check_cancelled; worker_main "$1" "$2" ) &
  worker_pid=$!
  # pid 登録前の parent_signal は転送先を持たないため trap だけでの worker への取消転送は不可
  if ((cancelled)); then
    parent_signal "$cancel_status"
  fi
  # wait の完了判定は run_child と同じ制約に従うため $? 単独と reaped 単独での判定は不可
  while :; do
    status=0
    wait -p reaped "$worker_pid" || status=$?
    if [[ -n ${reaped-} || $status == 127 ]]; then
      break
    fi
  done
  worker_pid=
  return "$status"
}

run_each() {
  local operation=$1 name status
  shift
  local -a failed=() skipped=()
  trap 'parent_signal 130' INT
  trap 'parent_signal 143' TERM HUP
  for name in "$@"; do
    if ((cancelled)); then
      skipped+=("$name")
      continue
    fi
    set +e
    run_worker "$operation" "$name"
    status=$?
    set -e
    if ((status != 0 && cancelled == 0)); then
      failed+=("$name")
    fi
  done
  if ((cancelled)); then
    echo "FATAL: cancelled; not started: ${skipped[*]:-none}" >&2
    exit "$cancel_status"
  fi
  if ((${#failed[@]} > 0)); then
    echo "FATAL: client supply failed: ${failed[*]}" >&2
    exit 1
  fi
}

# 観測だけを行い、directory の作成も lock も取らない
status_row() {
  local state=uninitialized previous='' store_path='' version='' revision=''
  describe_client "$1"
  trap worker_cleanup EXIT
  prepare_work
  if [[ -d $client_root ]]; then
    load_profile_state
    if [[ -n $current_generation ]]; then
      state=ready
      previous=$(previous_generation)
      store_path=$(generation_store_path "$current_generation")
      if probe_store_path "$store_path"; then
        version=$probe_version
      fi
      revision=$(read_receipt | jq -r --arg number "$current_generation" '.generations[$number].revision // ""')
    fi
  fi
  jq -nc --arg client "$client" --arg state "$state" --arg generation "$current_generation" \
    --arg previous "$previous" --arg storePath "$store_path" --arg version "$version" \
    --arg revision "$revision" --arg source "$source_ref" '
      def nullable: if . == "" then null else . end;
      {client: $client, state: $state, source: $source,
       generation: ($generation | nullable | if . == null then null else tonumber end),
       previous: ($previous | nullable | if . == null then null else tonumber end),
       storePath: ($storePath | nullable), version: ($version | nullable),
       revision: ($revision | nullable)}
    '
}

command_name=${1:-}
[[ -n $command_name ]] || usage_error "a command is required"
shift

case $command_name in
  init)
    (($# == 0)) || usage_error "init takes no arguments"
    mapfile -t targets < <(adopted_names)
    run_each init "${targets[@]}"
    ;;
  update)
    automatic=0
    targets=()
    for argument in "$@"; do
      case $argument in
        --automatic) automatic=1 ;;
        -*) usage_error "unknown option: $argument" ;;
        *) targets+=("$argument") ;;
      esac
    done
    if ((${#targets[@]} > 0 && automatic)); then
      usage_error "--automatic selects the automatic subset and cannot be combined with client names"
    fi
    if ((${#targets[@]} == 0)); then
      if ((automatic)); then
        mapfile -t targets < <(automatic_names)
      else
        mapfile -t targets < <(adopted_names)
      fi
    fi
    if ((${#targets[@]} == 0)); then
      log "no client to update"
      exit 0
    fi
    for argument in "${targets[@]}"; do
      is_adopted "$argument" || usage_error "client is not adopted: $argument"
    done
    run_each update "${targets[@]}"
    ;;
  rollback)
    (($# == 1)) || usage_error "rollback takes exactly one client"
    is_adopted "$1" || usage_error "client is not adopted: $1"
    run_each rollback "$1"
    ;;
  status)
    json=0
    targets=()
    for argument in "$@"; do
      case $argument in
        --json) json=1 ;;
        -*) usage_error "unknown option: $argument" ;;
        *) targets+=("$argument") ;;
      esac
    done
    if ((${#targets[@]} == 0)); then
      mapfile -t targets < <(adopted_names)
    fi
    rows=()
    failed=()
    for argument in "${targets[@]}"; do
      is_adopted "$argument" || usage_error "client is not adopted: $argument"
      if row=$(status_row "$argument"); then
        rows+=("$row")
      else
        failed+=("$argument")
      fi
    done
    if ((${#rows[@]} > 0)); then
      if ((json)); then
        printf '%s\n' "${rows[@]}" | jq -s .
      else
        printf '%s\n' "${rows[@]}" | jq -r '[.client, .state, (.generation // "-" | tostring), (.version // "-"), (.revision // "-"), (.storePath // "-")] | @tsv'
      fi
    fi
    if ((${#failed[@]} > 0)); then
      echo "FATAL: client status failed: ${failed[*]}" >&2
      exit 1
    fi
    ;;
  *)
    usage_error "unknown command: $command_name"
    ;;
esac
