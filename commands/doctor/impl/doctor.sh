usage() {
  cat <<'USAGE'
usage: dotfiles-doctor [--json]

Reconcile the declared dotfiles deployment with the running system. Exit 0
when checks only pass or warn, 1 when any check fails.
USAGE
}

json=0
case "${1-}" in
  --json) json=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

agent_table=@agentTable@
artifact_table=@artifactTable@
secret_table=@secretTable@
service_table=@serviceTable@
maintenance_table=@maintenanceTable@
managed_root_table=@managedRootTable@
container_table=@containerTable@
health_table=@healthTable@
mcp_table=@mcpTable@
gateway_json=@gatewayUrl@

curl_command=@curlCommand@
docker_command=@dockerCommand@
jq_command=@jqCommand@
cmp_command=@cmpCommand@
readlink_command=@readlinkCommand@
stat_command=@statCommand@
systemctl_command=@systemctlCommand@
timeout_command=@timeoutCommand@
swapon_command=@swaponCommand@
zramctl_command=@zramctlCommand@
df_command=@dfCommand@
powershell_command=@powershellCommand@
journalctl_command=@journalctlCommand@
du_command=@duCommand@

checks=()
warnings=()
failures=()
resources=()

probe_timeout_seconds=10
minimum_swap_bytes=8589934592
root_warning_percent=85
root_failure_percent=95
windows_warning_percent=15
windows_failure_percent=10
maximum_journal_bytes=4294967296
restart_warning_count=5
restart_failure_count=20

run_bounded() {
  "$timeout_command" --signal=TERM --kill-after=2s "${probe_timeout_seconds}s" "$@"
}

record_pass() {
  local id=$1
  local check
  check=$("$jq_command" -cn --arg id "$id" '{id:$id,status:"pass"}')
  checks+=("$check")
}

record_failure() {
  local id=$1
  local message=$2
  local check failure
  check=$("$jq_command" -cn --arg id "$id" '{id:$id,status:"fail"}')
  failure=$("$jq_command" -cn --arg id "$id" --arg message "$message" '{id:$id,message:$message}')
  checks+=("$check")
  failures+=("$failure")
}

record_warning() {
  local id=$1
  local message=$2
  local check warning
  check=$("$jq_command" -cn --arg id "$id" '{id:$id,status:"warn"}')
  warning=$("$jq_command" -cn --arg id "$id" --arg message "$message" '{id:$id,message:$message}')
  checks+=("$check")
  warnings+=("$warning")
}

record_resource() {
  local key=$1
  local value=$2
  local resource
  resource=$("$jq_command" -cn --arg key "$key" --argjson value "$value" \
    '{key:$key,value:$value}')
  resources+=("$resource")
}

probe_unit() {
  local id=$1
  local unit=$2
  local load_state active_state result

  if load_state=$(run_bounded "$systemctl_command" show "$unit" --property=LoadState --value 2>&1) \
    && active_state=$(run_bounded "$systemctl_command" show "$unit" --property=ActiveState --value 2>&1) \
    && result=$(run_bounded "$systemctl_command" show "$unit" --property=Result --value 2>&1); then
    if [[ $load_state == loaded && $active_state == active && $result == success ]]; then
      record_pass "$id"
    else
      record_failure "$id" "$unit is $load_state/$active_state/$result"
    fi
  else
    record_failure "$id" "could not read systemd state for $unit"
  fi
}

