# shellcheck shell=bash

set -euo pipefail

observation_file=$1
scratch_root=$2

cmp_command=@cmpCommand@
curl_command=@curlCommand@
df_command=@dfCommand@
docker_command=@dockerCommand@
find_command=@findCommand@
head_command=@headCommand@
journalctl_command=@journalctlCommand@
jq_command=@jqCommand@
proc_root=@procRoot@
readlink_command=@readlinkCommand@
stat_command=@statCommand@
swapon_command=@swaponCommand@
systemctl_command=@systemctlCommand@
wc_command=@wcCommand@
zramctl_command=@zramctlCommand@

observation=$($jq_command -c '.value' "$observation_file")
kind=$($jq_command -r '.kind' <<<"$observation")
check_id=$($jq_command -r '.checkId' <<<"$observation")
failure_message=$($jq_command -r '.failureMessage' <<<"$observation")
resource_key=$($jq_command -r '.resourceKey // empty' <<<"$observation")

resource_array() {
  local value=${1-null}
  if [[ -n $resource_key && $value != null ]]; then
    $jq_command -cn --arg key "$resource_key" --argjson value "$value" '[{key:$key,value:$value}]'
  else
    printf '[]\n'
  fi
}

emit_direct() {
  local status=$1
  local message=${2-}
  local resources=${3:-[]}
  local restart=${4-null}
  $jq_command -cn \
    --arg id "$check_id" \
    --arg status "$status" \
    --arg message "$message" \
    --argjson resources "$resources" \
    --argjson restart "$restart" '
      {
        checks: (if $status == "omit" then [] else [{id:$id,status:$status}] end),
        warnings: (if $status == "warn" then [{id:$id,message:$message}] else [] end),
        failures: (if $status == "fail" then [{id:$id,message:$message}] else [] end),
        resources: $resources,
        restart: $restart
      }
    '
}

emit_pass() {
  emit_direct pass "" "${1:-[]}" "${2:-null}"
}

emit_failure() {
  emit_direct fail "$failure_message" "${1:-[]}"
}

value_is_allowed() {
  local field=$1
  local value=$2
  $jq_command -e --arg field "$field" --arg value "$value" '.[$field] | index($value) != null' \
    >/dev/null <<<"$observation"
}

capture_bounded() {
  local limit=$1
  shift
  capture_file=$scratch_root/capture
  set +e
  "$@" 2>/dev/null | "$head_command" -c "$((limit + 1))" >"$capture_file"
  capture_statuses=("${PIPESTATUS[@]}")
  set -e
  capture_size=$($wc_command -c <"$capture_file")
  [[ $capture_size =~ ^[0-9]+$ ]] || return 1
  ((capture_size <= limit)) || return 1
  ((capture_statuses[0] == 0 && capture_statuses[1] == 0))
}

probe_roster() {
  local member_count minimum_count failure_only
  member_count=$($jq_command '.members | length' <<<"$observation")
  minimum_count=$($jq_command '.minimumCount' <<<"$observation")
  failure_only=$($jq_command -r '.failureOnly' <<<"$observation")
  if ((member_count < minimum_count)); then
    emit_failure
  elif [[ $failure_only == true ]]; then
    emit_direct omit
  else
    emit_pass
  fi
}

probe_path_match() {
  local current required resolution current_value required_value
  current=$($jq_command -r '.currentPath' <<<"$observation")
  required=$($jq_command -r '.requiredPath' <<<"$observation")
  resolution=$($jq_command -r '.resolution' <<<"$observation")
  if [[ $resolution == canonical ]]; then
    if current_value=$($readlink_command -f -- "$current" 2>/dev/null) \
      && required_value=$($readlink_command -f -- "$required" 2>/dev/null) \
      && [[ -n $current_value && $current_value == "$required_value" ]]; then
      emit_pass
    else
      emit_failure
    fi
  elif [[ $current == "$required" ]]; then
    emit_pass
  else
    emit_failure
  fi
}

