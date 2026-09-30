# shellcheck shell=bash

set -euo pipefail

block_devices=@blockDevices@
capacity_outcome=@capacityOutcome@
declared_size_bytes=@sizeBytes@
declared_sparse=@sparse@
envelope_version=@envelopeVersion@
jq_command=@jqCommand@
powershell_command=@powershellCommand@
powershell_probe=@powershellProbe@
probe_timeout_seconds=@timeoutSeconds@
stat_command=@statCommand@
timeout_command=@timeoutCommand@
wslconfig_outcome=@wslconfigOutcome@

outcomes=()
declare -A wslconfig=()

add_outcome() {
  outcomes+=("$("$jq_command" -cn --arg id "$1" --arg status "$2" --arg message "$3" \
    '{id:$id,status:$status,message:$message}')")
}

# sysfs の size は device の論理 sector 長によらず 512 byte 単位で数える
root_disk_bytes() {
  local device size_file sectors
  device=$("$stat_command" --format=%Hd:%Ld / 2>/dev/null) || return 1
  [[ $device =~ ^[0-9]+:[0-9]+$ ]] || return 1
  size_file=$block_devices/$device/size
  [[ -f $size_file && -r $size_file ]] || return 1
  sectors=$(<"$size_file")
  [[ $sectors =~ ^(0|[1-9][0-9]{0,15})$ ]] || return 1
  printf '%s\n' "$((sectors * 512))"
}

# WSL と同じく section と key の大文字小文字を区別せず、同じ key は最初の値を採る。
# 値は `#` からの comment と引用符を除き、行末の空白を詰める
parse_wslconfig() {
  local line name value section=
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:blank:]]*}"}
    if [[ $line =~ ^\[([A-Za-z][A-Za-z0-9]*)\][[:blank:]]*(#.*)?$ ]]; then
      section=${BASH_REMATCH[1],,}
    elif [[ $line == \[* ]]; then
      section=
    elif [[ -n $section && $line =~ ^([A-Za-z][A-Za-z0-9]*)[[:blank:]]*=[[:blank:]]*([^#]*) ]]; then
      name=$section.${BASH_REMATCH[1],,}
      value=${BASH_REMATCH[2]//\"/}
      value=${value%"${value##*[![:blank:]]}"}
      [[ -v wslconfig[$name] ]] || wslconfig[$name]=$value
    fi
  done
}

# WSL の size 表記は 10 進数に B、K、KB、M、MB、G、GB、T、TB を付け、単位は 1024 倍ずつ上がる
size_matches_declaration() {
  local number factor
  [[ $1 =~ ^([0-9]{1,18})(B|K|KB|M|MB|G|GB|T|TB)?$ ]] || return 1
  number=$((10#${BASH_REMATCH[1]}))
  case ${BASH_REMATCH[2]} in
    K | KB) factor=1024 ;;
    M | MB) factor=1048576 ;;
    G | GB) factor=1073741824 ;;
    T | TB) factor=1099511627776 ;;
    *) factor=1 ;;
  esac
  ((declared_size_bytes % factor == 0 && number == declared_size_bytes / factor))
}

# WSL の真偽値は 1、0 と、大文字小文字を区別しない true、false だけを受理する
boolean_value() {
  case ${1,,} in
    1 | true) printf 'true\n' ;;
    0 | false) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

if ! observed_bytes=$(root_disk_bytes); then
  add_outcome "$capacity_outcome" fail "could not observe the root disk capacity"
elif ((observed_bytes != declared_size_bytes)); then
  add_outcome "$capacity_outcome" fail "root disk capacity differs from the declared VHD size"
else
  add_outcome "$capacity_outcome" pass "root disk capacity matches the declared VHD size"
fi

if content=$(
  "$timeout_command" --signal=TERM --kill-after=2s "${probe_timeout_seconds}s" \
    "$powershell_command" -NoLogo -NoProfile -NonInteractive -Command "$powershell_probe" 2>/dev/null
); then
  parse_wslconfig <<<"$content"
  missing=()
  size_matches_declaration "${wslconfig[wsl2.defaultvhdsize]-}" || missing+=(wsl2.defaultVhdSize)
  if ! sparse=$(boolean_value "${wslconfig[experimental.sparsevhd]-}") \
    || [[ $sparse != "$declared_sparse" ]]; then
    missing+=(experimental.sparseVhd)
  fi
  if ((${#missing[@]} == 0)); then
    add_outcome "$wslconfig_outcome" pass "Windows .wslconfig declares the VHD size and sparse setting"
  else
    add_outcome "$wslconfig_outcome" fail "Windows .wslconfig lacks the declared ${missing[*]}"
  fi
else
  add_outcome "$wslconfig_outcome" fail "could not read the Windows .wslconfig"
fi

printf '%s\n' "${outcomes[@]}" \
  | "$jq_command" -cs --argjson version "$envelope_version" \
    '{schemaVersion:$version,outcomes:.,resources:[]}'
