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
        --header)
          header_name=${value%%:*}
          header_value=${value#*:}
          header_value=${header_value#"${header_value%%[![:space:]]*}"}
          headers[${header_name,,}]=$header_value
          ;;
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

write_headers() {
  local content_type=$1
  shift
  [[ -z $dump_header ]] || {
    {
      printf 'HTTP/1.1 200 OK\r\n'
      printf 'Content-Type: %s\r\n' "$content_type"
      local session
      for session in "$@"; do
        printf 'Mcp-Session-Id: %s\r\n' "$session"
      done
      printf '\r\n'
    } >"$dump_header"
  }
}

write_body() {
  local content_type=$1
  local body=$2
  [[ $output == /dev/null ]] || printf '%s\n' "$body" >"$output"
  write_headers "$content_type" "${@:3}"
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
  [[ ${headers[mcp-session-id]-} == fixture-session ]] || exit 64
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
    [[ $case_name == secret-session ]] && session_headers=("$secret")
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
    write_body "$content_type" "$(rpc_body "$response")" "${session_headers[@]}"
    ;;
  notifications/initialized)
    [[ $max_time == 2 ]] || exit 64
    [[ ${headers[mcp-session-id]-} == fixture-session ]] || exit 64
    [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
    "$jq_command" -e '. == {jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
      "$data_file" >/dev/null || exit 64
    [[ $case_name == notification-error ]] && exit 22
    write_body application/json ''
    ;;
  tools/list)
    [[ $max_time == 2 ]] || exit 64
    [[ ${headers[mcp-session-id]-} == fixture-session ]] || exit 64
    [[ ${headers[mcp-protocol-version]-} == 2025-06-18 ]] || exit 64
    "$jq_command" -e '. == {jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' \
      "$data_file" >/dev/null || exit 64
    response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_ping"},{"name":"zeta_status"}]}}'
    [[ $case_name == tools-missing ]] && response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_ping"}]}}'
    [[ $case_name == tools-wrong-exact ]] && response='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"alpha_other"},{"name":"zeta_status"}]}}'
    write_body "$content_type" "$(rpc_body "$response")"
    ;;
  tools/call)
    [[ ${headers[mcp-session-id]-} == fixture-session ]] || exit 64
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
    response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{content:[]}}')
    [[ $case_name == target-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,error:{code:-32000,message:"private upstream detail"}}')
    [[ $case_name == target-is-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{isError:true,content:[]}}')
    [[ $case_name == target-missing-content && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{}}')
    [[ $case_name == target-invalid-is-error && $tool == alpha_ping ]] \
      && response=$("$jq_command" -cn --argjson id "$rpc_id" '{jsonrpc:"2.0",$id,result:{isError:"false",content:[]}}')
    write_body "$content_type" "$(rpc_body "$response")"
    ;;
  *)
    exit 64
    ;;
esac