probe_command_version() {
  local path expected path_source expected_source
  local -a version_args=()
  path=$($jq_command -r '.path' <<<"$observation")
  expected=$($jq_command -r '.expectedSource' <<<"$observation")
  mapfile -t version_args < <($jq_command -r '.versionArgs[]' <<<"$observation")
  if [[ -x $path ]] \
    && path_source=$($readlink_command -f -- "$path" 2>/dev/null) \
    && expected_source=$($readlink_command -f -- "$expected" 2>/dev/null) \
    && [[ -n $path_source && $path_source == "$expected_source" ]] \
    && "$path" "${version_args[@]}" >/dev/null 2>&1; then
    emit_pass
  else
    emit_failure
  fi
}

probe_deployed_path() {
  local source destination destination_kind resolved
  source=$($jq_command -r '.source' <<<"$observation")
  destination=$($jq_command -r '.destination' <<<"$observation")
  if [[ -L $destination ]]; then
    destination_kind=symlink
    if value_is_allowed acceptedDestinationKinds "$destination_kind" \
      && resolved=$($readlink_command -f -- "$destination" 2>/dev/null) \
      && [[ $resolved == "$source" ]]; then
      emit_pass
    else
      emit_failure
    fi
  elif [[ -f $destination ]]; then
    destination_kind=regular-file
    if value_is_allowed acceptedDestinationKinds "$destination_kind" \
      && $cmp_command --silent -- "$source" "$destination" 2>/dev/null; then
      emit_pass
    else
      emit_failure
    fi
  else
    emit_failure
  fi
}

