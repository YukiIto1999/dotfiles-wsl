#!/usr/bin/env bash
# Shared setup for the dotfiles-rebuild behavior checks. The checks source this file.
#
# The Git checkout and the state directory are real. Nix, nixos-rebuild, sudo and
# the verification commands are the fixture dependencies, which model their results from
# their inputs: a toplevel is named after the content of the flake.lock it was built from,
# so a candidate and an evaluation agree only when they saw the same lock.
set -euo pipefail

harness_init() {
  local system

  REBUILD_BIN=$1
  REBUILD_DEPS=$2
  REBUILD_ROOT=$(cd -- "$(mktemp -d)" && pwd -P)
  export REBUILD_ROOT
  trap 'rm -rf -- "$REBUILD_ROOT"' EXIT
  export REBUILD_RESTART_PLANNER=$3
  export REBUILD_CHECKOUT=$REBUILD_ROOT/checkout
  export REBUILD_STORE_DIR=$REBUILD_ROOT/store
  export REBUILD_SYSTEM_PROFILE=$REBUILD_ROOT/profiles/system
  export REBUILD_CANDIDATE=$REBUILD_STORE_DIR/template
  export REBUILD_PREVIOUS=$REBUILD_STORE_DIR/previous
  export REBUILD_BOOTED_SYSTEM=$REBUILD_STORE_DIR/booted
  export REBUILD_RUNNING_SYSTEM=$REBUILD_STORE_DIR/running
  export REBUILD_GENERATIONS=$REBUILD_ROOT/generations
  export REBUILD_CALL_LOG=$REBUILD_ROOT/calls
  export REBUILD_OBSERVED=$REBUILD_ROOT/observed
  export REBUILD_CHILD_PIDS=$REBUILD_ROOT/child-pids
  export REBUILD_STOP_OBSERVED=$REBUILD_ROOT/stop-observed
  export REBUILD_HANG_STARTED=$REBUILD_ROOT/hang-started
  export REBUILD_SWITCH_STARTED=$REBUILD_ROOT/switch-started
  export REBUILD_SWITCH_RELEASE=$REBUILD_ROOT/switch-release
  export REBUILD_OVERLAP_LOG=$REBUILD_ROOT/overlap
  export REBUILD_INVALID_PATHS=$REBUILD_ROOT/invalid-paths
  export XDG_STATE_HOME=$REBUILD_ROOT/state
  REBUILD_STATE=$XDG_STATE_HOME/dotfiles-wsl/rebuild
  REBUILD_OUTPUT=$REBUILD_ROOT/output
  export PATH="$REBUILD_DEPS/bin:$PATH"

  mkdir -p "$REBUILD_CHECKOUT" "${REBUILD_SYSTEM_PROFILE%/*}" "$XDG_STATE_HOME" "$REBUILD_ROOT/clients"
  for system in "$REBUILD_CANDIDATE" "$REBUILD_BOOTED_SYSTEM" "$REBUILD_RUNNING_SYSTEM"; do
    mkdir -p "$system/etc"
    printf '[user]\ndefault=nixos\n' >"$system/etc/wsl.conf"
    printf '1\n' >"$system/init-interface-version"
  done
  cp -r "$REBUILD_CANDIDATE" "$REBUILD_PREVIOUS"
  ln -s "$REBUILD_PREVIOUS" "$REBUILD_SYSTEM_PROFILE-3-link"
  ln -s "$REBUILD_RUNNING_SYSTEM" "$REBUILD_SYSTEM_PROFILE-7-link"
  ln -s "$REBUILD_SYSTEM_PROFILE-7-link" "$REBUILD_SYSTEM_PROFILE"
  printf '3 2026-10-01 12:00:00\n7 2026-10-02 12:00:00 (current)\n10 2026-10-03 12:00:00\n' >"$REBUILD_GENERATIONS"

  printf 'client binary\n' >"$REBUILD_STORE_DIR/omp-binary"
  ln -s "$REBUILD_STORE_DIR/omp-binary" "$REBUILD_ROOT/clients/omp"
  REBUILD_CLIENT_TABLE=$'omp\t'"$REBUILD_ROOT/clients/omp"
  export REBUILD_CLIENT_TABLE

  git -C "$REBUILD_CHECKOUT" init -q
  git -C "$REBUILD_CHECKOUT" config user.name 'Rebuild fixture'
  git -C "$REBUILD_CHECKOUT" config user.email 'fixture@example.invalid'
  printf 'initial\n' >"$REBUILD_CHECKOUT/tracked"
  lock_json rev-1 >"$REBUILD_CHECKOUT/flake.lock"
  git -C "$REBUILD_CHECKOUT" add tracked flake.lock
  git -C "$REBUILD_CHECKOUT" commit -qm initial
}

