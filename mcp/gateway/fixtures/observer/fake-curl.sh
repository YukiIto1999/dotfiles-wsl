# shellcheck shell=bash

set -euo pipefail

jq_command=@jqCommand@
sleep_command=@sleepCommand@
touch_command=@touchCommand@

request=GET
dump_header=
output=/dev/stdout
write_out=
max_time=
data_file=
declare -A headers=()

record_header() {
  local value=$1
  local header_name header_value line

  if [[ $value == @* ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      [[ -n $line ]] || continue
      record_header "$line"
    done <"${value#@}"
    return
  fi

  header_name=${value%%:*}
  header_value=${value#*:}
  header_value=${header_value#"${header_value%%[![:space:]]*}"}
  headers[${header_name,,}]=$header_value
}

while (($# > 0)); do
  case "$1" in
    --silent | --show-error | --fail-with-body)
      shift
      ;;
    --max-time | --request | --dump-header | --output | --write-out | --header | --data-binary)
      option=$1
      value=${2-}
      [[ -n $value ]] || exit 64
      shift 2
      case "$option" in
        --max-time) max_time=$value ;;
        --request) request=$value ;;
        --dump-header) dump_header=$value ;;
        --output) output=$value ;;
        --write-out) write_out=$value ;;
        --header) record_header "$value" ;;
        --data-binary) data_file=${value#@} ;;
      esac
      ;;
    http://*)
      gateway_url=$1
      shift
      ;;
    *)
      exit 64
      ;;
  esac
done

