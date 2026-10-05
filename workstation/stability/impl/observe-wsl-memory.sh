# shellcheck shell=bash

set -euo pipefail

awk_command=@awkCommand@
buddyinfo=@buddyinfo@
envelope_version=@envelopeVersion@
high_order_outcome=@highOrderOutcome@
io_pressure_outcome=@ioPressureOutcome@
jq_command=@jqCommand@
journal_timeout_seconds=@journalTimeoutSeconds@
journalctl_command=@journalctlCommand@
memory_pressure_outcome=@memoryPressureOutcome@
pageblock_order=@pageblockOrder@
pressure_failure=@pressureFailure@
pressure_root=@pressureRoot@
pressure_warning=@pressureWarning@
ps_command=@psCommand@
relay_minimum_age_seconds=@relayMinimumAgeSeconds@
relay_outcome=@relayOutcome@
ring_order=@ringOrder@
timeout_command=@timeoutCommand@
vmbus_outcome=@vmbusOutcome@
zoneinfo=@zoneinfo@

read_kernel_log() {
  "$timeout_command" --signal=TERM --kill-after=2s "${journal_timeout_seconds}s" \
    "$journalctl_command" -k -b 0 -q --no-pager -o cat "$@" 2>/dev/null
}

# 一致なしと読取り不能がどちらも 1 を返すため終了 status だけによる 0 件の判定は不可
vmbus_state=error
vmbus_failures=
status=0
output=$(read_kernel_log --grep='vmbus_alloc_ring\+0x') || status=$?
if ((status == 0)); then
  mapfile -t frames <<<"$output"
  vmbus_failures=${#frames[@]}
  vmbus_state=observed
elif ((status == 124 || status == 137)); then
  vmbus_state=timeout
elif ((status == 1)) && [[ -z $output ]]; then
  status=0
  latest=$(read_kernel_log -n 1) || status=$?
  if ((status == 0)) && [[ -n $latest ]]; then
    vmbus_failures=0
    vmbus_state=observed
  elif ((status == 124 || status == 137)); then
    vmbus_state=timeout
  fi
fi

# 稼働中の Relay は SessionLeader の子で名前に PID を含むため名前の前方一致による滞留の判定は不可
stuck_relays=$(
  "$ps_command" -e -o ppid=,etimes=,comm= 2>/dev/null \
    | "$awk_command" -v age="$relay_minimum_age_seconds" '
        NF == 3 && $1 == 1 && $3 == "Relay" && $2 >= age { count++ }
        END { print count + 0 }
      '
) || stuck_relays=

# DMA32 は Normal からの確保に lowmem reserve を残すため zone の空き block の単純な合計は不可
high_order=$(
  "$awk_command" -v ring="$ring_order" -v pageblock="$pageblock_order" '
    FNR == NR {
      if ($1 == "Node") {
        node = $2
        sub(/,$/, "", node)
        key = node SUBSEP $4
        position[key] = zones[node]++
        if ($4 == "Normal") normal[node] = position[key]
      } else if ($1 == "pages" && $2 == "free") {
        free[key] = $3
      } else if ($1 == "min") {
        minimum[key] = $2
      } else if ($1 == "protection:") {
        line = $0
        gsub(/[^0-9 ]/, " ", line)
        count = split(line, values, " ")
        for (index_value = 1; index_value <= count; index_value++) protection[key, index_value - 1] = values[index_value]
      }
      next
    }
    $1 == "Node" {
      node = $2
      sub(/,$/, "", node)
      key = node SUBSEP $4
      if (!(node in normal) || !(key in position) || !(key in free) || !(key in minimum)) next
      if (position[key] > normal[node]) next
      floor = minimum[key] + protection[key, normal[node]]
      ring_blocks = 0
      pageblocks = 0
      for (field = 5; field <= NF; field++) {
        if (field - 5 >= ring) ring_blocks += $field
        if (field - 5 >= pageblock) pageblocks += $field
      }
      if (free[key] - (2 ^ ring - 1) > floor) total_ring += ring_blocks
      if (free[key] - (2 ^ pageblock - 1) > floor) total_pageblocks += pageblocks
      observed = 1
    }
    END {
      if (!observed) exit 1
      printf "%d %d\n", total_ring, total_pageblocks
    }
  ' "$zoneinfo" "$buddyinfo" 2>/dev/null
) || high_order=
ring_blocks=
pageblocks=
if [[ $high_order =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
  ring_blocks=${BASH_REMATCH[1]}
  pageblocks=${BASH_REMATCH[2]}
fi

full_pressure() {
  local line
  while IFS= read -r line; do
    if [[ $line =~ ^full\ avg10=[0-9]+\.[0-9]+\ avg60=([0-9]+\.[0-9]+)\  ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$pressure_root/$1"
  return 1
}
memory_full=$(full_pressure memory 2>/dev/null) || memory_full=
io_full=$(full_pressure io 2>/dev/null) || io_full=

json_number() {
  if [[ -n $1 ]]; then printf '%s\n' "$1"; else printf 'null\n'; fi
}

"$jq_command" -cn \
  --argjson version "$envelope_version" \
  --arg vmbus_outcome "$vmbus_outcome" \
  --arg vmbus_state "$vmbus_state" \
  --argjson vmbus "$(json_number "$vmbus_failures")" \
  --argjson journal_timeout "$journal_timeout_seconds" \
  --arg relay_outcome "$relay_outcome" \
  --argjson relays "$(json_number "$stuck_relays")" \
  --argjson relay_age "$relay_minimum_age_seconds" \
  --arg high_order_outcome "$high_order_outcome" \
  --argjson ring_blocks "$(json_number "$ring_blocks")" \
  --argjson pageblocks "$(json_number "$pageblocks")" \
  --arg memory_pressure_outcome "$memory_pressure_outcome" \
  --argjson memory_full "$(json_number "$memory_full")" \
  --arg io_pressure_outcome "$io_pressure_outcome" \
  --argjson io_full "$(json_number "$io_full")" \
  --argjson pressure_warning "$pressure_warning" \
  --argjson pressure_failure "$pressure_failure" '
    def outcome($id; $status; $message): {id: $id, status: $status, message: $message};
    def pressure($id; $kind; $value):
      if $value == null then outcome($id; "fail"; "could not read \($kind) pressure")
      else
        (if $value >= $pressure_failure then "fail"
         elif $value >= $pressure_warning then "warn"
         else "pass" end) as $status
        | outcome($id; $status; "\($kind) full pressure averaged \($value)% over 60s")
      end;
    {
      schemaVersion: $version,
      outcomes: [
        (if $vmbus_state == "timeout" then
           outcome($vmbus_outcome; "warn"; "kernel log scan did not finish within \($journal_timeout)s")
         elif $vmbus == null then
           outcome($vmbus_outcome; "fail"; "could not read the kernel log of this boot")
         elif $vmbus > 0 then
           outcome($vmbus_outcome; "fail"; "\($vmbus) VMBus ring allocations failed in this boot")
         else
           outcome($vmbus_outcome; "pass"; "no VMBus ring allocation failed in this boot")
         end),
        (if $relays == null then
           outcome($relay_outcome; "fail"; "could not list processes")
         elif $relays > 0 then
           outcome($relay_outcome; "fail"; "\($relays) WSL Relay processes have been orphaned for at least \($relay_age)s")
         else
           outcome($relay_outcome; "pass"; "no WSL Relay process is orphaned")
         end),
        (if $ring_blocks == null then
           outcome($high_order_outcome; "fail"; "could not read free page blocks")
         elif $ring_blocks == 0 then
           outcome($high_order_outcome; "fail"; "no free block can serve a VMBus ring allocation")
         elif $pageblocks == 0 then
           outcome($high_order_outcome; "warn"; "no free pageblock remains and \($ring_blocks) free blocks can serve a VMBus ring")
         else
           outcome($high_order_outcome; "pass"; "\($ring_blocks) free blocks can serve a VMBus ring and \($pageblocks) free pageblocks remain")
         end),
        pressure($memory_pressure_outcome; "memory"; $memory_full),
        pressure($io_pressure_outcome; "io"; $io_full)
      ],
      resources: [{
        key: "wslMemory",
        value: {
          vmbusRingFailures: $vmbus,
          stuckRelays: $relays,
          ringOrderBlocks: $ring_blocks,
          pageblocks: $pageblocks,
          memoryFullAvg60: $memory_full,
          ioFullAvg60: $io_full
        }
      }]
    }
  '
