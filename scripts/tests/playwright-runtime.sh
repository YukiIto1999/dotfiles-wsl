#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: playwright-runtime.sh TEST_WRAPPER ACTUAL_WRAPPER" >&2
  exit 2
fi

wrapper=$1
actual_wrapper=$2
work_dir=$(mktemp -d)
runtime_dir="$work_dir/runtime"
log_file="$work_dir/sessions.log"
release_file="$work_dir/release"
pids=()

cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -m 0700 "$runtime_dir"
: > "$log_file"

for _ in 1 2; do
  PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" \
    PLAYWRIGHT_MCP_TEST_LOG="$log_file" \
    PLAYWRIGHT_MCP_TEST_MODE=wait \
    PLAYWRIGHT_MCP_TEST_RELEASE="$release_file" \
    "$wrapper" &
  pids+=("$!")
done

for _ in {1..200}; do
  [[ $(wc -l < "$log_file") -eq 2 ]] && break
  sleep 0.05
done

mapfile -t session_dirs < "$log_file"
[[ ${#session_dirs[@]} -eq 2 ]]
[[ ${session_dirs[0]} != "${session_dirs[1]}" ]]

for session_dir in "${session_dirs[@]}"; do
  [[ $session_dir == "$runtime_dir"/* ]]
  [[ $(stat -c %a "$session_dir") == 700 ]]
  [[ $(< "$session_dir/result.txt") == session-scoped ]]
done

touch "$release_file"
for pid in "${pids[@]}"; do
  wait "$pid"
done
pids=()

[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]

set +e
PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" \
  PLAYWRIGHT_MCP_TEST_LOG="$log_file" \
  PLAYWRIGHT_MCP_TEST_MODE=fail \
  "$wrapper"
status=$?
set -e

[[ $status -eq 23 ]]
[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]

rm -f "$release_file"
PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" \
  PLAYWRIGHT_MCP_TEST_LOG="$log_file" \
  PLAYWRIGHT_MCP_TEST_MODE=wait \
  PLAYWRIGHT_MCP_TEST_RELEASE="$release_file" \
  "$wrapper" &
signal_wrapper_pid=$!
pids=("$signal_wrapper_pid")

for _ in {1..200}; do
  [[ $(wc -l < "$log_file") -eq 4 ]] && break
  sleep 0.05
done

signal_session_dir=$(tail -n 1 "$log_file")
signal_child_pid=$(< "$signal_session_dir/child.pid")
kill -TERM "$signal_wrapper_pid"

set +e
wait "$signal_wrapper_pid"
status=$?
set -e
pids=()

[[ $status -eq 143 ]]
! kill -0 "$signal_child_pid" 2>/dev/null
[[ ! -e $signal_session_dir ]]
[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]

help_output=$(PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" "$actual_wrapper" --help)
grep -F -- '--output-dir' <<< "$help_output" > /dev/null
[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]

stdin_log="$work_dir/stdin.log"
printf 'mcp-request\n' | env \
  PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" \
  PLAYWRIGHT_MCP_TEST_LOG="$log_file" \
  PLAYWRIGHT_MCP_TEST_MODE=stdio \
  PLAYWRIGHT_MCP_TEST_STDIN_LOG="$stdin_log" \
  "$wrapper"
[[ $(< "$stdin_log") == mcp-request ]]
[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]

int_child_log="$work_dir/int-child.pid"
set +e
PLAYWRIGHT_MCP_RUNTIME_DIR="$runtime_dir" \
  PLAYWRIGHT_MCP_TEST_LOG="$log_file" \
  PLAYWRIGHT_MCP_TEST_MODE=interrupt \
  PLAYWRIGHT_MCP_TEST_CHILD_LOG="$int_child_log" \
  timeout --preserve-status --signal=TERM --kill-after=1 5 "$wrapper"
status=$?
set -e

[[ $status -eq 130 ]]
int_child_pid=$(< "$int_child_log")
! kill -0 "$int_child_pid" 2>/dev/null
[[ -z $(find "$runtime_dir" -mindepth 1 -print -quit) ]]
