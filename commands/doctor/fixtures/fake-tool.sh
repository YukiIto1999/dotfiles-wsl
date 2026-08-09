#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

fixture=${DOTFILES_DOCTOR_FIXTURE:?DOTFILES_DOCTOR_FIXTURE is required}
tables=${DOTFILES_DOCTOR_TABLES:?DOTFILES_DOCTOR_TABLES is required}
command_name=${0##*/}

missing() {
  printf 'fixture does not define %s\n' "$*" >&2
  exit 64
}

fixture_value() {
  local filter=$1
  shift
  jq -er "$@" "$filter // empty" "$fixture" 2>/dev/null || missing "$command_name $*"
}

run_systemctl() {
  [[ $# == 4 && $1 == show && $3 == --property=* && $4 == --value ]] || missing "$*"
  local unit=$2
  local property=${3#--property=}
  jq -e --arg unit "$unit" '
    any(.serviceTable[]; .unit == $unit)
    or any(.maintenanceTable[]; .timer == $unit or .service == $unit)
  ' <<<"$tables" >/dev/null \
    || missing "$*"
  [[ $property == LoadState || $property == ActiveState || $property == Result \
    || $property == UnitFileState || $property == NRestarts ]] \
    || missing "$*"
  fixture_value '.systemd[$unit][$property]' --arg unit "$unit" --arg property "$property"
}

run_readlink() {
  [[ $# == 2 && $1 == -f ]] || missing "$*"
  case "$2" in
    /run/current-system) fixture_value '.system.current' ;;
    /nix/var/nix/profiles/system) fixture_value '.system.profile' ;;
    *) missing "$*" ;;
  esac
}

run_stat() {
  local path
  if [[ $# == 3 && $1 == --format && $2 == %U:%G:%a ]]; then
    path=$3
    jq -e --arg path "$path" 'any(.secretTable[]; .path == $path)' <<<"$tables" >/dev/null \
      || missing "$*"
    fixture_value '.secrets[$path].metadata' --arg path "$path"
  elif [[ $# == 2 && $1 == --format=%U:%G:%a ]]; then
    path=$2
    jq -e --arg path "$path" 'any(.secretTable[]; .path == $path)' <<<"$tables" >/dev/null \
      || missing "$*"
    fixture_value '.secrets[$path].metadata' --arg path "$path"
  elif [[ $# == 2 && $1 == --format=%F ]]; then
    path=$2
    jq -e --arg path "$path" 'any(.managedRootTable[]; . == $path)' <<<"$tables" >/dev/null \
      || missing "$*"
    local kind
    kind=$(fixture_value '.resources.managedRoots[$path].kind' --arg path "$path")
    [[ $kind != missing ]] || exit 1
    printf '%s\n' "$kind"
  else
    missing "$*"
  fi
}

run_cmp() {
  [[ $# == 3 && $1 == --silent ]] || missing "$*"
  local source=$2
  local destination=$3
  local id
  id=$(jq -er --arg source "$source" --arg destination "$destination" \
    '.artifactTable[] | select(.source == $source and .destination == $destination) | .id' \
    <<<"$tables") \
    || missing "$*"
  jq -e --arg id "$id" '.artifacts[$id] | has("equal")' "$fixture" >/dev/null \
    || missing "$*"
  jq -e --arg id "$id" '.artifacts[$id].equal == true' "$fixture" >/dev/null
}

run_docker() {
  if [[ $# == 5 && $1 == image && $2 == inspect && $4 == --format && $5 == '{{.Id}}' ]]; then
    jq -e --arg image "$3" 'any(.containerTable[]; .image == $image)' <<<"$tables" >/dev/null \
      || missing "$*"
    fixture_value '.docker.images[$image].imageId' --arg image "$3"
  elif [[ $# == 4 && $1 == inspect && $3 == --format && $4 == '{{.Image}}' ]]; then
    jq -e --arg container "$2" 'any(.containerTable[]; .container == $container)' \
      <<<"$tables" >/dev/null \
      || missing "$*"
    fixture_value '.docker.containers[$container].imageId' --arg container "$2"
  elif [[ $# == 4 && $1 == inspect && $3 == --format && $4 == '{{.RestartCount}}' ]]; then
    jq -e --arg container "$2" 'any(.containerTable[]; .container == $container)' \
      <<<"$tables" >/dev/null \
      || missing "$*"
    fixture_value '.docker.containers[$container].restartCount' --arg container "$2"
  else
    missing "$*"
  fi
}

run_swapon() {
  [[ $# == 4 && $1 == --show=NAME,TYPE,SIZE,PRIO && $2 == --bytes \
    && $3 == --noheadings && $4 == --raw ]] || missing "$*"
  jq -r '.resources.swap.entries[] | [.name, .type, .size, .priority] | @tsv' "$fixture"
}

run_zramctl() {
  [[ $# == 4 && $1 == --noheadings && $2 == --raw && $3 == --output \
    && $4 == NAME,ALGORITHM ]] || missing "$*"
  jq -r '.resources.swap.zram[] | [.name, .algorithm] | @tsv' "$fixture"
}

run_df() {
  [[ $# == 2 && $1 == --output=pcent && $2 == / ]] || missing "$*"
  printf 'Use%%\n%s%%\n' "$(fixture_value '.resources.rootFilesystem.usedPercent')"
}

run_powershell() {
  [[ $# == 5 && $1 == -NoLogo && $2 == -NoProfile && $3 == -NonInteractive \
    && $4 == -Command ]] || missing "$*"
  local expected status
  expected="\$drive = Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='D:'\"; if (\$null -eq \$drive -or \$drive.Size -le 0) { exit 1 }; [Console]::WriteLine([math]::Floor((\$drive.FreeSpace * 100) / \$drive.Size))"
  [[ $5 == "$expected" ]] || missing "$*"
  status=$(fixture_value '.resources.windowsDDrive.exit')
  ((status == 0)) || exit "$status"
  fixture_value '.resources.windowsDDrive.freePercent'
}

run_journalctl() {
  [[ $# == 1 && $1 == --disk-usage ]] || missing "$*"
  local status
  status=$(fixture_value '.resources.journald.exit')
  ((status == 0)) || exit "$status"
  fixture_value '.resources.journald.output'
}

run_du() {
  [[ $# == 5 && $1 == --summarize && $2 == --bytes && $3 == --one-file-system \
    && $4 == -- ]] || missing "$*"
  local root=$5 status
  jq -e --arg root "$root" 'any(.managedRootTable[]; . == $root)' <<<"$tables" >/dev/null \
    || missing "$*"
  status=$(fixture_value '.resources.managedRoots[$root].exit' --arg root "$root")
  ((status == 0)) || exit "$status"
  printf '%s\t%s\n' \
    "$(fixture_value '.resources.managedRoots[$root].bytes' --arg root "$root")" "$root"
}

write_response() {
  local body=$1
  local output=$2
  if [[ -z $output ]]; then
    printf '%s\n' "$body"
  elif [[ $output != /dev/null ]]; then
    printf '%s\n' "$body" >"$output"
  fi
}

write_headers() {
  local headers=$1
  local destination=$2
  [[ -n $destination ]] || return 0
  if [[ $destination == - ]]; then
    printf '%s' "$headers"
  else
    printf '%s' "$headers" >"$destination"
  fi
}

write_mcp_response() {
  local response=$1
  local output=$2
  local content_type
  content_type=$(fixture_value '.mcp.responseContentType')

  case "$content_type" in
    application/json)
      write_response "$response" "$output"
      ;;
    text/event-stream)
      [[ $output != /dev/null ]] || missing "MCP response output"
      {
        while IFS= read -r event; do
          printf 'data: %s\n\n' "$event"
        done < <(jq -c '.mcp.sseEvents[]' "$fixture")
        printf 'data: %s\n\n' "$response"
      } >"$output"
      ;;
    *) missing "MCP response content type $content_type" ;;
  esac
}

run_curl() {
  local request=GET
  local dump_header=
  local output=
  local data=
  local timeout=
  local url=
  local seen_request=0
  local seen_dump_header=0
  local seen_output=0
  local seen_data=0
  local seen_timeout=0
  local seen_silent=0
  local seen_show_error=0
  local seen_fail=0
  local seen_write_out=0
  local write_out=
  local header_count=0
  local header header_name header_value
  declare -A request_headers=()

  while (($#)); do
    case "$1" in
      --request)
        (($# >= 2 && seen_request == 0)) || missing "$*"
        seen_request=1
        request=$2
        shift 2
        ;;
      --dump-header)
        (($# >= 2 && seen_dump_header == 0)) || missing "$*"
        seen_dump_header=1
        dump_header=$2
        shift 2
        ;;
      --output)
        (($# >= 2 && seen_output == 0)) || missing "$*"
        seen_output=1
        output=$2
        shift 2
        ;;
      --data-binary)
        (($# >= 2 && seen_data == 0)) || missing "$*"
        seen_data=1
        data=$2
        shift 2
        ;;
      --max-time)
        (($# >= 2 && seen_timeout == 0)) || missing "$*"
        seen_timeout=1
        timeout=$2
        shift 2
        ;;
      --header)
        (($# >= 2)) || missing "$*"
        header=$2
        [[ $header == *:* ]] || missing "$*"
        header_name=${header%%:*}
        header_name=${header_name,,}
        header_value=${header#*:}
        header_value=${header_value#"${header_value%%[![:space:]]*}"}
        [[ $header_name == content-type || $header_name == accept || $header_name == mcp-session-id || $header_name == mcp-protocol-version ]] \
          || missing "$*"
        [[ ${request_headers[$header_name]+present} != present ]] || missing "$*"
        request_headers[$header_name]=$header_value
        ((header_count += 1))
        shift 2
        ;;
      --silent)
        ((seen_silent == 0)) || missing "$*"
        seen_silent=1
        shift
        ;;
      --show-error)
        ((seen_show_error == 0)) || missing "$*"
        seen_show_error=1
        shift
        ;;
      --fail-with-body)
        ((seen_fail == 0)) || missing "$*"
        seen_fail=1
        shift
        ;;
      --write-out)
        (($# >= 2 && seen_write_out == 0)) || missing "$*"
        seen_write_out=1
        write_out=$2
        shift 2
        ;;
      *)
        [[ $1 != -* && -z $url ]] || missing "$*"
        url=$1
        shift
        ;;
    esac
  done

  ((seen_silent == 1 && seen_show_error == 1)) || missing "$request $url"
  ((seen_request == 1 && seen_output == 1 && seen_timeout == 1)) \
    || missing "$request $url"
  [[ -n $url && $timeout =~ ^[1-9][0-9]*$ ]] || missing "$request $url"

  local health_contract
  health_contract=$(jq -cer --arg url "$url" \
    '.healthTable[] | select(.url == $url)' <<<"$tables" 2>/dev/null) || health_contract=
  if [[ -n $health_contract ]]; then
    local health_status health_body expected_method expected_timeout
    expected_method=$(jq -r '.method' <<<"$health_contract")
    expected_timeout=$(jq -r '.timeout' <<<"$health_contract")
    [[ $request == "$expected_method" && $timeout == "$expected_timeout" ]] \
      || missing "$request $url"
    ((seen_dump_header == 0 && seen_data == 0 && seen_fail == 1 && seen_write_out == 0 && header_count == 0)) \
      || missing "$request $url"
    [[ $output == /dev/null ]] || missing "$request $url"
    health_status=$(fixture_value '.health[$url].status' --arg url "$url")
    health_body=$(fixture_value '.health[$url].body' --arg url "$url")
    write_response "$health_body" "$output"
    ((health_status < 400)) || exit 22
    return 0
  fi

  local gateway_url gateway_timeout session_id protocol_version
  gateway_url=$(jq -er '.gatewayUrl' <<<"$tables") || missing "$request $url"
  gateway_timeout=$(jq -er '[.mcpTable[].probe.timeout] | max' <<<"$tables") \
    || missing "$request $url"
  session_id=$(jq -er '.mcp.sessionId // empty' "$fixture" 2>/dev/null) || session_id=
  protocol_version=$(fixture_value '.mcp.protocolVersion')
  [[ $url == "$gateway_url" ]] || missing "$request $url"

  if [[ $request == DELETE ]]; then
    ((seen_dump_header == 0 && seen_data == 0 && seen_fail == 0 && seen_write_out == 1 && header_count == 2)) \
      || missing "$request $url"
    [[ $output == /dev/null && $timeout == "$gateway_timeout" && $write_out == '%{http_code}' ]] \
      || missing "$request $url"
    [[ -n $session_id && ${request_headers[mcp-session-id]-} == "$session_id" ]] \
      || missing "$request $url"
    [[ ${request_headers[mcp-protocol-version]-} == "$protocol_version" ]] \
      || missing "$request $url"
    local delete_status
    delete_status=$(fixture_value '.mcp.deleteStatus')
    printf '%s' "$delete_status"
    return 0
  fi

  ((seen_fail == 1 && seen_write_out == 0)) || missing "$request $url"
  [[ $request == POST && $data == @* && -f ${data#@} ]] || missing "$request $url"
  [[ ${request_headers[content-type]-} == application/json ]] || missing "$request $url"
  [[ ${request_headers[accept]-} == 'application/json, text/event-stream' ]] \
    || missing "$request $url"
  local payload
  payload=$(<"${data#@}")

  local method
  method=$(jq -er '.method // empty' <<<"$payload") || missing "$request $url"

  local response headers response_content_type
  response_content_type=$(fixture_value '.mcp.responseContentType')
  headers="Content-Type: ${response_content_type}"$'\r\n'
  case "$method" in
    initialize)
      ((seen_dump_header == 1 && header_count == 2)) || missing "$request $url"
      [[ $output != /dev/null && $timeout == "$gateway_timeout" ]] || missing "$request $url"
      jq -e '
        . == {
          jsonrpc:"2.0",
          id:1,
          method:"initialize",
          params:{
            protocolVersion:"2025-06-18",
            capabilities:{},
            clientInfo:{name:"dotfiles-doctor",version:"1"}
          }
        }
      ' <<<"$payload" >/dev/null || missing "$request $url"
      if [[ -n $session_id ]]; then
        headers+="Mcp-Session-Id: ${session_id}"$'\r\n'
      fi
      response=$(jq -cn --argjson id "$(jq '.id' <<<"$payload")" --arg protocol "$protocol_version" \
        '{jsonrpc:"2.0", $id, result:{protocolVersion:$protocol, capabilities:{}, serverInfo:{name:"fixture", version:"1"}}}')
      ;;
    notifications/initialized)
      ((seen_dump_header == 0 && header_count == 4)) || missing "$request $url"
      [[ $output == /dev/null && $timeout == "$gateway_timeout" ]] || missing "$request $url"
      [[ -n $session_id && ${request_headers[mcp-session-id]-} == "$session_id" ]] \
        || missing "$request $url"
      [[ ${request_headers[mcp-protocol-version]-} == "$protocol_version" ]] \
        || missing "$request $url"
      jq -e '. == {jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
        <<<"$payload" >/dev/null || missing "$request $url"
      local notification_status
      notification_status=$(fixture_value '.mcp.notificationStatus')
      ((notification_status < 400)) || exit 22
      response=
      ;;
    tools/list)
      ((seen_dump_header == 1 && header_count == 4)) || missing "$request $url"
      [[ $output != /dev/null && $timeout == "$gateway_timeout" ]] || missing "$request $url"
      [[ -n $session_id && ${request_headers[mcp-session-id]-} == "$session_id" ]] \
        || missing "$request $url"
      [[ ${request_headers[mcp-protocol-version]-} == "$protocol_version" ]] \
        || missing "$request $url"
      jq -e '. == {jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' \
        <<<"$payload" >/dev/null || missing "$request $url"
      response=$(jq -cn --argjson id "$(jq '.id' <<<"$payload")" \
        --slurpfile fixture "$fixture" \
        '{jsonrpc:"2.0", $id, result:{tools:($fixture[0].mcp.tools | map({name:.}))}}')
      ;;
    tools/call)
      ((seen_dump_header == 1 && header_count == 4)) || missing "$request $url"
      [[ $output != /dev/null ]] || missing "$request $url"
      [[ -n $session_id && ${request_headers[mcp-session-id]-} == "$session_id" ]] \
        || missing "$request $url"
      [[ ${request_headers[mcp-protocol-version]-} == "$protocol_version" ]] \
        || missing "$request $url"
      local tool_name target target_contract expected_id expected_timeout
      tool_name=$(jq -er '.params.name' <<<"$payload") || missing "$request $url"
      target_contract=$(jq -cer --arg tool "$tool_name" '
        .mcpTable | to_entries[]
        | select((.value.id + "_" + .value.probe.tool) == $tool)
        | {index:.key, row:.value}
      ' <<<"$tables" 2>/dev/null) || missing "$request $url"
      target=$(jq -r '.row.id' <<<"$target_contract")
      expected_id=$(jq -r '.index + 3' <<<"$target_contract")
      expected_timeout=$(jq -r '.row.probe.timeout' <<<"$target_contract")
      [[ $timeout == "$expected_timeout" ]] || missing "$request $url"
      jq -e --argjson expected_id "$expected_id" --argjson contract "$target_contract" '
        .jsonrpc == "2.0"
        and .id == $expected_id
        and .method == "tools/call"
        and .params.name == ($contract.row.id + "_" + $contract.row.probe.tool)
        and .params.arguments == $contract.row.probe.args
        and ((keys | sort) == ["id", "jsonrpc", "method", "params"])
        and ((.params | keys | sort) == ["arguments", "name"])
      ' <<<"$payload" >/dev/null || missing "$request $url"
      jq -e --arg target "$target" '.mcp.calls | has($target)' "$fixture" >/dev/null \
        || missing "$request $url"
      response=$(jq -cn --argjson id "$(jq '.id' <<<"$payload")" --arg target "$target" \
        --slurpfile fixture "$fixture" \
        '{jsonrpc:"2.0", $id} + $fixture[0].mcp.calls[$target]')
      ;;
    *)
      missing "$request $url"
      ;;
  esac

  write_headers "$headers" "$dump_header"
  if [[ -n $response ]]; then
    write_mcp_response "$response" "$output"
  fi
}

case "$command_name" in
  systemctl) run_systemctl "$@" ;;
  readlink) run_readlink "$@" ;;
  stat) run_stat "$@" ;;
  cmp) run_cmp "$@" ;;
  docker) run_docker "$@" ;;
  swapon) run_swapon "$@" ;;
  zramctl) run_zramctl "$@" ;;
  df) run_df "$@" ;;
  powershell.exe) run_powershell "$@" ;;
  journalctl) run_journalctl "$@" ;;
  du) run_du "$@" ;;
  curl) run_curl "$@" ;;
  *)
    actual_args=$(jq -cn --args '$ARGS.positional' -- "$@")
    jq -e --arg binary "$command_name" --argjson actual "$actual_args" '
      any(.agentTable[]; .binary == $binary and .versionArgs == $actual)
    ' <<<"$tables" >/dev/null || missing "$*"
    stdout=$(fixture_value '.binaries[$command].stdout' --arg command "$command_name")
    status=$(fixture_value '.binaries[$command].exit' --arg command "$command_name")
    printf '%s\n' "$stdout"
    exit "$status"
    ;;
esac