probe_path_metadata() {
  local path owner group mode expected actual
  path=$($jq_command -r '.path' <<<"$observation")
  owner=$($jq_command -r '.owner' <<<"$observation")
  group=$($jq_command -r '.group' <<<"$observation")
  mode=$($jq_command -r '.mode' <<<"$observation")
  expected=$owner:$group:${mode#0}
  if actual=$($stat_command --format=%U:%G:%a -- "$path" 2>/dev/null) \
    && [[ $actual == "$expected" ]]; then
    emit_pass
  else
    emit_failure
  fi
}

cgroup_path() {
  local line
  while IFS= read -r line; do
    if [[ $line == 0::* ]]; then
      printf '%s\n' "${line#0::}"
      return 0
    fi
  done <"$1"
  return 1
}

# environ を読むと swap に出た process の page を読み戻すため実行 file の link 先以外による agent の判別は不可
probe_process_slice() {
  local slice listing process target root path inside=0 outside=0 resource_value resources
  local -a roots=()
  slice=$($jq_command -r '.slice' <<<"$observation")
  mapfile -t roots < <($jq_command -r '.executableRoots[]' <<<"$observation")
  listing=$($find_command "$proc_root"/[0-9]*/exe -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null) || true
  if [[ -z $listing ]]; then
    emit_failure
    return
  fi
  while IFS=$'\t' read -r process target; do
    [[ -n $target ]] || continue
    for root in "${roots[@]}"; do
      # root は glob pattern として扱う。native profile の実体は /nix/store の名前でしか識別できない
      # shellcheck disable=SC2053
      [[ $target == $root/* ]] || continue
      if path=$(cgroup_path "$process/cgroup" 2>/dev/null); then
        if [[ $path/ == */"$slice"/* ]]; then
          inside=$((inside + 1))
        else
          outside=$((outside + 1))
        fi
      fi
      break
    done
  done <<<"$listing"
  resource_value=$($jq_command -cn --argjson inside "$inside" --argjson outside "$outside" \
    '{inside:$inside,outside:$outside}')
  resources=$(resource_array "$resource_value")
  if ((outside == 0)); then emit_pass "$resources"; else emit_failure "$resources"; fi
}

# 指定した manager の unit が持つ systemctl show の出力の取得
#   $1: 問い合わせ先 manager の system と user の別
#   $2: 問い合わせる unit 名
#   $3 以降: systemctl show へそのまま渡す追加の引数
#   出力: systemctl show の標準出力
#   標準エラー: 破棄
#   終了: 不正な manager での systemctl 未実行の 1
#   終了: 他の場合の systemctl の終了 status
systemd_record() {
  local manager=$1 unit=$2
  shift 2
  # 同名の system unit への fallback は不可のため manager の明示指定
  case "$manager" in
    system | user) ;;
    *) return 1 ;;
  esac
  $systemctl_command "--$manager" show "$unit" "$@" 2>/dev/null
}

# unit の単一 property の値の取得
#   $1: 問い合わせ先 manager の system と user の別
#   $2: 問い合わせる unit 名
#   $3: 取得する property 名
#   出力: Key= を除いた property の値
#   終了: systemd_record と同一
systemd_show() {
  systemd_record "$1" "$2" --property="$3" --value
}

probe_systemd_unit() {
  local manager unit load active result
  manager=$($jq_command -r '.manager' <<<"$observation")
  unit=$($jq_command -r '.unit' <<<"$observation")
  if load=$(systemd_show "$manager" "$unit" LoadState) \
    && active=$(systemd_show "$manager" "$unit" ActiveState) \
    && result=$(systemd_show "$manager" "$unit" Result) \
    && value_is_allowed loadStates "$load" \
    && value_is_allowed activeStates "$active" \
    && value_is_allowed results "$result"; then
    emit_pass
  else
    emit_failure
  fi
}

# systemd の timer と対象 service の最後の実行結果の判定
#   前提: $observation が systemd-timer の observation
#   出力: 判定結果の JSON 一件
#   正常な timer: LoadState が loaded で UnitFileState と ActiveState の少なくとも一方が許可内
#   失敗の記録: service の LoadState と ExecMainStatus と Result の許可外の値
#   完了状態: service の ActiveState と SubState の組の inactive/dead と active/exited
#   完了待ちの状態: service の activating・reloading・deactivating・refreshing の各 ActiveState と active/running の組
#   判定 pass: 正常な timer と完了状態で失敗の記録なしの service
#   判定 warn: 正常な timer と完了待ちの状態で失敗の記録なしの service
#   判定 fail: pass と warn に該当しない全て
#   不変条件: service の状態は一回の systemctl show の snapshot
probe_systemd_timer() {
  local manager timer service timer_load unit_file active snapshot property value
  local service_load='' result='' exit_status='' service_active='' service_sub=''
  manager=$($jq_command -r '.manager' <<<"$observation")
  timer=$($jq_command -r '.timer' <<<"$observation")
  service=$($jq_command -r '.service' <<<"$observation")
  if ! { timer_load=$(systemd_show "$manager" "$timer" LoadState) \
    && unit_file=$(systemd_show "$manager" "$timer" UnitFileState) \
    && active=$(systemd_show "$manager" "$timer" ActiveState) \
    && snapshot=$(systemd_record "$manager" "$service" \
      --property=LoadState,ActiveState,SubState,Result,ExecMainStatus) \
    && [[ $timer_load == loaded ]] \
    && { value_is_allowed unitFileStates "$unit_file" || value_is_allowed activeStates "$active"; }; }; then
    emit_failure
    return
  fi
  while IFS='=' read -r property value; do
    case "$property" in
      LoadState) service_load=$value ;;
      ActiveState) service_active=$value ;;
      SubState) service_sub=$value ;;
      Result) result=$value ;;
      ExecMainStatus) exit_status=$value ;;
    esac
  done <<<"$snapshot"
  # reset-failed が Result だけを消すため Result 単独での成否判定は不可
  if [[ $service_load != loaded || $exit_status != 0 ]] \
    || ! value_is_allowed serviceResults "$result"; then
    emit_failure
    return
  fi
  case "$service_active:$service_sub" in
    inactive:dead | active:exited) emit_pass ;;
    activating:* | reloading:* | deactivating:* | refreshing:* | active:running)
      emit_direct warn "$service is $service_active/$service_sub; completion not yet observed"
      ;;
    *) emit_failure ;;
  esac
}

probe_restart_counter() {
  local source_kind manager target warning failure count restart status message
  source_kind=$($jq_command -r '.sourceKind' <<<"$observation")
  manager=$($jq_command -r '.manager' <<<"$observation")
  target=$($jq_command -r '.target' <<<"$observation")
  warning=$($jq_command '.warningAt' <<<"$observation")
  failure=$($jq_command '.failureAt' <<<"$observation")
  if [[ $source_kind == systemd-service ]]; then
    count=$(systemd_show "$manager" "$target" NRestarts) || {
      emit_failure
      return
    }
    restart=$($jq_command -cn --arg kind service --arg target "$target" --argjson count "$count" \
      '{kind:$kind,target:$target,count:$count}')
  else
    count=$($docker_command inspect "$target" --format '{{.RestartCount}}' 2>/dev/null) || {
      emit_failure
      return
    }
    restart=$($jq_command -cn --arg kind container --arg target "$target" --argjson count "$count" \
      '{kind:$kind,target:$target,count:$count}')
  fi
  if [[ ! $count =~ ^(0|[1-9][0-9]*)$ ]]; then
    emit_failure
  elif ((count >= failure)); then
    message="$target reached the restart failure threshold"
    emit_direct fail "$message" '[]' "$restart"
  elif ((count >= warning)); then
    message="$target reached the restart warning threshold"
    emit_direct warn "$message" '[]' "$restart"
  else
    emit_pass '[]' "$restart"
  fi
}

threshold_status() {
  local value=$1 metric=$2 warning=$3 failure=$4
  if [[ $metric == used-percent ]]; then
    if ((value >= failure)); then printf 'fail\n'
    elif ((value >= warning)); then printf 'warn\n'
    else printf 'pass\n'
    fi
  else
    if ((value < failure)); then printf 'fail\n'
    elif ((value < warning)); then printf 'warn\n'
    else printf 'pass\n'
    fi
  fi
}

emit_threshold() {
  local value=$1 metric=$2 warning=$3 failure=$4 resources=$5 status message
  status=$(threshold_status "$value" "$metric" "$warning" "$failure")
  message="$metric crossed its $status threshold"
  if [[ $status == fail ]]; then
    emit_direct fail "$message" "$resources"
  elif [[ $status == warn ]]; then
    emit_direct warn "$message" "$resources"
  else
    emit_pass "$resources"
  fi
}

probe_filesystem_threshold() {
  local path metric warning failure output used_value value resource_value resources
  path=$($jq_command -r '.path' <<<"$observation")
  metric=$($jq_command -r '.metric' <<<"$observation")
  warning=$($jq_command '.warning' <<<"$observation")
  failure=$($jq_command '.failure' <<<"$observation")
  if output=$($df_command --output=pcent -- "$path" 2>/dev/null); then
    used_value=${output##*$'\n'}
    used_value=${used_value//[[:space:]]/}
    used_value=${used_value%%%}
  else
    used_value=
  fi
  if [[ ! $used_value =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((used_value > 100)); then
    emit_failure
    return
  fi
  if [[ $metric == used-percent ]]; then
    value=$used_value
    resource_value=$($jq_command -cn --argjson value "$value" '{usedPercent:$value}')
  else
    value=$((100 - used_value))
    resource_value=$($jq_command -cn --argjson value "$value" '{freePercent:$value}')
  fi
  resources=$(resource_array "$resource_value")
  emit_threshold "$value" "$metric" "$warning" "$failure" "$resources"
}

probe_numeric_command_threshold() {
  local command metric warning failure value resource_value resources
  command=$($jq_command -r '.command' <<<"$observation")
  metric=$($jq_command -r '.metric' <<<"$observation")
  warning=$($jq_command '.warning' <<<"$observation")
  failure=$($jq_command '.failure' <<<"$observation")
  if ! capture_bounded 64 "$command"; then
    emit_failure
    return
  fi
  if ! value=$($jq_command -Rser '
    if test("^(0|[1-9][0-9]{0,2})(\\r?\\n)?$")
      then sub("\\r?\\n$"; "") | tonumber
      else empty
    end
  ' "$capture_file" 2>/dev/null) || ((value > 100)); then
    emit_failure
    return
  fi
  if [[ $metric == used-percent ]]; then
    resource_value=$($jq_command -cn --argjson value "$value" '{usedPercent:$value}')
  else
    resource_value=$($jq_command -cn --argjson value "$value" '{freePercent:$value}')
  fi
  resources=$(resource_array "$resource_value")
  emit_threshold "$value" "$metric" "$warning" "$failure" "$resources"
}

probe_numeric_command_threshold_set() {
  local command metric warning failure measurements name value status
  local items=()
  command=$($jq_command -r '.command' <<<"$observation")
  metric=$($jq_command -r '.metric' <<<"$observation")
  warning=$($jq_command '.warning' <<<"$observation")
  failure=$($jq_command '.failure' <<<"$observation")
  if ! capture_bounded 4096 "$command"; then
    emit_failure
    return
  fi
  # 名前は check ID の最後の一節になる。一つでも読めない行があれば、どの値も信用しない
  if ! measurements=$($jq_command -Rser '
    (sub("\n$"; "") | split("\n")) as $lines
    | if ($lines | length) > 0
        and all($lines[]; test("^[a-z0-9][a-z0-9-]{0,31} (0|[1-9][0-9]{0,2})$"))
        and all($lines[]; (split(" ")[1] | tonumber) <= 100)
      then $lines | sort | join("\n")
      else error("invalid measurements")
      end
  ' "$capture_file" 2>/dev/null); then
    emit_failure
    return
  fi
  while read -r name value; do
    status=$(threshold_status "$value" "$metric" "$warning" "$failure")
    items+=("$($jq_command -cn --arg name "$name" --argjson value "$value" --arg status "$status" \
      '{name:$name,value:$value,status:$status}')")
  done <<<"$measurements"
  printf '%s\n' "${items[@]}" | $jq_command -sc \
    --arg id "$check_id" \
    --arg metric "$metric" \
    --arg key "$resource_key" '
      map(. + {id: ($id + "/" + .name)}) as $items
      | {
          checks: [$items[] | {id, status}],
          warnings: [$items[] | select(.status == "warn") | {id, message: "\($metric) crossed its warn threshold"}],
          failures: [$items[] | select(.status == "fail") | {id, message: "\($metric) crossed its fail threshold"}],
          resources: (
            if $key == "" then []
            else [{
              key: $key,
              value: [$items[] | {name} + (if $metric == "used-percent" then {usedPercent: .value} else {freePercent: .value} end)]
            }]
            end
          ),
          restart: null
        }
    '
}

zram_device_identity() {
  local path=$1
  if [[ $path =~ ^/dev/zram([0-9]+)$ ]]; then
    printf 'zram%s\n' "${BASH_REMATCH[1]}"
  elif [[ $path =~ ^/zram([0-9]+)$ ]]; then
    printf 'zram%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

probe_swap_policy() {
  local minimum algorithm require_zram zram_above output name swap_type size priority extra
  local identity observed_algorithm
  local valid=1 total=0 zram_count=0 disk_count=0 min_zram_priority=0 max_disk_priority=0
  local -A algorithms_by_device=()
  local -a algorithms=()
  minimum=$($jq_command '.minimumTotalBytes' <<<"$observation")
  algorithm=$($jq_command -r '.requiredZramAlgorithm' <<<"$observation")
  require_zram=$($jq_command -r '.requireZram' <<<"$observation")
  zram_above=$($jq_command -r '.zramAboveDisk' <<<"$observation")
  if output=$($zramctl_command --noheadings --raw --output NAME,ALGORITHM 2>/dev/null); then
    while read -r name observed_algorithm extra; do
      [[ -n $name ]] || continue
      if [[ -n ${extra-} || -z $observed_algorithm ]] \
        || ! identity=$(zram_device_identity "$name"); then
        valid=0
        break
      fi
      algorithms_by_device[$identity]=$observed_algorithm
    done <<<"$output"
  else
    valid=0
  fi
  if output=$($swapon_command --show=NAME,TYPE,SIZE,PRIO --bytes --noheadings --raw 2>/dev/null); then
    while read -r name swap_type size priority extra; do
      [[ -n $name ]] || continue
      if [[ -n ${extra-} || -z $swap_type || ! $size =~ ^(0|[1-9][0-9]*)$ || ! $priority =~ ^-?[0-9]+$ ]]; then
        valid=0
        break
      fi
      total=$((total + size))
      if identity=$(zram_device_identity "$name"); then
        ((zram_count += 1))
        if ((zram_count == 1 || priority < min_zram_priority)); then min_zram_priority=$priority; fi
        observed_algorithm=${algorithms_by_device[$identity]-}
        [[ $observed_algorithm == "$algorithm" ]] || valid=0
        [[ -z $observed_algorithm ]] || algorithms+=("$observed_algorithm")
      else
        ((disk_count += 1))
        if ((disk_count == 1 || priority > max_disk_priority)); then max_disk_priority=$priority; fi
      fi
    done <<<"$output"
  else
    valid=0
  fi
  [[ $require_zram == false || $zram_count -gt 0 ]] || valid=0
  [[ $zram_above == false || $disk_count -eq 0 || $min_zram_priority -gt $max_disk_priority ]] || valid=0
  ((total >= minimum)) || valid=0
  algorithms_json=$(printf '%s\n' "${algorithms[@]}" | $jq_command -Rsc 'split("\n") | map(select(length > 0)) | unique')
  resource_value=$($jq_command -cn \
    --argjson total "$total" --argjson zram "$zram_count" --argjson disk "$disk_count" \
    --argjson min "$min_zram_priority" --argjson max "$max_disk_priority" \
    --argjson algorithms "$algorithms_json" \
    '{totalBytes:$total,zramDevices:$zram,diskDevices:$disk,minZramPriority:$min,maxDiskPriority:$max,algorithms:$algorithms}')
  resources=$(resource_array "$resource_value")
  if ((valid == 1)); then emit_pass "$resources"; else emit_failure "$resources"; fi
}

probe_journal_size() {
  local maximum output amount unit bytes resource_value resources
  maximum=$($jq_command '.maximumBytes' <<<"$observation")
  if output=$(LC_ALL=C $journalctl_command --disk-usage 2>/dev/null) \
    && [[ $output =~ take[[:space:]]+up[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]*([KMGTPE]?)(i?B)?[[:space:]]+in ]]; then
    amount=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[3]}
    bytes=$($jq_command -nr --arg amount "$amount" --arg unit "$unit" '
      {"":1,K:1024,M:1048576,G:1073741824,T:1099511627776,
       P:1125899906842624,E:1152921504606846976} as $powers
      | (($amount | tonumber) * $powers[$unit] | floor)
    ')
  else
    emit_failure
    return
  fi
  resource_value=$($jq_command -cn --argjson bytes "$bytes" '{bytes:$bytes}')
  resources=$(resource_array "$resource_value")
  if ((bytes > maximum)); then emit_direct fail "$failure_message" "$resources"; else emit_pass "$resources"; fi
}

probe_container_image() {
  local container image declared running
  container=$($jq_command -r '.container' <<<"$observation")
  image=$($jq_command -r '.image' <<<"$observation")
  if declared=$($docker_command image inspect "$image" --format '{{.Id}}' 2>/dev/null) \
    && running=$($docker_command inspect "$container" --format '{{.Image}}' 2>/dev/null) \
    && [[ -n $declared && $declared == "$running" ]]; then
    emit_pass
  else
    emit_failure
  fi
}

probe_http_health() {
  local method url
  method=$($jq_command -r '.method' <<<"$observation")
  url=$($jq_command -r '.url' <<<"$observation")
  if $curl_command --silent --show-error --fail-with-body --request "$method" --output /dev/null "$url" \
    >/dev/null 2>&1; then
    emit_pass
  else
    emit_failure
  fi
}

probe_normalized_protocol() {
  local command version allowed required_outcomes required_resources normalized
  command=$($jq_command -r '.command' <<<"$observation")
  version=$($jq_command '.envelopeVersion' <<<"$observation")
  allowed=$($jq_command -c '.allowedOutcomeIds' <<<"$observation")
  required_outcomes=$($jq_command -c '.requiredOutcomeIds' <<<"$observation")
  required_resources=$($jq_command -c '.requiredResourceKeys | sort' <<<"$observation")
  if ! capture_bounded 65536 "$command"; then
    emit_failure
    return
  fi
  normalized=$scratch_root/normalized
  if ! $jq_command -cse \
    --argjson version "$version" \
    --argjson allowed "$allowed" \
    --argjson required_outcomes "$required_outcomes" \
    --argjson required_resources "$required_resources" '
      if length == 1
        and (.[0] | type) == "object"
        and (.[0] | keys | sort) == ["outcomes","resources","schemaVersion"]
        and .[0].schemaVersion == $version
        and (.[0].outcomes | type) == "array"
        and all(.[0].outcomes[];
          type == "object"
          and (keys | sort) == ["id","message","status"]
          and (.id | type) == "string"
          and (.id as $id | ($allowed | index($id)) != null)
          and (.status == "pass" or .status == "warn" or .status == "fail")
          and (.message | type) == "string"
          and (.message | length) > 0)
        and (
          (.[0].outcomes | map(.id)) as $actual_outcome_ids
          | ($actual_outcome_ids | length) == ($actual_outcome_ids | unique | length)
          and all($required_outcomes[];
            . as $required_id | ($actual_outcome_ids | index($required_id)) != null)
        )
        and (.[0].resources | type) == "array"
        and all(.[0].resources[];
          type == "object"
          and (keys | sort) == ["key","value"]
          and (.key | type) == "string"
          and (.key as $key | ($required_resources | index($key)) != null))
        and ((.[0].resources | map(.key)) | length) == ((.[0].resources | map(.key) | unique) | length)
        and (.[0].resources | map(.key) | sort) == $required_resources
      then .[0]
      else empty
      end
    ' "$capture_file" >"$normalized" 2>/dev/null; then
    emit_failure
    return
  fi
  $jq_command -c '
    {
      checks: [.outcomes[] | {id,status}],
      warnings: [.outcomes[] | select(.status == "warn") | {id,message}],
      failures: [.outcomes[] | select(.status == "fail") | {id,message}],
      resources: .resources,
      restart: null
    }
  ' "$normalized"
}

case "$kind" in
  roster) probe_roster ;;
  path-match) probe_path_match ;;
  command-version) probe_command_version ;;
  deployed-path) probe_deployed_path ;;
  path-metadata) probe_path_metadata ;;
  process-slice) probe_process_slice ;;
  systemd-service) probe_systemd_unit ;;
  systemd-socket) probe_systemd_unit ;;
  systemd-timer) probe_systemd_timer ;;
  restart-counter) probe_restart_counter ;;
  filesystem-threshold) probe_filesystem_threshold ;;
  numeric-command-threshold) probe_numeric_command_threshold ;;
  numeric-command-threshold-set) probe_numeric_command_threshold_set ;;
  swap-policy) probe_swap_policy ;;
  journal-size) probe_journal_size ;;
  container-image) probe_container_image ;;
  http-health) probe_http_health ;;
  normalized-protocol) probe_normalized_protocol ;;
  *) exit 64 ;;
esac
