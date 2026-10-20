usage() {
  cat <<'USAGE'
usage:
  dotfiles-rebuild [--plan]
  dotfiles-rebuild --candidate ID
  dotfiles-rebuild --discard ID
  dotfiles-rebuild --rollback [--plan]

Without options, copy the committed source into an isolated checkout, validate and build it with
flake.lock as committed, verify the committed source, and switch to exactly the candidate that
was built. No input is fetched or updated and nothing is written to the checkout. To move an
input, update it explicitly (nix flake update INPUT), commit flake.lock and run this command again.

--plan stops after the candidate is built and held by a Nix GC root. The checkout, HEAD,
index, flake.lock and the deployed system are not changed. The candidate is held until it
is applied with --candidate ID, released with --discard ID, or replaced by the next plan.
--candidate ID applies a held candidate. It is rejected, and no other candidate is built
in its place, when the candidate expired or no longer matches the checkout.
--discard ID also releases what a run kept because its supervisor could not confirm that every
process of a command had ended; no later run releases it, so confirm first that none runs.
--rollback selects the previous system generation that still exists. It never fetches
or builds. Apply and rollback share one writer; a second one is refused while it runs.
A failed activation can leave the profile and running services in different states;
inspect the system before retrying or rolling back. WSL is never terminated by this
command.

Exit status:
  0    completed (or the plan was produced)
  2    refused or failed; the checkout and the system are as they were
  3    switched, but a WSL boot transition is pending; this is not a completed switch
  4    the checkout changed while the command ran and the system was not switched
  5    activation started and failed or was interrupted; the system may be partial
  130  interrupted before anything changed
USAGE
}

interrupted=0
active_pid=
work_dir=
cand_dir=
cand_id=
cand_path=
retain_candidate=0
base_head=
checkout_real=
restart_plan=
verify_entry=
verify_budget=
child_result=
child_unconfirmed=0

dotfiles=@configuredDotfiles@
system_profile="@systemProfilePath@"
distro_name=@distroName@
host_name=@hostName@
store_dir=@nixStoreDir@
sudo_command=@sudoCommand@
nixos_rebuild=@nixosRebuild@
nvd=@nvd@
wsl_restart_required=@wslRestartRequired@
verification_entry=@verificationEntry@
agent_verify=@agentVerify@
supervise=@supervise@
client_executables=@clientExecutables@
child_grace_seconds=@childGraceSeconds@

plan_only=0
rollback=0
candidate_id=
discard_id=
while [[ $# -gt 0 ]]; do
  case "$1" in
  --plan)
    ((plan_only == 0)) || {
      usage >&2
      exit 2
    }
    plan_only=1
    ;;
  --rollback)
    ((rollback == 0)) || {
      usage >&2
      exit 2
    }
    rollback=1
    ;;
  --candidate)
    [[ $# -ge 2 && $2 =~ ^[0-9]+-[0-9]+$ && -z $candidate_id ]] || {
      usage >&2
      exit 2
    }
    candidate_id=$2
    shift
    ;;
  --discard)
    [[ $# -ge 2 && $2 =~ ^[0-9]+-[0-9]+$ && -z $discard_id ]] || {
      usage >&2
      exit 2
    }
    discard_id=$2
    shift
    ;;
  --help | -h)
    [[ $# -eq 1 && $plan_only -eq 0 && $rollback -eq 0 && -z $candidate_id && -z $discard_id ]] ||
      {
        usage >&2
        exit 2
      }
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

if [[ -n $candidate_id ]] && ((plan_only || rollback)); then
  usage >&2
  exit 2
fi
if [[ -n $discard_id ]] && ((plan_only || rollback)); then
  usage >&2
  exit 2
fi
if [[ -n $discard_id && -n $candidate_id ]]; then
  usage >&2
  exit 2
fi

# A repository hook runs with GIT_DIR and friends set; they would redirect every git call below.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

state_root=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-wsl/rebuild

die() {
  local status=$1
  [[ $interrupted -eq 0 ]] || status=130
  printf 'FATAL: %s\n' "$2" >&2
  exit "$status"
}

checkpoint() {
  [[ $interrupted -eq 0 ]] || die 130 "interrupted; nothing was changed"
}

# 走行が所有する作業directoryの解放
# $1: 解放対象の作業directory
# 前提: 子孫の終了確認または利用者による明示的なdiscard
# 戻り値: 解放成功時の0または失敗時の非0
release_work_dir() {
  rm -rf --one-file-system -- "$1"
}

# 終了statusを保った走行資源の条件付き解放
# 前提: EXIT trapからの呼出し
# 未確認の子孫: 作業directoryと候補rootの保持
# shellcheck disable=SC2329 # The EXIT trap invokes this function indirectly.
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $active_pid ]]; then
    kill -TERM "$active_pid" 2>/dev/null || true
    settle_child || true
  fi
  if ((child_unconfirmed == 0)); then
    if [[ -n $work_dir ]]; then
      release_work_dir "$work_dir" || printf 'WARN: could not release the work directory %s\n' "$work_dir" >&2
    fi
    if [[ -n $cand_dir && $retain_candidate -eq 0 ]]; then
      rm -rf --one-file-system -- "$cand_dir" || true
    fi
  fi
  exit "$status"
}