[[ ${gateway_url-} == http://127.0.0.1:18765/mcp ]] || exit 64
[[ -n $max_time ]] || exit 64
case_name=${MCP_OBSERVER_CASE:-healthy-json}
secret=${MCP_OBSERVER_SECRET-}
expected_session=fixture-session
[[ $case_name == argv-secret ]] && expected_session=$secret

write_headers() {
  local status=$1
  local content_type=$2
  shift 2
  [[ -z $dump_header ]] || {
    {
      printf 'HTTP/1.1 %s Fixture\r\n' "$status"
      [[ -z $content_type ]] || printf 'Content-Type: %s\r\n' "$content_type"
      local session
      for session in "$@"; do
        printf 'Mcp-Session-Id: %s\r\n' "$session"
      done
      printf '\r\n'
    } >"$dump_header"
  }
}

write_response() {
  local status=$1
  local content_type=$2
  local body=$3
  [[ $output == /dev/null ]] || printf '%s' "$body" >"$output"
  write_headers "$status" "$content_type" "${@:4}"
  [[ -z $write_out ]] || {
    [[ $write_out == '%{http_code}' ]] || exit 64
    printf '%s' "$status"
  }
}

rpc_body() {
  local response=$1
  if [[ $case_name == healthy-sse ]]; then
    printf 'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\ndata: %s\n' "$response"
  else
    printf '%s' "$response"
  fi
}

content_type=application/json
[[ $case_name == healthy-sse ]] && content_type='text/event-stream; charset=utf-8'

if [[ $request == DELETE ]]; then
  [[ $max_time == 2 ]] || exit 64
  delete_status=204
  [[ $case_name == delete-405 ]] && delete_status=405
  [[ $case_name == delete-failure ]] && delete_status=500
  [[ ${headers[mcp-session-id]-} == "$expected_session" ]] || exit 64
  [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
  [[ $write_out == '%{http_code}' ]] || exit 64
  [[ -z ${MCP_OBSERVER_DELETE_MARKER-} ]] || "$touch_command" "$MCP_OBSERVER_DELETE_MARKER"
  printf '%s' "$delete_status"
  exit 0
fi

[[ $request == POST ]] || exit 64
[[ -f $data_file ]] || exit 64
method=$("$jq_command" -r '.method' "$data_file")
case "$method" in
  initialize)
    [[ $max_time == 2 ]] || exit 64
    "$jq_command" -e '
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
    ' "$data_file" >/dev/null || exit 64
    [[ $case_name == observer-timeout ]] && "$sleep_command" 3
    if [[ $case_name == network-error || $case_name == secret-network ]]; then
      printf '%s\n' "${secret:-fixture transport error}" >&2
      exit 7
    fi
    session_headers=(fixture-session)
    [[ $case_name == missing-session ]] && session_headers=()
    [[ $case_name == duplicate-session ]] && session_headers=(fixture-session second-session)
    [[ $case_name == empty-session ]] && session_headers=("")
    [[ $case_name == secret-session || $case_name == argv-secret ]] && session_headers=("$secret")
    response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
    [[ $case_name == init-error ]] && response='{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"private upstream detail"}}'
    [[ $case_name == invalid-protocol ]] && response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"invalid","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
    [[ $case_name == init-missing-capabilities ]] && response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"fixture","version":"1"}}}'
    [[ $case_name == init-missing-server-info ]] && response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}'
    [[ $case_name == init-missing-server-name ]] && response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"version":"1"}}}'
    [[ $case_name == init-missing-server-version ]] && response='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fixture"}}}'
    [[ $case_name == secret-body ]] && response="{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"$secret\"}}"
    if [[ $case_name == invalid-content-type ]]; then
      content_type=text/plain
    fi
    [[ $case_name == post-session-jq-error ]] \
      && "$touch_command" "${MCP_OBSERVER_JQ_FAIL_MARKER:?}"
    write_response 200 "$content_type" "$(rpc_body "$response")" "${session_headers[@]}"
    ;;
  notifications/initialized)
    [[ $max_time == 2 ]] || exit 64
    [[ ${headers[mcp-session-id]-} == "$expected_session" ]] || exit 64
    [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
    "$jq_command" -e '. == {jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
      "$data_file" >/dev/null || exit 64
    [[ $case_name == notification-error ]] && exit 22
    if [[ $case_name == argv-secret ]]; then
      printf '%s\n' "$$" >"${MCP_OBSERVER_CURL_PID_FILE:?}"
      for _ in {1..500}; do
        [[ -e ${MCP_OBSERVER_CURL_RELEASE_FILE:?} ]] && break
        "$sleep_command" 0.02
      done
      [[ -e $MCP_OBSERVER_CURL_RELEASE_FILE ]] || exit 64
    fi
    if [[ $case_name == post-session-timeout || $case_name == post-session-term ]]; then
      "$touch_command" "${MCP_OBSERVER_POST_SESSION_MARKER:?}"
      "$sleep_command" 3
    fi
    notification_status=202
    notification_content_type=
    notification_body=
    [[ $case_name == notification-json-error ]] && {
      notification_status=200
      notification_content_type=application/json
      notification_body='{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"invalid notification"}}'
    }
    [[ $case_name == notification-body ]] && notification_body='unexpected'
    [[ $case_name == notification-content-type ]] && notification_content_type=application/json
    [[ $case_name == notification-redirect ]] && notification_status=302
    write_response "$notification_status" "$notification_content_type" "$notification_body"
    ;;
  tools/list)
    [[ $max_time == 2 ]] || exit 64
    [[ ${headers[mcp-session-id]-} == "$expected_session" ]] || exit 64
    [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
    "$jq_command" -e '. == {jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' \
      "$data_file" >/dev/null || exit 64
    response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_ping"},{"name":"zeta_status"}]}}'
    [[ $case_name == tools-missing ]] && response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_ping"}]}}'
    [[ $case_name == tools-wrong-exact ]] && response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_other"},{"name":"zeta_status"}]}}'
    write_response 200 "$content_type" "$(rpc_body "$response")"
    ;;
  tools/call)
    [[ ${headers[mcp-session-id]-} == "$expected_session" ]] || exit 64
    [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
    tool=$("$jq_command" -r '.params.name' "$data_file")
    rpc_id=$("$jq_command" -r '.id' "$data_file")
    case "$tool" in
      alpha_ping)
        [[ $max_time == 2 ]] || exit 64
        "$jq_command" -e '.params.arguments == {value:"alpha"}' "$data_file" >/dev/null || exit 64
        ;;
      zeta_status)
        [[ $max_time == 1 ]] || exit 64
        "$jq_command" -e '.params.arguments == {}' "$data_file" >/dev/null || exit 64
        ;;
      *) exit 64 ;;
    esac
    if [[ $case_name == parallel ]]; then
      parallel_root=${MCP_OBSERVER_PARALLEL_ROOT:?}
      "$touch_command" "$parallel_root/$tool"
      for _ in {1..100}; do
        if [[ -e $parallel_root/alpha_ping && -e $parallel_root/zeta_status ]]; then
          break
        fi
        "$sleep_command" 0.02
      done
      [[ -e $parallel_root/alpha_ping && -e $parallel_root/zeta_status ]] || exit 64
    fi
    response=$("$jq_command" -cn --argjson id "$rpc_id" '{
      jsonrpc:"2.0",
      $id,
      result:{content:[
        {type:"text",text:"fixture"},
        {type:"image",data:"aW1hZ2U=",mimeType:"image/png"},
        {type:"audio",data:"YXVkaW8=",mimeType:"audio/wav"},
        {type:"resource_link",name:"fixture",uri:"file:///fixture.txt"},
        {type:"resource",resource:{uri:"file:///fixture.txt",mimeType:"text/plain",text:"fixture"}},
        {type:"resource",resource:{uri:"file:///fixture.bin",mimeType:"application/octet-stream",blob:"Zml4dHVyZQ=="}}
      ]}
    }')
    [[ $case_name == target-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,error:{code:-32000,message:"private upstream detail"}}')
    [[ $case_name == target-is-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{isError:true,content:[]}}')
    [[ $case_name == target-missing-content && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{}}')
    [[ $case_name == target-invalid-is-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{isError:"false",content:[]}}')
    [[ $case_name == target-non-object-content && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[1]}}')
    [[ $case_name == target-unsupported-content && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"unknown"}]}}')
    [[ $case_name == target-missing-content-type && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{text:"fixture"}]}}')
    [[ $case_name == target-text-missing-field && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"text"}]}}')
    [[ $case_name == target-image-missing-field && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"image",data:"aW1hZ2U="}]}}')
    [[ $case_name == target-image-missing-data && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"image",mimeType:"image/png"}]}}')
    [[ $case_name == target-audio-missing-field && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"audio",mimeType:"audio/wav"}]}}')
    [[ $case_name == target-audio-missing-mime-type && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"audio",data:"YXVkaW8="}]}}')
    [[ $case_name == target-resource-link-missing-field && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"resource_link",uri:"file:///fixture"}]}}')
    [[ $case_name == target-resource-link-missing-uri && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"resource_link",name:"fixture"}]}}')
    [[ $case_name == target-resource-missing-field && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"resource",resource:{uri:"file:///fixture"}}]}}')
    [[ $case_name == target-resource-missing-object && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"resource"}]}}')
    [[ $case_name == target-resource-missing-uri && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[{type:"resource",resource:{text:"fixture"}}]}}')
    write_response 200 "$content_type" "$(rpc_body "$response")"
    ;;
  *)
    exit 64
    ;;
esac
