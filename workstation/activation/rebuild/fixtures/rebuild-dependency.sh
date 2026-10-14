#!/usr/bin/env bash
set -euo pipefail

# One program standing in for nix, nix-env, nvd, sudo, nixos-rebuild, wsl.exe and the two
# verification commands. Each is a symlink to this file; the name selects the behavior and
# the REBUILD_* variables select the outcome.
command_name=${0##*/}
{
  printf '%s' "$command_name"
  printf ' %q' "$@"
  printf '\n'
} >>"$REBUILD_CALL_LOG"

# 選ばれた stage だけでの build を模した leader と子孫の取消待ち
#   $1: 呼び出し位置の stage の名前
#   REBUILD_HANG_AT: 取消待ちの対象とする stage の名前
#   REBUILD_HANG_IGNORE_TERM: 1 での leader と子孫の TERM の無視
#   REBUILD_HANG_SLOW_STOP: 1 での TERM 後の遅延終了
#   REBUILD_HANG_ESCAPE: 1 での別 session の子孫の追加
#   REBUILD_CHILD_PIDS: leader と子孫の pid の追記先
#   REBUILD_HANG_STARTED: 全 process の起動後に作る合図 file
#   REBUILD_STOP_OBSERVED: 遅延終了時の作業 directory の有無の記録先
hang_at() {
  [[ ${REBUILD_HANG_AT:-} == "$1" ]] || return 0
  if [[ ${REBUILD_HANG_IGNORE_TERM:-0} == 1 ]]; then
    trap '' TERM
  fi
  if [[ ${REBUILD_HANG_SLOW_STOP:-0} == 1 ]]; then
    trap 'sleep 0.5; if [[ -d $PWD ]]; then echo present; else echo gone; fi >"$REBUILD_STOP_OBSERVED"; exit 0' TERM
  fi
  sleep 1000 &
  printf '%s\n%s\n' "$$" "$!" >>"$REBUILD_CHILD_PIDS"
  if [[ ${REBUILD_HANG_ESCAPE:-0} == 1 ]]; then
    setsid "$BASH" -c 'printf "%s\n" "$$" >>"$1"; exec sleep 1000' _ "$REBUILD_CHILD_PIDS" &
    while [[ $(wc -l <"$REBUILD_CHILD_PIDS") -lt 3 ]]; do
      sleep 0.02
    done
  fi
  : >"$REBUILD_HANG_STARTED"
  wait
}

# 選ばれた stage での元の checkout への別の writer の編集
#   $1: 呼び出し位置の stage の名前
#   REBUILD_EDIT_AT: 編集を起こす stage の名前
#   REBUILD_EDIT_FILE: 編集する checkout 内の file の相対 path
#   REBUILD_EDIT_CONTENT: file に書く内容
#   REBUILD_EDIT_RECORD: worktree と stage と commit から選ぶ編集の記録先
concurrent_edit() {
  [[ ${REBUILD_EDIT_AT:-} == "$1" ]] || return 0
  printf '%s\n' "$REBUILD_EDIT_CONTENT" >"$REBUILD_CHECKOUT/$REBUILD_EDIT_FILE"
  case ${REBUILD_EDIT_RECORD:-worktree} in
  worktree) ;;
  stage)
    git -C "$REBUILD_CHECKOUT" add -- "$REBUILD_EDIT_FILE"
    ;;
  commit)
    git -C "$REBUILD_CHECKOUT" add -- "$REBUILD_EDIT_FILE"
    git -C "$REBUILD_CHECKOUT" commit -q -m 'concurrent edit'
    ;;
  esac
}

lock_sum() {
  sha256sum <"$1" | cut -c1-16
}

apply_switch_effect() {
  if [[ $1 == rollback ]]; then
    ln -sfn "$REBUILD_SYSTEM_PROFILE-3-link" "$REBUILD_SYSTEM_PROFILE"
  else
    ln -sfn "$1" "$REBUILD_SYSTEM_PROFILE-11-link"
    ln -sfn "$REBUILD_SYSTEM_PROFILE-11-link" "$REBUILD_SYSTEM_PROFILE"
  fi
}