# supervisorは絶対pathの実行ファイルだけを受けるためPATH上の名前のまま渡すのは不可
# 親を失った build を継続しないため親の終了による取消の省略は不可
# 共通supervisor配下でのcommandの非同期起動
# $1: 子の作業directory
# $2: 標準出力の保存先または保存しないときの空文字列
# $3以降: 実行fileの名前またはpathと引数
# 副作用: active_pidとchild_resultへの起動状態の記録
# 戻り値: 起動時の0または取消時の130または実行fileの探索失敗時の127
start_child() {
  local dir=$1 out=$2 executable
  local -a supervised
  shift 2
  [[ $interrupted -eq 0 ]] || return 130
  executable=$(type -P "$1") || {
    printf 'FATAL: cannot find the executable %s\n' "$1" >&2
    return 127
  }
  shift
  child_result=$work_dir/supervisor.json
  rm -f -- "$child_result"
  supervised=("$supervise" --term-grace "$child_grace_seconds" --parent-death-cancels "$$" --result "$child_result" -- "$executable" "$@")
  if [[ -n $out ]]; then
    (
      cd -- "$dir" || exit 126
      exec "${supervised[@]}" </dev/null >"$out"
    ) &
  else
    (
      cd -- "$dir" || exit 126
      exec "${supervised[@]}" </dev/null
    ) &
  fi
  active_pid=$!
}

# command 開始前の取消でも結果fileが欠けるため結果fileの欠落だけによる残存process扱いは不可
# supervisorが記録した子孫の終了確認
# $1: supervisorの結果file
# 戻り値: 開始前の取消または終了確認時の0と未確認時の非0
drain_confirmed() {
  [[ ! -e $1 ]] || jq -e '.phase == "finished" and .drained == true' "$1" >/dev/null 2>&1
}

