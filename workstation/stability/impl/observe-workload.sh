# shellcheck shell=bash

set -euo pipefail

aggregate_cgroup=@aggregateCgroup@
awk_command=@awkCommand@
cgroup_budget_outcome=@cgroupBudgetOutcome@
cgroup_root=@cgroupRoot@
cpu_online=@cpuOnline@
cpu_outcome=@cpuOutcome@
date_command=@dateCommand@
declared_memory_bytes=@declaredMemoryBytes@
declared_processors=@declaredProcessors@
envelope_version=@envelopeVersion@
host_reserve_percent=@hostReservePercent@
io_pressure_outcome=@ioPressureOutcome@
jq_command=@jqCommand@
linux_memory_outcome=@linuxMemoryOutcome@
memory_pressure_outcome=@memoryPressureOutcome@
meminfo=@meminfo@
pressure_failure=@pressureFailure@
pressure_root=@pressureRoot@
pressure_warning=@pressureWarning@
proc_cgroup=@procCgroup@
proc_status=@procStatus@
reader_command=@readerCommand@
reader_timeout_seconds=@readerTimeoutSeconds@
timeout_command=@timeoutCommand@
windows_commit_failure=@windowsCommitFailure@
windows_commit_warning=@windowsCommitWarning@
windows_memory_outcome=@windowsMemoryOutcome@
windows_physical_reserve_bytes=@windowsPhysicalReserveBytes@
wsl_cap_outcome=@wslCapOutcome@

bytes_pattern='^(0|[1-9][0-9]{0,17})$'
cgroup_path_pattern='^/(([A-Za-z0-9_.@:\\-]+/)*[A-Za-z0-9_.@:\\-]+)?$'
dot_component_pattern='(^|/)\.\.?(/|$)'

read_first_line() {
  local -n line=$2
  { IFS= read -r line || [[ -n $line ]]; } 2>/dev/null <"$1"
}

cpu_list_count() {
  "$awk_command" -F, '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) {
          count++
        } else if ($i ~ /^[0-9]+-[0-9]+$/) {
          split($i, bounds, "-")
          if (bounds[2] + 0 < bounds[1] + 0) bad = 1
          count += bounds[2] - bounds[1] + 1
        } else {
          bad = 1
        }
      }
    }
    END { if (bad || count < 1) exit 1; printf "%d\n", count }
  '
}

meminfo_kilobytes() {
  "$awk_command" -v key="$1:" '
    $1 == key && $3 == "kB" && $2 ~ /^(0|[1-9][0-9]{0,14})$/ { print $2; found = 1; exit }
    END { exit !found }
  ' "$meminfo" 2>/dev/null
}

self_cgroup_path() {
  local line
  while IFS= read -r line; do
    if [[ $line == 0::* ]]; then
      printf '%s\n' "${line#0::}"
      return 0
    fi
  done <"$proc_cgroup"
  return 1
}

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