case $command_name in
nix)
  case ${1:-} in
  flake)
    [[ $* == 'flake update architectureStandard' ]]
    printf 'update-cwd %s\n' "$PWD" >>"$REBUILD_CALL_LOG"
    hang_at update
    [[ ${REBUILD_UPDATE_STATUS:-0} == 0 ]] || exit "$REBUILD_UPDATE_STATUS"
    if [[ -n ${REBUILD_LOCK_NEXT:-} ]]; then
      printf '%s\n' "$REBUILD_LOCK_NEXT" >flake.lock
    fi
    ;;
  run)
    [[ $* == 'run --no-write-lock-file .#verify' ]]
    printf 'verify-cwd %s\n' "$PWD" >>"$REBUILD_CALL_LOG"
    hang_at verify
    exit "${REBUILD_VERIFY_STATUS:-0}"
    ;;
  build)
    [[ $# -eq 5 && $2 == --no-update-lock-file && $3 == --out-link ]]
    [[ $5 == *'#nixosConfigurations.fixture-host.config.system.build.toplevel' ]]
    printf 'build-cwd %s\n' "$PWD" >>"$REBUILD_CALL_LOG"
    {
      printf '%s %s\n' "$(git -C "$REBUILD_CHECKOUT" rev-parse HEAD)" \
        "$(git -C "$REBUILD_CHECKOUT" --no-optional-locks status --porcelain --untracked-files=all | wc -l)"
      sha256sum <"$REBUILD_CHECKOUT/flake.lock"
      sha256sum <flake.lock
    } >>"$REBUILD_OBSERVED"
    concurrent_edit build
    hang_at build
    [[ ${REBUILD_BUILD_STATUS:-0} == 0 ]] || exit "$REBUILD_BUILD_STATUS"
    target=$REBUILD_STORE_DIR/system-$(lock_sum flake.lock)
    rm -rf -- "$target"
    cp -r "$REBUILD_CANDIDATE" "$target"
    ln -s "$target" "$4"
    ;;
  eval)
    [[ $# -eq 4 && $2 == --raw && $3 == --no-update-lock-file ]]
    [[ $4 == "$REBUILD_CHECKOUT#nixosConfigurations.fixture-host.config.system.build.toplevel.outPath" ]]
    printf '%s' "${REBUILD_EVAL_PATH:-$REBUILD_STORE_DIR/system-$(lock_sum "$REBUILD_CHECKOUT/flake.lock")}"
    ;;
  path-info)
    [[ $# -eq 2 && -d $2 ]]
    if grep -Fxq -- "$2" "$REBUILD_INVALID_PATHS" 2>/dev/null; then
      exit 1
    fi
    ;;
  *)
    printf 'unexpected nix invocation: %s\n' "$*" >&2
    exit 1
    ;;
  esac
  ;;
nix-env)
  [[ $* == "--list-generations --profile $REBUILD_SYSTEM_PROFILE" ]]
  [[ ${REBUILD_HISTORY_STATUS:-0} == 0 ]] || exit "$REBUILD_HISTORY_STATUS"
  cat "$REBUILD_GENERATIONS"
  ;;
nvd)
  [[ $1 == diff && $2 == /run/current-system && -d $3 ]]
  concurrent_edit show
  if [[ ${REBUILD_NVD_HOLD:-0} == 1 ]]; then
    : >"$REBUILD_NVD_READY"
    while [[ ! -e $REBUILD_NVD_RELEASE ]]; do
      sleep 0.05
    done
  fi
  ;;
sudo)
  exec "$@"
  ;;
nixos-rebuild)
  [[ $1 == switch && $2 == --no-reexec ]]
  mode=rollback
  if [[ $3 == --store-path ]]; then
    [[ $# -eq 4 ]]
    mode=$4
  else
    [[ $* == 'switch --no-reexec --rollback' ]]
  fi
  entered=0
  if mkdir "$REBUILD_ROOT/switch-active" 2>/dev/null; then
    entered=1
    trap 'rmdir "$REBUILD_ROOT/switch-active"' EXIT
  else
    printf 'overlap\n' >>"$REBUILD_OVERLAP_LOG"
  fi
  : >"$REBUILD_SWITCH_STARTED"
  while [[ ${REBUILD_SWITCH_HOLD:-0} == 1 && ! -e $REBUILD_SWITCH_RELEASE ]]; do
    sleep 0.05
  done
  effect_done=0
  if [[ ${REBUILD_PARTIAL_SWITCH:-0} == 1 ]]; then
    apply_switch_effect "$mode"
    effect_done=1
  fi
  [[ ${REBUILD_SWITCH_STATUS:-0} == 0 ]] || exit "$REBUILD_SWITCH_STATUS"
  if [[ ${REBUILD_SWITCH_NOOP:-0} != 1 && $effect_done == 0 ]]; then
    apply_switch_effect "$mode"
  fi
  [[ $entered == 1 ]] || exit 3
  ;;
dotfiles-verify-entry)
  repo=
  policy=
  mode=entry
  name=
  while [[ $# -gt 0 ]]; do
    case $1 in
    --repo)
      repo=$2
      shift 2
      ;;
    --policy)
      policy=$2
      shift 2
      ;;
    --snapshot | --budget | --candidates)
      mode=${1#--}
      shift
      ;;
    verify)
      name=$1
      shift
      ;;
    *)
      exit 64
      ;;
    esac
  done
  [[ $name == verify && -d $repo ]]
  case $mode in
  snapshot)
    printf '{"version":1}\n'
    ;;
  budget)
    [[ -f $policy ]]
    [[ ${REBUILD_BUDGET_STATUS:-0} == 0 ]] || exit "$REBUILD_BUDGET_STATUS"
    printf '%s\n' "${REBUILD_VERIFY_BUDGET:-300}"
    ;;
  entry)
    [[ -f $policy ]]
    printf '%s\n' "${REBUILD_VERIFY_ENTRY-nix run --no-write-lock-file .#verify}"
    ;;
  *)
    exit 64
    ;;
  esac
  ;;
dotfiles-agent-verify)
  [[ $1 == -- ]]
  shift
  [[ $* == 'nix run --no-write-lock-file .#verify' && $PWD == "$REBUILD_CHECKOUT" ]]
  printf 'agent-verify-head %s\n' "$(git rev-parse HEAD)" >>"$REBUILD_CALL_LOG"
  if [[ ${REBUILD_AGENT_VERIFY_DIRTY:-0} == 1 ]]; then
    printf 'edited-during-verify\n' >>tracked
  fi
  exit "${REBUILD_AGENT_VERIFY_STATUS:-0}"
  ;;
wsl.exe)
  ;;
*)
  printf 'unexpected fixture dependency: %s\n' "$command_name" >&2
  exit 1
  ;;
esac