# 親の終了だけでは子孫の終了を確認できないため後続の走行による未確認資源の自動解放は不可
# 未確認の子孫が使う資源の自動解放の禁止
# 引数なし
# 副作用: 走行と候補のunconfirmed記録と手動discardの案内
pin_unconfirmed() {
  local work_id=${work_dir##*/}
  child_unconfirmed=1
  : >"$work_dir/unconfirmed" || true
  if [[ -n $cand_dir && -d $cand_dir ]]; then
    : >"$cand_dir/unconfirmed" || true
  fi
  printf 'FATAL: the supervisor did not confirm that every process of the command had ended; the work directory %s and the candidate %s are kept, and no later run releases them\n' "$work_id" "${cand_id:-none}" >&2
  printf 'After confirming that none of those processes runs, release them with: dotfiles-rebuild --discard %s' "$work_id" >&2
  if [[ -n $cand_id && $cand_id != "$work_id" ]]; then
    printf ' and dotfiles-rebuild --discard %s' "$cand_id" >&2
  fi
  printf '\n' >&2
}

# 逃げた子孫が作業directoryと候補rootを使い続けるため終了statusだけによる解放は不可
# supervisorの終了statusと子孫の終了確認の合流
# 前提: active_pidに記録した子の開始済み状態
# 副作用: active_pidの解放と未確認資源の固定
# 戻り値: 取消時の130
# 戻り値: 終了未確認で元statusが0の場合の70
# 戻り値: その他の場合の元status
settle_child() {
  local pid=$active_pid status=0
  wait "$pid" 2>/dev/null || status=$?
  active_pid=
  if ! drain_confirmed "$child_result"; then
    pin_unconfirmed
    ((status != 0)) || status=70
  fi
  [[ $interrupted -eq 0 ]] || return 130
  return "$status"
}

# setsid で逃げた子孫へ process group 単位の signal は届かないため group への TERM と KILL は不可
# 取消要求をsupervisorへ渡す終了待ち
# 引数なし
# 戻り値: settle_childによる子孫の終了確認を含む終了status
wait_child() {
  local pid=$active_pid cancelled=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $interrupted -eq 1 && $cancelled -eq 0 ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      cancelled=1
    fi
    sleep 0.1
  done
  settle_child
}

# 共通supervisor配下でのcommandの同期実行
# 引数: start_childと同じ作業directoryと出力先とcommand
# 戻り値: 起動の失敗またはwait_childによる終了status
run_child() {
  local status=0
  start_child "$@" || return $?
  wait_child || status=$?
  return "$status"
}

ensure_work_dir() {
  [[ -z $work_dir ]] || return 0
  work_dir=$state_root/work/$(date +%s)-$$
  mkdir -- "$work_dir" || die 2 "could not create $work_dir"
}

init_state() {
  [[ -d $dotfiles ]] || die 2 "cannot enter $dotfiles"
  mkdir -p -- "$state_root/candidates" "$state_root/work" || die 2 "could not create $state_root"
  chmod 700 -- "$state_root" || die 2 "could not protect $state_root"
}

# One writer at a time for apply, rollback and discard. The descriptor stays open in the
# children this run starts, except behind sudo, which closes it; the activation is awaited by
# this process, so the lock is held until it returns.
acquire_writer() {
  exec 9>"$state_root/writer.lock" || die 2 "could not open the writer lock"
  flock -n 9 || die 2 "another dotfiles-rebuild apply, rollback or discard holds the writer lock; wait for it to finish"
}

# Removes what an invocation left behind when it died without cleaning up: its work directory,
# and a candidate directory that never received its receipt. Published candidates are kept, and so
# is anything pinned as unconfirmed or whose supervisor has not recorded that every process ended.
prune_dead_leftovers() {
  local entry id owner
  for entry in "$state_root"/work/* "$state_root"/candidates/*; do
    [[ -d $entry ]] || continue
    id=${entry##*/}
    owner=${id#*-}
    [[ $owner =~ ^[0-9]+$ ]] || continue
    if kill -0 "$owner" 2>/dev/null; then
      continue
    fi
    if [[ $entry == */candidates/* && -f $entry/receipt ]]; then
      continue
    fi
    if [[ -e $entry/unconfirmed ]] || ! drain_confirmed "$state_root/work/$id/supervisor.json"; then
      continue
    fi
    release_work_dir "$entry" || printf 'WARN: could not release the work directory %s\n' "$entry" >&2
  done
}

# Describes how the checkout differs from a clean one. Returns 0 when it is clean, 1 when it
# differs and 2 when the state could not be read. Untracked files that are not ignored count,
# because the flake source and the verification entry both refuse them.
source_difference() {
  local top=$1 difference flags line unusual=
  difference=$(git -C "$top" --no-optional-locks status --porcelain --untracked-files=normal --ignore-submodules=none) || return 2
  flags=$(git -C "$top" --no-optional-locks ls-files -v --recurse-submodules) || return 2
  while IFS= read -r line; do
    [[ -z $line || $line == 'H '* ]] || unusual+=$line$'\n'
  done <<<"$flags"
  if [[ -z $difference && -z $unusual ]]; then
    return 0
  fi
  if [[ -n $difference ]]; then
    printf '%s\n' "$difference"
  fi
  if [[ -n $unusual ]]; then
    printf '%s' "$unusual"
  fi
  return 1
}

require_clean_source() {
  local difference status=0
  difference=$(source_difference "$dotfiles") || status=$?
  if ((status == 1)); then
    printf '%s\n' "$difference" >&2
    die 2 "commit the working tree before rebuilding"
  fi
  ((status == 0)) || die 2 "could not inspect the working tree"
}

read_base() {
  checkout_real=$(realpath -e -- "$dotfiles") || die 2 "cannot resolve $dotfiles"
  base_head=$(git -C "$dotfiles" rev-parse --verify 'HEAD^{commit}') || die 2 "the checkout has no commit"
}

# True while the checkout is still the clean base commit this run started from.
source_is_base() {
  local head
  head=$(git -C "$dotfiles" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [[ $head == "$base_head" ]] || return 1
  source_difference "$dotfiles" >/dev/null
}

# Resolves the declared verification entry and its time budget for the source in $1.
resolve_verification() {
  local dir=$1 policy
  policy=$work_dir/verification-policy.json
  "$verification_entry" --repo "$dir" --snapshot verify >"$policy" || return 1
  verify_budget=$("$verification_entry" --repo "$dir" --policy "$policy" --budget verify) || return 1
  verify_entry=$("$verification_entry" --repo "$dir" --policy "$policy" verify) || return 1
  if [[ -z $verify_entry ]]; then
    printf '%s declares no verify entry\n' "$dir" >&2
    return 1
  fi
}

write_receipt() {
  {
    printf 'version=2\n'
    printf 'host=%s\n' "$host_name"
    printf 'checkout=%s\n' "$checkout_real"
    printf 'base_head=%s\n' "$base_head"
    printf 'toplevel=%s\n' "$cand_path"
  } >"$cand_dir/receipt.tmp" || die 2 "could not write the candidate receipt"
}

# 並行した plan が互いの receipt を消すため公開と旧候補解放の分割は不可
# 適用中の候補が消えるため writer lock を取れない間の旧候補解放は不可
# 引数なしでのplan候補の条件付き公開
# 前提: buildを終えた候補と表示済みplanの保持
# 戻り値: 公開完了時の0または公開前の取消時の130
publish_candidate() {
  local entry
  write_receipt
  {
    run_child "$dotfiles" "" flock 7 || die 2 "could not acquire the candidate publication lock"
    checkpoint
    # 公開済み候補の保持と旧候補解放を分断するため公開決定後の取消による中断は不可
    mv -T -- "$cand_dir/receipt.tmp" "$cand_dir/receipt" || die 2 "could not publish candidate $cand_id"
    retain_candidate=1
    if flock -n 8; then
      for entry in "$state_root"/candidates/*; do
        [[ -f $entry/receipt && ! -e $entry/unconfirmed && ${entry##*/} != "$cand_id" ]] || continue
        rm -rf --one-file-system -- "$entry" || true
      done
    fi
  } 7>"$state_root/publish.lock" 8>"$state_root/writer.lock"
}