# A flake.lock with one input locked at revision $1.
lock_json() {
  printf '{"nodes":{"source":{"locked":{"rev":"%s"}},"root":{"inputs":{"source":"source"}}},"root":"root","version":7}\n' "$1"
}

# Commits a flake.lock locked at revision $1, so that the checkout becomes a source whose toplevel
# differs, the way an owner adopts a moved input.
commit_lock() {
  lock_json "$1" >"$REBUILD_CHECKOUT/flake.lock"
  checkout_git commit -qam "lock $1"
}

# The toplevel the fixture nix builds from, or evaluates for, a flake.lock with this content.
system_for_lock() {
  printf '%s/system-%s' "$REBUILD_STORE_DIR" "$(printf '%s\n' "$1" | sha256sum | cut -c1-16)"
}

run_rebuild() {
  local expected_status=$1 status=0
  shift
  : >"$REBUILD_CALL_LOG"
  "$REBUILD_BIN" "$@" >"$REBUILD_OUTPUT" 2>&1 || status=$?
  if [[ $status != "$expected_status" ]]; then
    cat "$REBUILD_OUTPUT" >&2
    printf 'expected exit %s, got %s\n' "$expected_status" "$status" >&2
    exit 1
  fi
}

checkout_git() { git -C "$REBUILD_CHECKOUT" "$@"; }

head_of() { checkout_git rev-parse "${1:-HEAD}"; }

# HEAD, the index bytes, flake.lock and the status in one comparable value.
checkout_snapshot() {
  checkout_git rev-parse HEAD
  sha256sum <"$REBUILD_CHECKOUT/.git/index"
  sha256sum <"$REBUILD_CHECKOUT/flake.lock"
  checkout_git --no-optional-locks status --porcelain --untracked-files=all
}

# Brings the checkout back to a commit, so that a scenario that left it changed does not
# decide the next one.
checkout_reset() {
  checkout_git reset -q --hard "$1"
  checkout_git clean -fdq
}

reset_profile() {
  rm -f -- "$REBUILD_SYSTEM_PROFILE-11-link"
  ln -sfn "$REBUILD_SYSTEM_PROFILE-7-link" "$REBUILD_SYSTEM_PROFILE"
}

assert_called() {
  if ! grep -Fxq -- "$1" "$REBUILD_CALL_LOG"; then
    cat "$REBUILD_CALL_LOG" >&2
    printf 'expected call not made: %s\n' "$1" >&2
    exit 1
  fi
}

assert_not_called() {
  if grep -q -- "^$1" "$REBUILD_CALL_LOG"; then
    cat "$REBUILD_CALL_LOG" >&2
    printf 'unexpected call: %s\n' "$1" >&2
    exit 1
  fi
}

assert_output_has() {
  if ! grep -Fq -- "$1" "$REBUILD_OUTPUT"; then
    cat "$REBUILD_OUTPUT" >&2
    printf 'output lacks: %s\n' "$1" >&2
    exit 1
  fi
}

assert_output_lacks() {
  if grep -Fq -- "$1" "$REBUILD_OUTPUT"; then
    cat "$REBUILD_OUTPUT" >&2
    printf 'output must not contain: %s\n' "$1" >&2
    exit 1
  fi
}