decode_response() {
  local headers=$1
  local body=$2
  local expected_id=$3
  local output=$4
  local line header_name header_value media_type
  local data_seen=0
  local payload=
  local response_count=0
  local -a content_types=()
  local -a events=()

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    header_name=${line%%:*}
    if [[ ${header_name,,} == content-type ]]; then
      header_value=${line#*:}
      header_value=${header_value#"${header_value%%[![:space:]]*}"}
      header_value=${header_value%"${header_value##*[![:space:]]}"}
      content_types+=("$header_value")
    fi
  done <"$headers"

  ((${#content_types[@]} == 1)) || return 1
  media_type=${content_types[0]%%;*}
  media_type=${media_type%"${media_type##*[![:space:]]}"}
  media_type=${media_type,,}

  if [[ $media_type == application/json ]]; then
    "$jq_command" -cse --argjson expected_id "$expected_id" '
      if length == 1
        and .[0].jsonrpc == "2.0"
        and .[0].id == $expected_id
        and (.[0] | has("method") | not)
        and ((.[0] | has("result")) or (.[0] | has("error")))
      then .[0]
      else empty
      end
    ' "$body" >"$output"
    return
  fi

  [[ $media_type == text/event-stream ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ -z $line ]]; then
      if ((data_seen == 1)); then
        events+=("$payload")
        data_seen=0
        payload=
      fi
      continue
    fi
    [[ $line == data:* ]] || continue
    line=${line#data:}
    line=${line# }
    if ((data_seen == 1)); then
      payload+=$'\n'
    fi
    payload+=$line
    data_seen=1
  done <"$body"
  if ((data_seen == 1)); then
    events+=("$payload")
  fi

  : >"$output"
  for payload in "${events[@]}"; do
    "$jq_command" -e . >/dev/null 2>&1 <<<"$payload" || return 1
    if "$jq_command" -e --argjson expected_id "$expected_id" '
      .jsonrpc == "2.0"
      and .id == $expected_id
      and (has("method") | not)
      and (has("result") or has("error"))
    ' >/dev/null <<<"$payload"; then
      ((response_count += 1))
      printf '%s\n' "$payload" >"$output"
    elif ! "$jq_command" -e '
      .jsonrpc == "2.0"
      and (.method | type == "string")
      and (has("result") | not)
      and (has("error") | not)
    ' >/dev/null <<<"$payload"; then
      return 1
    fi
  done

  ((response_count == 1))
}

emit_json() {
  local checks_file=$doctor_tmp/checks.jsonl
  local warnings_file=$doctor_tmp/warnings.jsonl
  local failures_file=$doctor_tmp/failures.jsonl
  local resources_file=$doctor_tmp/resources.jsonl

  : >"$checks_file"
  : >"$warnings_file"
  : >"$failures_file"
  : >"$resources_file"
  if ((${#checks[@]} > 0)); then
    printf '%s\n' "${checks[@]}" >"$checks_file"
  fi
  if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}" >"$failures_file"
  fi
  if ((${#warnings[@]} > 0)); then
    printf '%s\n' "${warnings[@]}" >"$warnings_file"
  fi
  if ((${#resources[@]} > 0)); then
    printf '%s\n' "${resources[@]}" >"$resources_file"
  fi

  "$jq_command" -cn \
    --slurpfile checks "$checks_file" \
    --slurpfile warnings "$warnings_file" \
    --slurpfile failures "$failures_file" \
    --slurpfile resources "$resources_file" \
    '{checks:$checks,warnings:$warnings,failures:$failures,resources:($resources | from_entries)}'
}

doctor_tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor.XXXXXX")
trap 'rm -rf -- "$doctor_tmp"' EXIT

# 1. System generation reconciliation.
if current_system=$("$readlink_command" -f /run/current-system 2>&1) \
  && profile_system=$("$readlink_command" -f /nix/var/nix/profiles/system 2>&1); then
  if [[ $current_system == "$profile_system" ]]; then
    record_pass system-generation
  else
    record_failure system-generation "/run/current-system does not match the system profile"
  fi
else
  record_failure system-generation "could not resolve the current system generation"
fi

# 2. Active swap must retain the declared WSL pressure hierarchy.
swap_valid=1
zram_output=
swap_output=
declare -A zram_algorithms=()
if zram_output=$(run_bounded "$zramctl_command" --noheadings --raw --output NAME,ALGORITHM 2>/dev/null); then
  while read -r zram_name zram_algorithm extra; do
    [[ -n $zram_name ]] || continue
    if [[ -n ${extra-} || $zram_name != /dev/zram* || -z $zram_algorithm ]]; then
      swap_valid=0
      break
    fi
    zram_algorithms[$zram_name]=$zram_algorithm
  done <<<"$zram_output"
else
  swap_valid=0
fi

total_swap_bytes=0
zram_devices=0
disk_devices=0
min_zram_priority=0
max_disk_priority=0
zram_algorithm_valid=1
swap_algorithms=()
if swap_output=$(run_bounded "$swapon_command" --show=NAME,TYPE,SIZE,PRIO --bytes --noheadings --raw 2>/dev/null); then
  while read -r swap_name swap_type swap_size swap_priority extra; do
    [[ -n $swap_name ]] || continue
    if [[ -n ${extra-} || -z $swap_type || ! $swap_size =~ ^[0-9]+$ \
      || ! $swap_priority =~ ^-?[0-9]+$ ]]; then
      swap_valid=0
      break
    fi

    total_swap_bytes=$((total_swap_bytes + swap_size))
    if [[ $swap_name == /dev/zram* ]]; then
      zram_devices=$((zram_devices + 1))
      if ((zram_devices == 1 || swap_priority < min_zram_priority)); then
        min_zram_priority=$swap_priority
      fi
      algorithm=${zram_algorithms[$swap_name]-}
      if [[ $algorithm != lzo-rle ]]; then
        zram_algorithm_valid=0
      fi
      [[ -z $algorithm ]] || swap_algorithms+=("$algorithm")
    else
      disk_devices=$((disk_devices + 1))
      if ((disk_devices == 1 || swap_priority > max_disk_priority)); then
        max_disk_priority=$swap_priority
      fi
    fi
  done <<<"$swap_output"
else
  swap_valid=0
fi

if ((swap_valid == 1)); then
  algorithms_json=$(printf '%s\n' "${swap_algorithms[@]}" \
    | "$jq_command" -Rsc 'split("\n") | map(select(length > 0)) | unique')
  swap_resource=$("$jq_command" -cn \
    --argjson totalBytes "$total_swap_bytes" \
    --argjson zramDevices "$zram_devices" \
    --argjson diskDevices "$disk_devices" \
    --argjson minZramPriority "$min_zram_priority" \
    --argjson maxDiskPriority "$max_disk_priority" \
    --argjson algorithms "$algorithms_json" \
    '{totalBytes:$totalBytes,zramDevices:$zramDevices,diskDevices:$diskDevices,
      minZramPriority:$minZramPriority,maxDiskPriority:$maxDiskPriority,algorithms:$algorithms}')
  record_resource swap "$swap_resource"
fi

if ((swap_valid == 1 \
  && zram_devices > 0 \
  && zram_algorithm_valid == 1 \
  && (disk_devices == 0 || min_zram_priority > max_disk_priority) \
  && total_swap_bytes >= minimum_swap_bytes)); then
  record_pass resource/swap
else
  record_failure resource/swap \
    "swap must include lzo-rle zram above any disk swap with at least 8 GiB total"
fi

# 3. Root filesystem utilization has warning and failure thresholds.
if root_output=$(run_bounded "$df_command" --output=pcent / 2>/dev/null); then
  root_used=${root_output##*$'\n'}
  root_used=${root_used//[[:space:]]/}
  root_used=${root_used%%%}
else
  root_used=
fi
if [[ $root_used =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((root_used <= 100)); then
  root_resource=$("$jq_command" -cn --argjson usedPercent "$root_used" \
    '{usedPercent:$usedPercent}')
  record_resource rootFilesystem "$root_resource"
  if ((root_used >= root_failure_percent)); then
    record_failure resource/root-filesystem "root filesystem utilization is at least 95%"
  elif ((root_used >= root_warning_percent)); then
    record_warning resource/root-filesystem "root filesystem utilization is at least 85%"
  else
    record_pass resource/root-filesystem
  fi
else
  record_failure resource/root-filesystem "could not observe root filesystem utilization"
fi

# 4. Windows D: capacity is queried through a fixed, non-interactive PowerShell command.
powershell_probe="\$drive = Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='D:'\"; if (\$null -eq \$drive -or \$drive.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor((\$drive.FreeSpace * 100) / \$drive.Size))"
if windows_output=$(
  run_bounded "$powershell_command" \
    -NoLogo -NoProfile -NonInteractive -Command "$powershell_probe" 2>/dev/null
  windows_status=$?
  printf '\x1f'
  exit "$windows_status"
); then
  windows_output=${windows_output%$'\x1f'}
  if [[ $windows_output == *$'\r\n' ]]; then
    windows_free=${windows_output%$'\r\n'}
  elif [[ $windows_output == *$'\n' ]]; then
    windows_free=${windows_output%$'\n'}
  elif [[ $windows_output == *$'\r' ]]; then
    windows_free=${windows_output%$'\r'}
  else
    windows_free=$windows_output
  fi
else
  windows_free=
fi
if [[ $windows_free =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((windows_free <= 100)); then
  windows_resource=$("$jq_command" -cn --argjson freePercent "$windows_free" \
    '{freePercent:$freePercent}')
  record_resource windowsDDrive "$windows_resource"
  if ((windows_free < windows_failure_percent)); then
    record_failure resource/windows-d-drive "Windows D drive free space is below 10%"
  elif ((windows_free < windows_warning_percent)); then
    record_warning resource/windows-d-drive "Windows D drive free space is below 15%"
  else
    record_pass resource/windows-d-drive
  fi
else
  record_failure resource/windows-d-drive "could not observe Windows D drive free space"
fi

# 5. journalctl is authoritative for the current journal footprint.
if journal_output=$(LC_ALL=C run_bounded "$journalctl_command" --disk-usage 2>/dev/null) \
  && [[ $journal_output =~ take[[:space:]]+up[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]*([KMGTPE]?)(i?B)?[[:space:]]+in ]]; then
  journal_amount=${BASH_REMATCH[1]}
  journal_unit=${BASH_REMATCH[3]}
  journal_bytes=$("$jq_command" -nr --arg amount "$journal_amount" --arg unit "$journal_unit" '
    {"":1,K:1024,M:1048576,G:1073741824,T:1099511627776,
      P:1125899906842624,E:1152921504606846976} as $powers
    | (($amount | tonumber) * $powers[$unit] | floor)
  ')
else
  journal_bytes=
fi
if [[ $journal_bytes =~ ^[0-9]+$ ]]; then
  journal_resource=$("$jq_command" -cn --argjson bytes "$journal_bytes" '{bytes:$bytes}')
  record_resource journald "$journal_resource"
  if ((journal_bytes > maximum_journal_bytes)); then
    record_failure resource/journald "journald disk usage exceeds 4 GiB"
  else
    record_pass resource/journald
  fi
else
  record_failure resource/journald "could not observe journald disk usage"
fi

# 6. Only the three managed roots are summarized, with a timeout per root.
mapfile -t managed_roots < <("$jq_command" -r '.[]' <<<"$managed_root_table")
managed_root_resources=()
managed_roots_valid=1
for managed_root in "${managed_roots[@]}"; do
  if managed_root_kind=$(run_bounded "$stat_command" --format=%F "$managed_root" 2>/dev/null); then
    if [[ $managed_root_kind != directory ]]; then
      managed_roots_valid=0
      continue
    fi
  elif [[ ! -e $managed_root && ! -L $managed_root ]]; then
    managed_root_resource=$("$jq_command" -cn --arg path "$managed_root" \
      '{path:$path,bytes:0}')
    managed_root_resources+=("$managed_root_resource")
    continue
  else
    managed_roots_valid=0
    continue
  fi

  if managed_root_output=$(run_bounded "$du_command" \
    --summarize --bytes --one-file-system -- "$managed_root" 2>/dev/null); then
    read -r managed_root_bytes observed_root extra <<<"$managed_root_output"
    if [[ $managed_root_bytes =~ ^[0-9]+$ && $observed_root == "$managed_root" && -z ${extra-} ]]; then
      managed_root_resource=$("$jq_command" -cn \
        --arg path "$managed_root" --argjson bytes "$managed_root_bytes" \
        '{path:$path,bytes:$bytes}')
      managed_root_resources+=("$managed_root_resource")
      continue
    fi
  fi
  managed_roots_valid=0
done
managed_roots_resource=$(printf '%s\n' "${managed_root_resources[@]}" | "$jq_command" -sc '.')
record_resource managedRoots "$managed_roots_resource"
if ((managed_roots_valid == 1)); then
  record_pass resource/managed-roots
else
  record_failure resource/managed-roots "could not summarize every managed resource root"
fi

# 7. Evaluated maintenance timers must remain loaded, enabled or active, and successful.
mapfile -t maintenance_rows < <("$jq_command" -c '.[]' <<<"$maintenance_table")
for row in "${maintenance_rows[@]}"; do
  timer_unit=$("$jq_command" -r '.timer' <<<"$row")
  timer_service=$("$jq_command" -r '.service' <<<"$row")
  check_id="maintenance/$timer_unit"
  if timer_load=$(run_bounded "$systemctl_command" show "$timer_unit" \
    --property=LoadState --value 2>/dev/null) \
    && timer_enabled=$(run_bounded "$systemctl_command" show "$timer_unit" \
      --property=UnitFileState --value 2>/dev/null) \
    && timer_active=$(run_bounded "$systemctl_command" show "$timer_unit" \
      --property=ActiveState --value 2>/dev/null) \
    && service_load=$(run_bounded "$systemctl_command" show "$timer_service" \
      --property=LoadState --value 2>/dev/null) \
    && service_result=$(run_bounded "$systemctl_command" show "$timer_service" \
      --property=Result --value 2>/dev/null); then
    case "$timer_enabled" in
      enabled | enabled-runtime) timer_is_enabled=1 ;;
      *) timer_is_enabled=0 ;;
    esac
    if [[ $timer_load == loaded \
      && ( $timer_active == active || $timer_is_enabled == 1 ) \
      && $service_load == loaded \
      && $service_result == success ]]; then
      record_pass "$check_id"
    else
      record_failure "$check_id" "$timer_unit or its service is not operational"
    fi
  else
    record_failure "$check_id" "could not read maintenance state for $timer_unit"
  fi
done

# 8. Home Manager activation is operationally distinct from the general roster.
mapfile -t service_rows < <("$jq_command" -c '.[]' <<<"$service_table")
mapfile -t home_manager_rows < <("$jq_command" -c '.[] | select(.role == "home-manager")' <<<"$service_table")
if ((${#home_manager_rows[@]} == 1)); then
  home_manager_unit=$("$jq_command" -r '.unit' <<<"${home_manager_rows[0]}")
  probe_unit home-manager "$home_manager_unit"
else
  record_failure home-manager "service roster must contain exactly one Home Manager unit"
fi

# 9. Agent executables and version commands.
mapfile -t agent_rows < <("$jq_command" -c '.[]' <<<"$agent_table")
if ((${#agent_rows[@]} == 0)); then
  record_failure agent-roster "agent roster is empty"
else
  for row in "${agent_rows[@]}"; do
    agent_id=$("$jq_command" -r '.id' <<<"$row")
    binary=$("$jq_command" -r '.binary' <<<"$row")
    mapfile -t version_args < <("$jq_command" -r '.versionArgs[]' <<<"$row")

    if binary_path=$(command -v -- "$binary") \
      && [[ -x $binary_path ]] \
      && run_bounded "$binary_path" "${version_args[@]}" >/dev/null 2>&1; then
      record_pass "agent/$agent_id"
    else
      record_failure "agent/$agent_id" "$binary is unavailable or its version command failed"
    fi
  done
fi

# 10. Immutable sources must still match their deployed destinations.
mapfile -t artifact_rows < <("$jq_command" -c '.[]' <<<"$artifact_table")
for row in "${artifact_rows[@]}"; do
  artifact_id=$("$jq_command" -r '.id' <<<"$row")
  source_path=$("$jq_command" -r '.source' <<<"$row")
  destination=$("$jq_command" -r '.destination' <<<"$row")
  check_id="artifact/$artifact_id"

  if [[ -L $destination ]]; then
    if resolved_destination=$("$readlink_command" -f "$destination" 2>&1) \
      && [[ $resolved_destination == "$source_path" ]]; then
      record_pass "$check_id"
    else
      record_failure "$check_id" "$destination does not resolve to $source_path"
    fi
  elif [[ -f $destination ]]; then
    if "$cmp_command" --silent "$source_path" "$destination"; then
      record_pass "$check_id"
    else
      record_failure "$check_id" "$destination differs from $source_path"
    fi
  else
    record_failure "$check_id" "$destination is missing or has an unsupported file type"
  fi
done

# 11. Secret contents are never read; only ownership and mode are compared.
mapfile -t secret_rows < <("$jq_command" -c '.[]' <<<"$secret_table")
for row in "${secret_rows[@]}"; do
  secret_id=$("$jq_command" -r '.id' <<<"$row")
  secret_path=$("$jq_command" -r '.path' <<<"$row")
  secret_owner=$("$jq_command" -r '.owner' <<<"$row")
  secret_group=$("$jq_command" -r '.group' <<<"$row")
  secret_mode=$("$jq_command" -r '.mode' <<<"$row")
  expected_metadata="$secret_owner:$secret_group:${secret_mode#0}"

  if actual_metadata=$("$stat_command" --format %U:%G:%a "$secret_path" 2>&1) \
    && [[ $actual_metadata == "$expected_metadata" ]]; then
    record_pass "secret/$secret_id"
  else
    record_failure "secret/$secret_id" "$secret_path metadata does not match $expected_metadata"
  fi
done

# 12. Typed service roster.
if ((${#service_rows[@]} == 0)); then
  record_failure service-roster "service roster is empty"
else
  for row in "${service_rows[@]}"; do
    role=$("$jq_command" -r '.role' <<<"$row")
    [[ $role == home-manager ]] && continue
    unit=$("$jq_command" -r '.unit' <<<"$row")
    probe_unit "service/$unit" "$unit"
  done
fi

# 13. Service restart counters are observed without changing unit state.
service_restart_resources=()
for row in "${service_rows[@]}"; do
  unit=$("$jq_command" -r '.unit' <<<"$row")
  check_id="restart/service/$unit"
  if restart_count=$(run_bounded "$systemctl_command" show "$unit" \
    --property=NRestarts --value 2>/dev/null) \
    && [[ $restart_count =~ ^(0|[1-9][0-9]*)$ ]]; then
    restart_resource=$("$jq_command" -cn --arg unit "$unit" --argjson count "$restart_count" \
      '{unit:$unit,count:$count}')
    service_restart_resources+=("$restart_resource")
    if ((restart_count >= restart_failure_count)); then
      record_failure "$check_id" "$unit has restarted at least 20 times"
    elif ((restart_count >= restart_warning_count)); then
      record_warning "$check_id" "$unit has restarted at least 5 times"
    else
      record_pass "$check_id"
    fi
  else
    record_failure "$check_id" "could not observe restart count for $unit"
  fi
done
service_restarts_resource=$(printf '%s\n' "${service_restart_resources[@]}" | "$jq_command" -sc '.')
record_resource serviceRestarts "$service_restarts_resource"

# 14. Running containers must use the image IDs declared by their image references.
mapfile -t container_rows < <("$jq_command" -c '.[]' <<<"$container_table")
if ((${#container_rows[@]} == 0)); then
  record_failure container-roster "container roster is empty"
else
  for row in "${container_rows[@]}"; do
    container=$("$jq_command" -r '.container' <<<"$row")
    image=$("$jq_command" -r '.image' <<<"$row")
    if declared_image_id=$(run_bounded "$docker_command" image inspect "$image" \
      --format '{{.Id}}' 2>&1) \
      && running_image_id=$(run_bounded "$docker_command" inspect "$container" \
        --format '{{.Image}}' 2>&1) \
      && [[ $declared_image_id == "$running_image_id" ]]; then
      record_pass "container-image/$container"
    else
      record_failure "container-image/$container" "$container is not running the declared image $image"
    fi
  done
fi

# 15. Container restart counters use Docker's monotonic restart count.
container_restart_resources=()
for row in "${container_rows[@]}"; do
  container=$("$jq_command" -r '.container' <<<"$row")
  check_id="restart/container/$container"
  if restart_count=$(run_bounded "$docker_command" inspect "$container" \
    --format '{{.RestartCount}}' 2>/dev/null) \
    && [[ $restart_count =~ ^(0|[1-9][0-9]*)$ ]]; then
    restart_resource=$("$jq_command" -cn --arg container "$container" \
      --argjson count "$restart_count" '{container:$container,count:$count}')
    container_restart_resources+=("$restart_resource")
    if ((restart_count >= restart_failure_count)); then
      record_failure "$check_id" "$container has restarted at least 20 times"
    elif ((restart_count >= restart_warning_count)); then
      record_warning "$check_id" "$container has restarted at least 5 times"
    else
      record_pass "$check_id"
    fi
  else
    record_failure "$check_id" "could not observe restart count for $container"
  fi
done
container_restarts_resource=$(printf '%s\n' "${container_restart_resources[@]}" \
  | "$jq_command" -sc '.')
record_resource containerRestarts "$container_restarts_resource"

# 16. Application health endpoints.
mapfile -t health_rows < <("$jq_command" -c '.[]' <<<"$health_table")
for row in "${health_rows[@]}"; do
  application=$("$jq_command" -r '.application' <<<"$row")
  method=$("$jq_command" -r '.method' <<<"$row")
  timeout=$("$jq_command" -r '.timeout' <<<"$row")
  url=$("$jq_command" -r '.url' <<<"$row")
  if "$curl_command" \
    --silent \
    --show-error \
    --fail-with-body \
    --max-time "$timeout" \
    --request "$method" \
    --output /dev/null \
    "$url"; then
    record_pass "container-health/$application"
  else
    record_failure "container-health/$application" "$method $url failed"
  fi
done

# MCP Streamable HTTP session lifecycle.
mapfile -t mcp_rows < <("$jq_command" -c '.[]' <<<"$mcp_table")
if ((${#mcp_rows[@]} == 0)); then
  record_failure mcp-roster "MCP target roster is empty"
else
  gateway_url=$("$jq_command" -r '.' <<<"$gateway_json")
  gateway_timeout=$("$jq_command" -r '[.[].probe.timeout] | max' <<<"$mcp_table")
  initialize_headers=$doctor_tmp/initialize.headers
  initialize_body=$doctor_tmp/initialize.body
  initialize_json=$doctor_tmp/initialize.json
  initialize_request=$doctor_tmp/initialize-request.json
  notification_request=$doctor_tmp/notification-request.json

  "$jq_command" -cn \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"dotfiles-doctor",version:"1"}}}' \
    >"$initialize_request"

  has_session=0
  has_protocol=0
  session_initialized=0
  if "$curl_command" \
    --silent \
    --show-error \
    --fail-with-body \
    --max-time "$gateway_timeout" \
    --request POST \
    --dump-header "$initialize_headers" \
    --output "$initialize_body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --data-binary "@$initialize_request" \
    "$gateway_url"; then
    session_headers=()
    while IFS= read -r header || [[ -n $header ]]; do
      header=${header%$'\r'}
      header_name=${header%%:*}
      if [[ ${header_name,,} == mcp-session-id ]]; then
        session_value=${header#*:}
        session_value=${session_value#"${session_value%%[![:space:]]*}"}
        session_value=${session_value%"${session_value##*[![:space:]]}"}
        session_headers+=("$session_value")
      fi
    done <"$initialize_headers"

    if ((${#session_headers[@]} == 1)) && [[ -n ${session_headers[0]} ]]; then
      session_id=${session_headers[0]}
      has_session=1
      if decode_response "$initialize_headers" "$initialize_body" 1 "$initialize_json" \
        && "$jq_command" -e \
          '.jsonrpc == "2.0"
           and .id == 1
           and has("result")
           and (has("error") | not)
           and (.result.protocolVersion | type == "string")
           and (.result.protocolVersion | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' \
          "$initialize_json" >/dev/null; then
        protocol_version=$("$jq_command" -r '.result.protocolVersion' "$initialize_json")
        has_protocol=1
        "$jq_command" -cn \
          '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
          >"$notification_request"
        if "$curl_command" \
          --silent \
          --show-error \
          --fail-with-body \
          --max-time "$gateway_timeout" \
          --request POST \
          --output /dev/null \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header "mcp-session-id: $session_id" \
          --header "MCP-Protocol-Version: $protocol_version" \
          --data-binary "@$notification_request" \
          "$gateway_url"; then
          record_pass mcp-session
          session_initialized=1
        else
          record_failure mcp-session "MCP initialized notification failed"
        fi
      else
        record_failure mcp-session "MCP initialize response is invalid"
      fi
    else
      record_failure mcp-session "MCP initialize did not return exactly one session ID"
    fi
  else
    record_failure mcp-session "MCP initialize request failed"
  fi

  if ((session_initialized == 1)); then
    tools_request=$doctor_tmp/tools-list-request.json
    tools_body=$doctor_tmp/tools-list.body
    tools_headers=$doctor_tmp/tools-list.headers
    tools_json=$doctor_tmp/tools-list.json
    "$jq_command" -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' >"$tools_request"

    tools_valid=0
    if "$curl_command" \
      --silent \
      --show-error \
      --fail-with-body \
      --max-time "$gateway_timeout" \
      --request POST \
      --dump-header "$tools_headers" \
      --output "$tools_body" \
      --header 'content-type: application/json' \
      --header 'accept: application/json, text/event-stream' \
      --header "mcp-session-id: $session_id" \
      --header "MCP-Protocol-Version: $protocol_version" \
      --data-binary "@$tools_request" \
      "$gateway_url" \
      && decode_response "$tools_headers" "$tools_body" 2 "$tools_json" \
      && "$jq_command" -e \
        '.jsonrpc == "2.0" and .id == 2 and (.result.tools | type == "array") and (has("error") | not)' \
        "$tools_json" >/dev/null; then
      tools_valid=1
      for row in "${mcp_rows[@]}"; do
        target_id=$("$jq_command" -r '.id' <<<"$row")
        probe_tool=$("$jq_command" -r '.probe.tool' <<<"$row")
        expected_tool="${target_id}_${probe_tool}"
        if ! "$jq_command" -e --arg prefix "${target_id}_" --arg expected "$expected_tool" \
          'any(.result.tools[]; (.name | type == "string") and (.name | startswith($prefix)))
           and any(.result.tools[]; .name == $expected)' \
          "$tools_json" >/dev/null; then
          tools_valid=0
        fi
      done
    fi

    if ((tools_valid == 1)); then
      record_pass mcp-tools
    else
      record_failure mcp-tools "MCP tools/list response does not cover every target probe"
    fi

    call_id=3
    for row in "${mcp_rows[@]}"; do
      target_id=$("$jq_command" -r '.id' <<<"$row")
      target_timeout=$("$jq_command" -r '.probe.timeout' <<<"$row")
      call_request=$doctor_tmp/tools-call-$call_id-request.json
      call_body=$doctor_tmp/tools-call-$call_id.body
      call_headers=$doctor_tmp/tools-call-$call_id.headers
      call_json=$doctor_tmp/tools-call-$call_id.json

      "$jq_command" -c --argjson rpc_id "$call_id" \
        '{jsonrpc:"2.0",id:$rpc_id,method:"tools/call",params:{name:(.id + "_" + .probe.tool),arguments:.probe.args}}' \
        <<<"$row" \
        >"$call_request"

      if "$curl_command" \
        --silent \
        --show-error \
        --fail-with-body \
        --max-time "$target_timeout" \
        --request POST \
        --dump-header "$call_headers" \
        --output "$call_body" \
        --header 'content-type: application/json' \
        --header 'accept: application/json, text/event-stream' \
        --header "mcp-session-id: $session_id" \
        --header "MCP-Protocol-Version: $protocol_version" \
        --data-binary "@$call_request" \
        "$gateway_url" \
        && decode_response "$call_headers" "$call_body" "$call_id" "$call_json" \
        && "$jq_command" -e --argjson rpc_id "$call_id" \
          '.jsonrpc == "2.0"
           and .id == $rpc_id
           and has("result")
           and (has("error") | not)
           and ((.result.isError // false) == false)' \
          "$call_json" >/dev/null; then
        record_pass "mcp-target/$target_id"
      else
        record_failure "mcp-target/$target_id" "MCP tools/call failed or returned a JSON-RPC error"
      fi
      ((call_id += 1))
    done
  fi

  if ((has_session == 1 && has_protocol == 1)); then
    if delete_status=$("$curl_command" \
      --silent \
      --show-error \
      --max-time "$gateway_timeout" \
      --request DELETE \
      --output /dev/null \
      --write-out '%{http_code}' \
      --header "mcp-session-id: $session_id" \
      --header "MCP-Protocol-Version: $protocol_version" \
      "$gateway_url") \
      && [[ $delete_status =~ ^[0-9]{3}$ ]] \
      && { ((delete_status >= 200 && delete_status < 300)) || ((delete_status == 405)); }; then
      :
    else
      record_failure mcp-session "MCP session DELETE failed"
    fi
  fi
fi

report=$(emit_json)
if ((json == 1)); then
  printf '%s\n' "$report"
else
  "$jq_command" -r '.checks[] | "\(.status): \(.id)"' <<<"$report"
  if ((${#warnings[@]} > 0)); then
    "$jq_command" -r '.warnings[] | "  \(.id): \(.message)"' <<<"$report" >&2
  fi
  if ((${#failures[@]} > 0)); then
    "$jq_command" -r '.failures[] | "  \(.id): \(.message)"' <<<"$report" >&2
  fi
fi

if ((${#failures[@]} > 0)); then
  exit 1
fi
exit 0