# Builds a candidate from an isolated copy of the committed source. Nothing in the checkout is
# written, and flake.lock is used as committed: no input is fetched or updated. The candidate root
# is a native Nix GC root created by nix build --out-link, inside the candidate directory; only a
# plan publishes the directory, by its receipt.
prepare_candidate() {
  local source_dir status=0
  local -a entry_words

  ensure_work_dir
  cand_id=${work_dir##*/}
  cand_dir=$state_root/candidates/$cand_id
  mkdir -- "$cand_dir" || stop_before_activation "could not create the candidate directory"
  source_dir=$work_dir/source

  run_child "$work_dir" "" git -c core.hooksPath=/dev/null clone --quiet --local --no-checkout -- "$dotfiles" "$source_dir" ||
    stop_before_activation "could not copy the committed source for the candidate"
  run_child "$source_dir" "" git -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach "$base_head" ||
    stop_before_activation "could not check out the base commit in the isolated source"
  checkpoint

  resolve_verification "$source_dir" || stop_before_activation "the isolated source declares no usable verification entry"
  read -r -a entry_words <<<"$verify_entry"
  printf 'validate: %s (budget %ss, isolated source)\n' "$verify_entry" "$verify_budget"
  run_child "$source_dir" "" timeout --kill-after=5s "$verify_budget" "${entry_words[@]}" || status=$?
  if ((status == 124)); then
    stop_before_activation "validation of the candidate exceeded its ${verify_budget}s budget"
  fi
  ((status == 0)) || stop_before_activation "validation of the candidate failed (status $status)"

  run_child "$source_dir" "" nix build --no-update-lock-file --out-link "$cand_dir/toplevel" \
    "$source_dir#nixosConfigurations.$host_name.config.system.build.toplevel" ||
    stop_before_activation "candidate build failed"
  cand_path=$(readlink -e -- "$cand_dir/toplevel") || stop_before_activation "the candidate build left no root"
  [[ $cand_path == "$store_dir"/* ]] || stop_before_activation "the candidate root does not resolve into $store_dir"

  checkpoint
  rm -rf --one-file-system -- "$work_dir/source" || true
}

# Loads a held candidate and rejects it, without preparing another one, when it is not usable.
load_candidate() {
  local id=$1 key value resolved
  local -A receipt=()

  [[ $id =~ ^[0-9]+-[0-9]+$ ]] || die 2 "malformed candidate id: $id"
  if [[ -e $state_root/candidates/$id/unconfirmed ]]; then
    die 2 "candidate $id is pinned: a run could not confirm that every one of its processes ended, so it is not applied or released automatically. After confirming that none of them runs, release it with: dotfiles-rebuild --discard $id"
  fi
  if [[ ! -f $state_root/candidates/$id/receipt ]]; then
    die 2 "no held candidate $id: it was applied, discarded, replaced by a newer plan or never completed. No other candidate was substituted; run dotfiles-rebuild --plan again"
  fi
  cand_id=$id
  cand_dir=$state_root/candidates/$id
  retain_candidate=1
  while IFS='=' read -r key value; do
    receipt[$key]=$value
  done <"$cand_dir/receipt"

  if [[ ${receipt[version]-} != 2 ]]; then
    die 2 "candidate $id was written in another receipt format; run dotfiles-rebuild --plan again"
  fi
  if [[ ${receipt[host]-} != "$host_name" || ${receipt[checkout]-} != "$checkout_real" ]]; then
    die 2 "candidate $id belongs to another host or checkout"
  fi
  cand_path=${receipt[toplevel]-}

  resolved=$(readlink -e -- "$cand_dir/toplevel" 2>/dev/null) || resolved=
  if [[ -z $resolved || $resolved != "$cand_path" ]] || ! nix path-info "$cand_path" >/dev/null 2>&1; then
    retain_candidate=0
    die 2 "candidate $id expired: its GC root or store path is gone. No other candidate was substituted; run dotfiles-rebuild --plan again"
  fi
  if [[ ${receipt[base_head]-} != "$base_head" ]]; then
    retain_candidate=0
    die 2 "candidate $id is stale: it was prepared from ${receipt[base_head]-unknown} and HEAD is $base_head. No other candidate was substituted; run dotfiles-rebuild --plan again"
  fi
}

show_plan() {
  printf 'candidate: %s\n' "$cand_id"
  printf 'candidate-path: %s\n' "$cand_path"
  printf 'base: %s\n' "$base_head"
  "$nvd" diff /run/current-system "$cand_path" || true
  printf 'plan: %s\n' "$restart_plan"
}

report_state() {
  local running link generation id path resolved profile_target
  running=$(readlink -f -- /run/current-system 2>/dev/null) || running=unknown
  profile_target=$(readlink -f -- "$system_profile" 2>/dev/null) || profile_target=unknown
  link=$(readlink -- "$system_profile" 2>/dev/null) || link=
  generation=unknown
  if [[ ${link##*/} =~ -([0-9]+)-link$ ]]; then
    generation=${BASH_REMATCH[1]}
  fi
  printf 'system profile: %s (generation %s)\n' "$profile_target" "$generation"
  printf 'running system: %s\n' "$running"
  printf 'client executables (a separate state from the system generation; this command does not change them):\n'
  while IFS=$'\t' read -r id path; do
    [[ -n $id ]] || continue
    resolved=$(readlink -e -- "$path" 2>/dev/null) || resolved=
    if [[ -n $resolved ]]; then
      printf '  %s: %s -> %s\n' "$id" "$path" "$resolved"
    else
      printf '  %s: %s (not installed)\n' "$id" "$path"
    fi
  done <<<"$client_executables"
}

