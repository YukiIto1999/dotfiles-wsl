set -euo pipefail

kernel_log_path=${WSL_RELAY_RECOVERY_KERNEL_LOG_PATH:-}
proc_root=${WSL_RELAY_RECOVERY_PROC_ROOT:-/proc}
signal_command=${WSL_RELAY_RECOVERY_SIGNAL_COMMAND:-kill}
clock_ticks=${WSL_RELAY_RECOVERY_CLOCK_TICKS:-}
minimum_age_seconds=@minimumAgeSeconds@

fail() {
  printf 'WSL relay recovery failed: %s\n' "$1" >&2
  exit 1
}

read_kernel_log() {
  if [[ -n $kernel_log_path ]]; then
    [[ -r $kernel_log_path ]] || fail "kernel log is not readable: $kernel_log_path"
    cat -- "$kernel_log_path"
    return
  fi

  dmesg --time-format=raw --level=err,warn
}

read_relay_start_ticks() {
  local process_id=$1
  local process_path=$proc_root/$process_id
  local process_stat
  local process_executable
  local -a fields

  [[ -r $process_path/comm && -r $process_path/stat && -L $process_path/exe ]] || return 1
  [[ $(<"$process_path/comm") == Relay ]] || return 1
  process_executable=$(readlink -- "$process_path/exe") || return 1
  [[ $process_executable == /init ]] || return 1

  process_stat=$(<"$process_path/stat")
  read -r -a fields <<< "$process_stat"
  [[ ${#fields[@]} -ge 22 ]] || return 1
  [[ ${fields[0]} == "$process_id" && ${fields[1]} == '(Relay)' ]] || return 1
  [[ ${fields[3]} == 1 ]] || return 1
  [[ ${fields[21]} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[21]}"
}

workspace=$(mktemp -d)
trap 'rm -rf -- "$workspace"' EXIT
relay_events=$workspace/relay-events

if ! read_kernel_log \
  | awk '
      match($0, /^\[([0-9]+)(\.[0-9]+)?\] WSL \(([0-9]+) - Relay\) ERROR: UtilAcceptVsock:[0-9]+: Waiting for abnormally long accept\([0-9]+\)$/, match_fields) {
        event_seconds = match_fields[1] match_fields[2]
        process_id = match_fields[3]
        if (!(process_id in latest) || event_seconds > latest[process_id]) {
          latest[process_id] = event_seconds
        }
      }
      END {
        for (process_id in latest) {
          print process_id, latest[process_id]
        }
      }
    ' \
  | sort -n -k1,1 > "$relay_events"; then
  fail 'could not read WSL kernel warnings'
fi

[[ -s $relay_events ]] || exit 0

if [[ -z $clock_ticks ]]; then
  clock_ticks=$(getconf CLK_TCK) || fail 'could not read CLK_TCK'
fi
[[ $clock_ticks =~ ^[1-9][0-9]*$ ]] || fail "invalid CLK_TCK: $clock_ticks"

read -r uptime_seconds _ < "$proc_root/uptime" || fail "uptime is not readable: $proc_root/uptime"
[[ $uptime_seconds =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "invalid uptime: $uptime_seconds"
uptime_ticks=$(awk -v uptime_seconds="$uptime_seconds" -v clock_ticks="$clock_ticks" \
  'BEGIN { printf "%.0f\n", int(uptime_seconds * clock_ticks) }')

while read -r process_id event_seconds; do
  initial_start_ticks=$(read_relay_start_ticks "$process_id") || continue
  event_ticks=$(awk -v event_seconds="$event_seconds" -v clock_ticks="$clock_ticks" \
    'BEGIN { printf "%.0f\n", int(event_seconds * clock_ticks) }')
  ((initial_start_ticks < event_ticks && event_ticks <= uptime_ticks)) || continue
  process_age_ticks=$((uptime_ticks - initial_start_ticks))
  ((process_age_ticks >= minimum_age_seconds * clock_ticks)) || continue
  process_age_seconds=$((process_age_ticks / clock_ticks))

  current_start_ticks=$(read_relay_start_ticks "$process_id") || continue
  [[ $current_start_ticks == "$initial_start_ticks" ]] || continue

  if ! "$signal_command" -9 "$process_id"; then
    [[ ! -e $proc_root/$process_id ]] || fail "could not terminate Relay pid $process_id"
    continue
  fi
  printf 'WSL stale Relay removed: pid=%s age=%ss\n' "$process_id" "$process_age_seconds"
done < "$relay_events"