assert_no_switch() {
  if grep -q '^nixos-rebuild ' "$REBUILD_CALL_LOG"; then
    cat "$REBUILD_CALL_LOG" >&2
    printf 'a read-only, refused or failed invocation switched the system\n' >&2
    exit 1
  fi
}

assert_no_terminate() {
  if grep -q '^wsl.exe' "$REBUILD_CALL_LOG"; then
    printf 'WSL was terminated by the command\n' >&2
    exit 1
  fi
}

assert_failure_guidance() {
  assert_output_has 'readlink -f /run/current-system'
  assert_output_has "readlink -f $REBUILD_SYSTEM_PROFILE"
  assert_output_has 'systemctl --failed'
  assert_output_has 'journalctl'
  assert_output_lacks 'previous generation is still active'
}

# The order of two calls in the call log.
assert_call_order() {
  local first second
  first=$(grep -n -m1 -F -- "$1" "$REBUILD_CALL_LOG" | cut -d: -f1)
  second=$(grep -n -m1 -F -- "$2" "$REBUILD_CALL_LOG" | cut -d: -f1)
  if [[ -z $first || -z $second || $first -ge $second ]]; then
    cat "$REBUILD_CALL_LOG" >&2
    printf 'expected "%s" before "%s"\n' "$1" "$2" >&2
    exit 1
  fi
}

# 状態 directory 直下の directory の項目名
#   $1: REBUILD_STATE 直下の directory 名
#   標準出力: 項目名の一覧
#   不在の directory の標準出力: 空
state_entries() {
  [[ -e $REBUILD_STATE/$1 ]] || return 0
  ls -A "$REBUILD_STATE/$1"
}

assert_no_work_left() {
  if [[ -n $(state_entries work) ]]; then
    printf 'source worktree left behind: %s\n' "$(state_entries work)" >&2
    exit 1
  fi
}

# plan の出力に印字された最後の candidate id
#   $1: 既定が REBUILD_OUTPUT の出力 file
#   標準出力: 末尾の改行を含まない id
#   戻り値: id が印字されていない場合の非ゼロ
candidate_id_of_output() {
  local file=${1:-$REBUILD_OUTPUT} line id=
  while IFS= read -r line; do
    if [[ $line == 'candidate: '* ]]; then
      id=${line#candidate: }
    fi
  done <"$file"
  if [[ -z $id ]]; then
    cat "$file" >&2
    exit 1
  fi
  printf '%s' "$id"
}

wait_for_file() {
  local file=$1
  for _ in {1..600}; do
    if [[ -e $file ]]; then
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for %s\n' "$file" >&2
  return 1
}

process_alive() {
  local state
  [[ -r /proc/$1/stat ]] || return 1
  read -r _ _ state _ <"/proc/$1/stat" || return 1
  [[ $state != Z ]]
}

# process の stat の指定欄の値
#   $1: 対象の pid
#   $2: 状態を 3 欄目とする stat の欄番号
#   標準出力: 指定欄の値
#   戻り値: 対象の stat を読めない場合の非ゼロ
process_field() {
  local stat
  local -a fields
  { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
  read -r -a fields <<<"${stat##*) }"
  printf '%s' "${fields[$2 - 3]}"
}

# process が指定の状態へ入るまでの待機
#   $1: 対象の pid
#   $2: stat の状態を表す一文字
#   戻り値: 待機の上限までに入らない場合の非ゼロ
wait_for_process_state() {
  for _ in {1..600}; do
    if [[ $(process_field "$1" 3) == "$2" ]]; then
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for process %s to reach state %s\n' "$1" "$2" >&2
  return 1
}

# 起動時刻が一致する process だけへの信号の送信
#   $1: 信号の名前
#   $2: 対象の pid
#   $3: 対象を特定した時点の起動時刻
#   戻り値: 常に 0
signal_same_process() {
  [[ $(process_field "$2" 22) == "$3" ]] || return 0
  kill "-$1" "$2" 2>/dev/null || true
}