print_inspection() {
  printf 'Inspect the system profile, running system and failed services before retrying:\n' >&2
  printf '  readlink -f %s\n' "$system_profile" >&2
  printf '  readlink -f /run/current-system\n' >&2
  printf '  systemctl --failed\n' >&2
  printf '  journalctl -b -p err\n' >&2
}

print_terminate_command() {
  printf 'WSL restart required. From Windows (this command does not run it):\n'
  printf "  wsl.exe --terminate '%s'\n" "${distro_name//\'/\'\'}"
}

# The apply stopped before activation. Reports the checkout as observed and exits; this command
# never writes to the checkout, so there is nothing of its own to take back.
stop_before_activation() {
  local head difference status=0
  printf 'FATAL: %s\n' "$1" >&2
  if source_is_base; then
    printf 'result: unchanged. HEAD, index, working tree and the deployed system are as they were before this run.\n' >&2
    [[ $interrupted -eq 0 ]] || exit 130
    exit 2
  fi
  retain_candidate=0
  head=$(git -C "$dotfiles" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || head=unknown
  difference=$(source_difference "$dotfiles") || status=$?
  printf 'result: source-changed. The deployed system was not switched.\n' >&2
  printf '  base commit: %s\n  HEAD now:    %s\n' "$base_head" "$head" >&2
  printf '  this run wrote nothing to the checkout; the change was made by something else.\n' >&2
  if [[ -n $difference ]]; then
    printf '  working tree differences, left as they are:\n%s\n' "$difference" >&2
  fi
  if ((status == 2)); then
    printf '  the working tree could not be inspected.\n' >&2
  fi
  printf '  inspect git status and git log, then run dotfiles-rebuild again.\n' >&2
  exit 4
}

# The activation was started and did not end as expected. The profile, the running system and
# the services are reported as observed, never as recovered.
activation_failed() {
  retain_candidate=0
  printf 'FATAL: %s\n' "$1" >&2
  printf 'result: activation-failed. Activation started and did not complete; the profile, the running system and services may be partially applied. Nothing was restored automatically.\n' >&2
  report_state >&2
  print_inspection
  exit 5
}

# $1 is the system that must be the profile target after activation; the rest is the
# nixos-rebuild argv. The native tool runs in the foreground with this terminal. A cancel
# that reaches only this script is deferred until activation ends; it is never killed halfway.
# rootのactivationを取消のTERMとKILLで途中停止すると部分適用になるためsupervisor配下への配置は不可
activate() {
  local expected=$1 status=0 actual
  shift
  printf 'activate: nixos-rebuild %s\n' "$*"
  "$sudo_command" "$nixos_rebuild" "$@" || status=$?
  if ((status != 0)); then
    activation_failed "nixos-rebuild $* failed with status $status"
  fi
  actual=$(readlink -f -- "$system_profile" 2>/dev/null) || actual=unknown
  if [[ $actual != "$expected" ]]; then
    activation_failed "nixos-rebuild succeeded but the system profile resolves to $actual instead of $expected"
  fi
}

finish_activation() {
  report_state
  case $restart_plan in
  switch)
    printf 'result: %s. WSL does not need a restart.\n' "$1"
    exit 0
    ;;
  switch-restart)
    printf 'result: %s. The running system already uses it; a WSL restart loads the new WSL manifest.\n' "$1"
    print_terminate_command
    exit 0
    ;;
  *)
    printf 'result: boot-transition (%s). The system profile was switched, but the WSL boot transition is not finished and this is not a completed switch.\n' "$restart_plan"
    print_terminate_command
    exit 3
    ;;
  esac
}