# page cache は上限まで増えるため、active な cache を使用中と数えると headroom が時間とともに 0 へ張り付き、
# host 側の MemAvailable とも定義が食い違う。map 中、dirty、writeback 中の page は直ちに回収できないため控除しない
# この式は memoryLimits の階層にも memoryScopes の scope にも使い、supervise の入場は scope の値をここから読む。他に同じ式を置かない
usage_current=
usage_working=
usage_bytes() {
  local key value reclaimable
  local -A file=()
  read_first_line "$1/memory.current" usage_current && [[ $usage_current =~ $bytes_pattern ]] || return 1
  while read -r key value _ || [[ -n $key ]]; do
    case $key in
      inactive_file|active_file|file_mapped|file_dirty|file_writeback)
        [[ $value =~ $bytes_pattern ]] || return 1
        file[$key]=$value
        ((${#file[@]} == 5)) && break
        ;;
    esac
  done 2>/dev/null <"$1/memory.stat" || return 1
  ((${#file[@]} == 5)) || return 1
  reclaimable=$((file[inactive_file] + file[active_file] - file[file_mapped] - file[file_dirty] - file[file_writeback]))
  if ((reclaimable < 0)); then
    reclaimable=0
  fi
  usage_working=$((usage_current > reclaimable ? usage_current - reclaimable : 0))
}

# 読めない階層を制限なしとみなす楽観のため読取り失敗の無視は不可
controller_disabled() {
  local controllers
  read_first_line "$1/cgroup.controllers" controllers || return 1
  [[ " $controllers " != *" $2 "* ]]
}

memory_limit_rows=()
cpu_quota_rows=()

memory_level() {
  local directory=$1 path=$2 file value limit headroom
  [[ -d $directory ]] || return 1
  if [[ ! -e $directory/memory.max && ! -e $directory/memory.high ]]; then
    controller_disabled "$directory" memory
    return
  fi
  limit=
  for file in memory.max memory.high; do
    read_first_line "$directory/$file" value || return 1
    if [[ $value == max ]]; then
      continue
    fi
    [[ $value =~ $bytes_pattern ]] || return 1
    if [[ -z $limit ]] || ((value < limit)); then
      limit=$value
    fi
  done
  if [[ -z $limit ]]; then
    return 0
  fi
  usage_bytes "$directory" || return 1
  headroom=0
  if ((limit > usage_working)); then
    headroom=$((limit - usage_working))
  fi
  memory_limit_rows+=("$path"$'\t'"$headroom"$'\t'"$limit"$'\t'"$usage_current"$'\t'"$usage_working")
}

cpu_level() {
  local directory=$1 value quota period
  if [[ ! -e $directory/cpu.max ]]; then
    controller_disabled "$directory" cpu
    return
  fi
  read_first_line "$directory/cpu.max" value || return 1
  read -r quota period <<<"$value"
  [[ ${period-} =~ ^[1-9][0-9]{0,9}$ ]] || return 1
  if [[ $quota == max ]]; then
    return 0
  fi
  [[ $quota =~ ^[1-9][0-9]{0,15}$ ]] || return 1
  cpu_quota_rows+=("$quota $period")
}

memory_total=
if total_kilobytes=$(meminfo_kilobytes MemTotal) && ((total_kilobytes > 0)); then
  memory_total=$((total_kilobytes * 1024))
fi
memory_available=
if available_kilobytes=$(meminfo_kilobytes MemAvailable); then
  memory_available=$((available_kilobytes * 1024))
fi
# 総量を超える空きを total へ丸めると楽観になるため丸めは不可
if [[ -n $memory_total && -n $memory_available ]] && ((memory_available > memory_total)); then
  memory_available=
fi

cgroup_known=1
cpu_known=1
# 引数は、これから process を置く cgroup。無ければ呼んだ process 自身の cgroup から辿る
if (($# > 0)); then
  cgroup_path=$1
else
  cgroup_path=$(self_cgroup_path 2>/dev/null) || cgroup_path=
fi
if [[ ! $cgroup_path =~ $cgroup_path_pattern || $cgroup_path =~ $dot_component_pattern ]]; then
  cgroup_known=0
  cpu_known=0
  cgroup_path=/
elif ! read_first_line "$cgroup_root/cgroup.controllers" controllers; then
  cgroup_known=0
  cpu_known=0
elif (($# > 0)); then
  # 置き先の slice は、中に scope が無い間は cgroup が存在しない。上限は存在する最も近い祖先から上に掛かる
  while [[ $cgroup_path != / && ! -d $cgroup_root$cgroup_path ]]; do
    cgroup_path=${cgroup_path%/*}
    if [[ -z $cgroup_path ]]; then
      cgroup_path=/
    fi
  done
fi
path=$cgroup_path
while [[ $path != / ]]; do
  memory_level "$cgroup_root$path" "$path" || cgroup_known=0
  cpu_level "$cgroup_root$path" || cpu_known=0
  path=${path%/*}
  if [[ -z $path ]]; then
    path=/
  fi
done

memory_limits=[]
if ((${#memory_limit_rows[@]} > 0)); then
  memory_limits=$(
    printf '%s\n' "${memory_limit_rows[@]}" \
      | "$jq_command" -Rcn '[inputs | split("\t") | {path: .[0], headroomBytes: (.[1] | tonumber), limitBytes: (.[2] | tonumber), currentBytes: (.[3] | tonumber), workingSetBytes: (.[4] | tonumber)}]'
  )
fi

# 引数の 2 つ目以降は、直下の scope の使用量も求める cgroup。入場の判定が、走行中の scope の使い増せる量を求めるのに使う。
# working set の式は usage_bytes だけが持ち、supervise はここで報告した値を読む。読めない scope は載せない
memory_scope_rows=()
for scope_parent in "${@:2}"; do
  if [[ $scope_parent == / || ! $scope_parent =~ $cgroup_path_pattern || $scope_parent =~ $dot_component_pattern ]]; then
    cgroup_known=0
    continue
  fi
  for scope_directory in "$cgroup_root$scope_parent"/*.scope; do
    [[ -d $scope_directory ]] || continue
    usage_bytes "$scope_directory" || continue
    memory_scope_rows+=("$scope_parent/${scope_directory##*/}"$'\t'"$usage_current"$'\t'"$usage_working")
  done
done
memory_scopes=[]
if ((${#memory_scope_rows[@]} > 0)); then
  memory_scopes=$(
    printf '%s\n' "${memory_scope_rows[@]}" \
      | "$jq_command" -Rcn '[inputs | split("\t") | {path: .[0], currentBytes: (.[1] | tonumber), workingSetBytes: (.[2] | tonumber)}]'
  )
fi

# host の基盤が既に使う分は reserve の一部のため reserve 全量を空きから引く二重の控除は不可
reserve_bytes=
reserve_charged_bytes=
host_headroom=
if [[ -n $memory_total && -n $memory_available ]]; then
  reserve_bytes=$(((memory_total * host_reserve_percent + 99) / 100))
  reserve_charged_bytes=$reserve_bytes
  if usage_bytes "$cgroup_root$aggregate_cgroup"; then
    outside_bytes=$((memory_total - memory_available))
    if ((outside_bytes > usage_working)); then
      outside_bytes=$((outside_bytes - usage_working))
    else
      outside_bytes=0
    fi
    if ((reserve_bytes > outside_bytes)); then
      reserve_charged_bytes=$((reserve_bytes - outside_bytes))
    else
      reserve_charged_bytes=0
    fi
  fi
  host_headroom=0
  if ((memory_available > reserve_charged_bytes)); then
    host_headroom=$((memory_available - reserve_charged_bytes))
  fi
fi

cpu_affinity=
affinity_list=$(
  "$awk_command" -F'\t' '
    $1 == "Cpus_allowed_list:" { gsub(/[[:space:]]/, "", $2); print $2; found = 1; exit }
    END { exit !found }
  ' "$proc_status" 2>/dev/null
) || affinity_list=
cpu_affinity=$(cpu_list_count <<<"$affinity_list" 2>/dev/null) || cpu_affinity=
read_first_line "$cpu_online" online_list || online_list=
online_processors=$(cpu_list_count <<<"$online_list" 2>/dev/null) || online_processors=

cpu_quota=
if ((${#cpu_quota_rows[@]} > 0)); then
  cpu_quota=$(
    printf '%s\n' "${cpu_quota_rows[@]}" | "$awk_command" '
      NF == 2 && $2 > 0 {
        ratio = $1 / $2
        if (!seen || ratio < smallest) { smallest = ratio; seen = 1 }
      }
      END { if (!seen) exit 1; printf "%.3f\n", smallest }
    '
  ) || cpu_known=0
fi
cpu_count=
if ((cpu_known == 1)) && [[ -n $cpu_affinity ]]; then
  cpu_count=$cpu_affinity
  if [[ -n $cpu_quota ]]; then
    quota_cpus=${cpu_quota%%.*}
    if [[ ! $quota_cpus =~ ^[0-9]{1,9}$ ]]; then
      quota_cpus=999999999
    fi
    if ((quota_cpus < 1)); then
      quota_cpus=1
    fi
    if ((quota_cpus < cpu_count)); then
      cpu_count=$quota_cpus
    fi
  fi
fi

memory_full=$(full_pressure memory 2>/dev/null) || memory_full=
io_full=$(full_pressure io 2>/dev/null) || io_full=

observed_at=$("$date_command" +%s 2>/dev/null) || observed_at=
if [[ ! $observed_at =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
  observed_at=
fi

windows_snapshot=$("$timeout_command" --signal=TERM --kill-after=1s "${reader_timeout_seconds}s" \
  "$reader_command" 2>/dev/null) || windows_snapshot=
windows_snapshot=$(
  "$jq_command" -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' \
    <<<"$windows_snapshot" 2>/dev/null
) || windows_snapshot=
if [[ -z $windows_snapshot ]]; then
  windows_snapshot='{"state":"unavailable"}'
fi

"$jq_command" -cn \
  --argjson version "$envelope_version" \
  --arg linux_memory_outcome "$linux_memory_outcome" \
  --arg cgroup_budget_outcome "$cgroup_budget_outcome" \
  --arg cpu_outcome "$cpu_outcome" \
  --arg memory_pressure_outcome "$memory_pressure_outcome" \
  --arg io_pressure_outcome "$io_pressure_outcome" \
  --arg windows_memory_outcome "$windows_memory_outcome" \
  --arg wsl_cap_outcome "$wsl_cap_outcome" \
  --argjson observed_at "${observed_at:-null}" \
  --argjson memory_total "${memory_total:-null}" \
  --argjson memory_available "${memory_available:-null}" \
  --argjson cgroup_known "$cgroup_known" \
  --argjson memory_limits "$memory_limits" \
  --argjson memory_scopes "$memory_scopes" \
  --argjson reserve_bytes "${reserve_bytes:-null}" \
  --argjson reserve_charged_bytes "${reserve_charged_bytes:-null}" \
  --argjson host_headroom "${host_headroom:-null}" \
  --argjson cpu_count "${cpu_count:-null}" \
  --argjson cpu_affinity "${cpu_affinity:-null}" \
  --argjson cpu_quota "${cpu_quota:-null}" \
  --argjson online_processors "${online_processors:-null}" \
  --argjson declared_memory "${declared_memory_bytes:-null}" \
  --argjson declared_processors "${declared_processors:-null}" \
  --argjson memory_full "${memory_full:-null}" \
  --argjson io_full "${io_full:-null}" \
  --argjson pressure_warning "$pressure_warning" \
  --argjson pressure_failure "$pressure_failure" \
  --argjson windows_commit_warning "$windows_commit_warning" \
  --argjson windows_commit_failure "$windows_commit_failure" \
  --argjson windows_physical_reserve "$windows_physical_reserve_bytes" \
  --argjson snapshot "$windows_snapshot" '
    def outcome($id; $status; $message): {id: $id, status: $status, message: $message};
    def pressure($id; $kind; $value):
      if $value == null then outcome($id; "fail"; "could not read \($kind) pressure")
      else
        (if $value >= $pressure_failure then "fail"
         elif $value >= $pressure_warning then "warn"
         else "pass" end) as $status
        | outcome($id; $status; "\($kind) full pressure averaged \($value)% over 60s")
      end;
    def finding($code; $condition): if $condition then $code else empty end;
    def explanation: {
      configuredMemoryDiffersFromDeclared: "the Windows .wslconfig memory differs from the declared cap",
      configuredProcessorsDiffersFromDeclared: "the Windows .wslconfig processors differ from the declared count",
      effectiveMemoryExceedsConfigured: "the running VM has more memory than the Windows .wslconfig now sets, so WSL has not restarted since it changed",
      effectiveProcessorsExceedConfigured: "the running VM has more processors than the Windows .wslconfig now sets, so WSL has not restarted since it changed",
      effectiveMemoryExceedsDeclared: "the running VM has more memory than the declared cap",
      effectiveProcessorsExceedDeclared: "the running VM has more processors than the declared count"
    }[.];

    ($cgroup_known == 1) as $cgroup_ok
    | (if $host_headroom != null and $cgroup_ok
       then ([$host_headroom] + ($memory_limits | map(.headroomBytes)) | min)
       else null end) as $headroom
    | ($snapshot.state // "unavailable") as $reported
    | ([$snapshot.physicalTotalBytes, $snapshot.physicalAvailableBytes, $snapshot.commitUsedBytes,
        $snapshot.commitLimitBytes, $snapshot.ageSeconds, $snapshot.observedAt]
       | all(type == "number") and ($snapshot.commitLimitBytes > 0)) as $complete
    | (if $reported == "fresh" and ($complete | not) then "invalid"
       elif ($reported | IN("fresh", "stale", "future", "invalid", "unavailable")) then $reported
       else "unavailable" end) as $window
    | (if $window == "fresh"
       then ($snapshot.commitUsedBytes * 100 / $snapshot.commitLimitBytes | floor | if . > 100 then 100 else . end)
       else null end) as $commit_percent
    | (if $window == "fresh" and ($snapshot.wslConfig.state | IN("read", "missing"))
       then $snapshot.wslConfig
       else null end) as $configured
    | [
        finding("configuredMemoryDiffersFromDeclared";
          $configured != null and $declared_memory != null and $configured.memoryBytes != $declared_memory),
        finding("configuredProcessorsDiffersFromDeclared";
          $configured != null and $declared_processors != null and $configured.processors != $declared_processors),
        finding("effectiveMemoryExceedsConfigured";
          $configured.memoryBytes != null and $memory_total != null and $memory_total > $configured.memoryBytes),
        finding("effectiveProcessorsExceedConfigured";
          $configured.processors != null and $online_processors != null and $online_processors > $configured.processors),
        finding("effectiveMemoryExceedsDeclared";
          $configured == null and $declared_memory != null and $memory_total != null and $memory_total > $declared_memory),
        finding("effectiveProcessorsExceedDeclared";
          $configured == null and $declared_processors != null and $online_processors != null and $online_processors > $declared_processors)
      ] as $findings
    | (($declared_memory != null and $memory_total == null)
       or ($declared_processors != null and $online_processors == null)) as $unverifiable
    | {
        schemaVersion: $version,
        outcomes: [
          (if $memory_total == null or $memory_available == null then
             outcome($linux_memory_outcome; "fail"; "could not read a consistent MemAvailable and MemTotal")
           elif $observed_at == null then
             outcome($linux_memory_outcome; "fail"; "could not read the clock")
           else
             outcome($linux_memory_outcome; "pass";
               "MemAvailable \($memory_available) of MemTotal \($memory_total) bytes with \($reserve_charged_bytes) bytes of host reserve still unspent")
           end),
          (if $cgroup_ok then
             outcome($cgroup_budget_outcome; "pass";
               (if ($memory_limits | length) == 0 then "no ancestor cgroup memory limit applies"
                else "\($memory_limits | length) ancestor cgroup memory limits apply, the tightest leaves \($memory_limits | map(.headroomBytes) | min) bytes" end))
           else
             outcome($cgroup_budget_outcome; "fail"; "could not establish the memory limits of the cgroup chain")
           end),
          (if $cpu_count == null then
             outcome($cpu_outcome; "fail"; "could not establish the usable CPU count")
           else
             outcome($cpu_outcome; "pass"; "\($cpu_count) CPUs usable, affinity \($cpu_affinity), quota \($cpu_quota // "none")")
           end),
          pressure($memory_pressure_outcome; "memory"; $memory_full),
          pressure($io_pressure_outcome; "io"; $io_full),
          (if $window == "fresh" then
             (if $commit_percent >= $windows_commit_failure then "fail"
              elif $commit_percent >= $windows_commit_warning then "warn"
              else "pass" end) as $status
             | outcome($windows_memory_outcome; $status;
                 "Windows committed memory used \($commit_percent)% in a snapshot taken \($snapshot.ageSeconds)s ago")
           elif $window == "stale" then
             outcome($windows_memory_outcome; "fail";
               "Windows memory snapshot is stale: \($snapshot.ageSeconds)s old and at most \($snapshot.maximumAgeSeconds)s is accepted")
           elif $window == "future" then
             outcome($windows_memory_outcome; "fail";
               "Windows memory snapshot is dated \(-($snapshot.ageSeconds))s in the future")
           elif $window == "invalid" then
             outcome($windows_memory_outcome; "fail"; "Windows memory snapshot is not a valid record")
           else
             outcome($windows_memory_outcome; "fail"; "Windows memory snapshot is unavailable")
           end),
          (if $unverifiable then
             outcome($wsl_cap_outcome; "fail"; "could not compare the running VM with the declared WSL cap")
           elif ($findings | length) > 0 then
             outcome($wsl_cap_outcome; "warn";
               "WSL cap declaration drift, a diagnosis only because admission measures the running VM: \($findings | map(explanation) | join("; "))")
           elif $declared_memory == null and $declared_processors == null then
             outcome($wsl_cap_outcome; "pass"; "no WSL memory or processor cap is declared")
           elif $configured == null then
             outcome($wsl_cap_outcome; "pass"; "the running VM is within the declared cap and the Windows .wslconfig was not read")
           else
             outcome($wsl_cap_outcome; "pass"; "the configured caps match the declaration and the running VM is within them; this does not prove a pending increase has taken effect")
           end)
        ],
        resources: [{
          key: "workload",
          value: {
            observedAt: $observed_at,
            memoryAvailableBytes: $memory_available,
            memoryTotalBytes: $memory_total,
            cpuCount: $cpu_count,
            memoryHeadroomBytes: $headroom,
            hostMemoryHeadroomBytes: $host_headroom,
            hostReserveBytes: $reserve_bytes,
            hostReserveChargedBytes: $reserve_charged_bytes,
            memoryLimits: (if $cgroup_ok then $memory_limits else null end),
            memoryScopes: (if $cgroup_ok then $memory_scopes else null end),
            windowsCommitHeadroomBytes:
              (if $window == "fresh"
               then ([(($snapshot.commitLimitBytes * $windows_commit_warning / 100 | floor) - $snapshot.commitUsedBytes), 0] | max)
               else null end),
            windowsCommitRemainingBytes:
              (if $window == "fresh" then ([$snapshot.commitLimitBytes - $snapshot.commitUsedBytes, 0] | max) else null end),
            windowsPhysicalAvailableBytes:
              (if $window == "fresh" then $snapshot.physicalAvailableBytes else null end),
            windowsPhysicalHeadroomBytes:
              (if $window == "fresh" then ([$snapshot.physicalAvailableBytes - $windows_physical_reserve, 0] | max) else null end),
            windowsPhysicalReserveBytes: $windows_physical_reserve,
            windowsCommitUsedPercent: $commit_percent,
            windows: {
              state: $window,
              observedAt: (if $window | IN("fresh", "stale", "future") then $snapshot.observedAt else null end),
              ageSeconds: (if $window | IN("fresh", "stale", "future") then $snapshot.ageSeconds else null end)
            },
            memoryFullAvg60: $memory_full,
            ioFullAvg60: $io_full,
            cpuAffinityCount: $cpu_affinity,
            cpuQuotaCpus: $cpu_quota,
            wslCap: {
              declared: {memoryBytes: $declared_memory, processors: $declared_processors},
              configured: (if $window == "fresh"
                           then ($snapshot.wslConfig // {state: "unknown", memoryBytes: null, processors: null})
                           else {state: "unknown", memoryBytes: null, processors: null} end),
              effective: {memoryBytes: $memory_total, processors: $online_processors},
              findings: $findings
            }
          }
        }]
      }
  '