# Verifies the checkout through the existing source-bound verification, and requires that its
# evaluated toplevel is the held candidate. Nothing is carried over from the isolated source:
# the verification runs again for this directory and commit, and only Nix's immutable outputs
# and caches are reused.
verify_source() {
  local head status=0 evaluated
  local -a entry_words
  source_is_base || stop_before_activation "the checkout changed while the candidate was prepared"
  resolve_verification "$dotfiles" || stop_before_activation "the checkout declares no usable verification entry"
  read -r -a entry_words <<<"$verify_entry"
  printf 'verify: %s (source-bound, committed source)\n' "$verify_entry"
  run_child "$dotfiles" "" "$agent_verify" -- "${entry_words[@]}" || status=$?
  ((status == 0)) || stop_before_activation "verification of the committed source failed (status $status)"

  status=0
  run_child "$dotfiles" "$work_dir/evaluated" nix eval --raw --no-update-lock-file \
    "$dotfiles#nixosConfigurations.$host_name.config.system.build.toplevel.outPath" || status=$?
  ((status == 0)) || stop_before_activation "could not evaluate the toplevel of the committed source (status $status)"
  evaluated=$(<"$work_dir/evaluated")
  [[ $evaluated == "$cand_path" ]] ||
    stop_before_activation "the committed source evaluates to $evaluated, not to the held candidate $cand_path (Git metadata changes); activation was not started"

  head=$(git -C "$dotfiles" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || head=
  [[ $head == "$base_head" ]] || stop_before_activation "HEAD moved from $base_head during verification"
  source_difference "$dotfiles" >/dev/null || stop_before_activation "the working tree changed during verification"
  [[ $interrupted -eq 0 ]] || stop_before_activation "interrupted before activation"
}

do_discard() {
  local released=0
  [[ $discard_id =~ ^[0-9]+-[0-9]+$ ]] || die 2 "malformed candidate id: $discard_id"
  acquire_writer
  if [[ -d $state_root/candidates/$discard_id ]]; then
    rm -rf --one-file-system -- "${state_root:?}/candidates/$discard_id" || die 2 "could not release candidate $discard_id"
    released=1
  fi
  if [[ -d $state_root/work/$discard_id ]] && ! kill -0 "${discard_id#*-}" 2>/dev/null; then
    release_work_dir "$state_root/work/$discard_id" || die 2 "could not release the work directory $discard_id"
    released=1
  fi
  ((released)) || die 2 "no held candidate $discard_id"
  printf 'discarded: %s\n' "$discard_id"
  exit 0
}

do_plan() {
  prune_dead_leftovers
  require_clean_source
  read_base
  prepare_candidate
  restart_plan=$("$wsl_restart_required" --plan "$cand_path") || die 2 "could not classify the restart requirement"
  checkpoint
  show_plan
  checkpoint
  publish_candidate
  printf 'result: planned. Nothing was changed; apply exactly this candidate with: dotfiles-rebuild --candidate %s\n' "$cand_id"
  exit 0
}

do_apply() {
  acquire_writer
  prune_dead_leftovers
  require_clean_source
  read_base
  ensure_work_dir
  if [[ -n $candidate_id ]]; then
    load_candidate "$candidate_id"
  else
    prepare_candidate
  fi
  checkpoint
  restart_plan=$("$wsl_restart_required" --plan "$cand_path") || die 2 "could not classify the restart requirement"
  show_plan
  verify_source
  activate "$cand_path" switch --no-reexec --store-path "$cand_path"
  retain_candidate=0
  finish_activation "applied candidate $cand_id"
}

do_rollback() {
  local generations generation metadata previous_generation='' current_found=0 target
  if ((plan_only == 0)); then
    acquire_writer
  fi
  require_clean_source
  generations=$("$sudo_command" nix-env --list-generations --profile "$system_profile") ||
    die 2 "could not list system generations"
  while read -r generation metadata; do
    [[ $generation =~ ^[0-9]+$ ]] || continue
    if [[ $metadata == *"(current)"* ]]; then
      current_found=1
      break
    fi
    previous_generation=$generation
  done <<<"$generations"
  [[ $current_found -eq 1 && -n $previous_generation ]] ||
    die 2 "no previous system generation is available"
  target=$(readlink -e -- "$system_profile-$previous_generation-link") ||
    die 2 "could not resolve the previous system generation"
  restart_plan=$("$wsl_restart_required" --plan "$target") ||
    die 2 "could not classify the restart requirement"
  checkpoint
  printf 'rollback: system generation %s (%s); nothing is fetched or built\n' "$previous_generation" "$target"
  if ((plan_only)); then
    "$nvd" diff /run/current-system "$target" || true
    printf 'plan: %s\n' "$restart_plan"
    exit 0
  fi
  activate "$target" switch --no-reexec --rollback
  finish_activation "rolled back the system generation to $previous_generation"
}

trap 'interrupted=1' INT TERM HUP
trap cleanup EXIT
init_state

if [[ -n $discard_id ]]; then
  do_discard
fi
if ((rollback)); then
  do_rollback
fi
if ((plan_only)); then
  do_plan
fi
do_apply
