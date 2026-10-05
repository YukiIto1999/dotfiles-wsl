# shellcheck shell=bash

set -euo pipefail

curl_command=@curlCommand@
gateway_timeout=@gatewayTimeout@
gateway_url=@gatewayUrl@
jq_command=@jqCommand@
mktemp_command=@mktempCommand@
probes_json=@probesJson@
rm_command=@rmCommand@

umask 077
scratch_root=$("$mktemp_command" -d "${TMPDIR:-/tmp}/mcp-gateway-observer.XXXXXXXX")
session_id=
session_header_file=$scratch_root/session.headers
session_cleanup_required=0
write_session_headers() {
  printf 'mcp-session-id: %s\nMCP-Protocol-Version: 2025-06-18\n' "$session_id" \
    >"$session_header_file"
}
delete_session() {
  local delete_status curl_status=0
  delete_status=$("$curl_command" \
    --silent \
    --show-error \
    --max-time "$gateway_timeout" \
    --request DELETE \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header "@$session_header_file" \
    "$gateway_url" 2>/dev/null) || curl_status=$?
  ((curl_status == 0)) || return "$curl_status"
  [[ $delete_status =~ ^[0-9]{3}$ ]] \
    && { ((delete_status >= 200 && delete_status < 300)) || ((delete_status == 405)); }
}
cleanup() {
  local status=$?
  trap - EXIT TERM INT
  if ((session_cleanup_required == 1)); then
    if [[ ! -s $session_header_file ]]; then
      write_session_headers || true
    fi
    delete_session || true
  fi
  "$rm_command" -rf -- "$scratch_root"
  exit "$status"
}
terminate() {
  exit "$1"
}
trap cleanup EXIT
trap 'terminate 130' INT
trap 'terminate 143' TERM

curl_timeout_status=28
curl_http_error_status=22

declare -A outcome_status=()
declare -A outcome_message=()

set_outcome() {
  local id=$1
  outcome_status["$id"]=$2
  outcome_message["$id"]=$3
}

# 期限切れは観測の未完了だけを示し対象の故障を示さないため fail による報告は不可
set_request_failure() {
  local id=$1 curl_status=$2 timeout_seconds=$3 failure_message=$4
  if ((curl_status == curl_timeout_status)); then
    set_outcome "$id" warn "observation did not finish within ${timeout_seconds}s"
  else
    set_outcome "$id" fail "$failure_message"
  fi
}

decode_response() {
  local headers=$1
  local body=$2
  local expected_id=$3
  local output=$4
  local line header_name header_value media_type payload
  local data_seen=0
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
    ' "$body" >"$output" 2>/dev/null
    return
  fi

  [[ $media_type == text/event-stream ]] || return 1
  payload=
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
    ' >/dev/null 2>&1 <<<"$payload"; then
      ((response_count += 1))
      printf '%s\n' "$payload" >"$output"
    elif ! "$jq_command" -e '
      .jsonrpc == "2.0"
      and (.method | type == "string")
      and (has("result") | not)
      and (has("error") | not)
    ' >/dev/null 2>&1 <<<"$payload"; then
      return 1
    fi
  done

  ((response_count == 1))
}

is_empty_accepted_response() {
  local headers=$1
  local body=$2
  local status=$3
  local line header_name
  local content_type_count=0

  [[ $status == 202 ]] || return 1
  [[ ! -s $body ]] || return 1

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    header_name=${line%%:*}
    if [[ ${header_name,,} == content-type ]]; then
      ((content_type_count += 1))
    fi
  done <"$headers"

  ((content_type_count == 0))
}

emit_envelope() {
  local outcomes_file=$scratch_root/outcomes.jsonl
  local id
  : >"$outcomes_file"
  for id in "mcp-session" "mcp-tools"; do
    if [[ -v outcome_status[$id] ]]; then
      "$jq_command" -cn \
        --arg id "$id" \
        --arg status "${outcome_status[$id]}" \
        --arg message "${outcome_message[$id]}" \
        '{id:$id,status:$status,message:$message}' >>"$outcomes_file"
    fi
  done
  while IFS= read -r id; do
    id="mcp-target/$id"
    if [[ -v outcome_status[$id] ]]; then
      "$jq_command" -cn \
        --arg id "$id" \
        --arg status "${outcome_status[$id]}" \
        --arg message "${outcome_message[$id]}" \
        '{id:$id,status:$status,message:$message}' >>"$outcomes_file"
    fi
  done < <("$jq_command" -r 'keys[]' <<<"$probes_json")
  "$jq_command" -cns --slurpfile outcomes "$outcomes_file" \
    '{schemaVersion:1,outcomes:$outcomes,resources:[]}'
}

initialize_headers=$scratch_root/initialize.headers
initialize_body=$scratch_root/initialize.body
initialize_json=$scratch_root/initialize.json
initialize_request=$scratch_root/initialize-request.json
notification_request=$scratch_root/notification-request.json
notification_headers=$scratch_root/notification.headers
notification_body=$scratch_root/notification.body

"$jq_command" -cn '
  {
    jsonrpc:"2.0",
    id:1,
    method:"initialize",
    params:{
      protocolVersion:"2025-06-18",
      capabilities:{},
      clientInfo:{name:"dotfiles-doctor",version:"1"}
    }
  }
' >"$initialize_request"

initialize_curl_status=0
"$curl_command" \
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
  "$gateway_url" 2>/dev/null || initialize_curl_status=$?
if ((initialize_curl_status != 0)); then
  set_request_failure mcp-session "$initialize_curl_status" "$gateway_timeout" \
    "MCP initialize request failed"
  emit_envelope
  exit 0
fi

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

if ((${#session_headers[@]} != 1)) || [[ -z ${session_headers[0]} ]]; then
  set_outcome mcp-session fail "MCP initialize did not return exactly one session ID"
  emit_envelope
  exit 0
fi
session_id=${session_headers[0]} session_cleanup_required=1
write_session_headers

if ! decode_response "$initialize_headers" "$initialize_body" 1 "$initialize_json" \
  || ! "$jq_command" -e '
    .jsonrpc == "2.0"
    and .id == 1
    and has("result")
    and (has("error") | not)
    and .result.protocolVersion == "2025-06-18"
    and (.result.capabilities | type == "object")
    and (.result.serverInfo | type == "object")
    and (.result.serverInfo.name | type == "string")
    and (.result.serverInfo.name | length > 0)
    and (.result.serverInfo.version | type == "string")
    and (.result.serverInfo.version | length > 0)
  ' "$initialize_json" >/dev/null 2>&1; then
  set_outcome mcp-session fail "MCP initialize response is invalid"
  emit_envelope
  exit 0
fi

"$jq_command" -cn \
  '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
  >"$notification_request"
notification_curl_status=0
notification_status=$("$curl_command" \
  --silent \
  --show-error \
  --fail-with-body \
  --max-time "$gateway_timeout" \
  --request POST \
  --dump-header "$notification_headers" \
  --output "$notification_body" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --header 'accept: application/json, text/event-stream' \
  --header "@$session_header_file" \
  --data-binary "@$notification_request" \
  "$gateway_url" 2>/dev/null) || notification_curl_status=$?
if ((notification_curl_status != 0)) \
  || ! is_empty_accepted_response "$notification_headers" "$notification_body" "$notification_status"; then
  set_request_failure mcp-session "$notification_curl_status" "$gateway_timeout" \
    "MCP initialized notification failed"
  emit_envelope
  exit 0
fi

tools_request=$scratch_root/tools-list-request.json
tools_headers=$scratch_root/tools-list.headers
tools_body=$scratch_root/tools-list.body
tools_json=$scratch_root/tools-list.json
"$jq_command" -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' >"$tools_request"

tools_curl_status=0
"$curl_command" \
  --silent \
  --show-error \
  --fail-with-body \
  --max-time "$gateway_timeout" \
  --request POST \
  --dump-header "$tools_headers" \
  --output "$tools_body" \
  --header 'content-type: application/json' \
  --header 'accept: application/json, text/event-stream' \
  --header "@$session_header_file" \
  --data-binary "@$tools_request" \
  "$gateway_url" 2>/dev/null || tools_curl_status=$?
if ((tools_curl_status == 0)) \
  && decode_response "$tools_headers" "$tools_body" 2 "$tools_json" \
  && "$jq_command" -e --argjson probes "$probes_json" '
    . as $response
    | .jsonrpc == "2.0"
      and .id == 2
      and (.result.tools | type == "array")
      and (has("error") | not)
      and all($probes | to_entries[];
        . as $probe
        | any($response.result.tools[];
            (.name | type == "string")
            and (.name | startswith($probe.key + "_")))
          and any($response.result.tools[];
            .name == ($probe.key + "_" + $probe.value.tool)))
  ' "$tools_json" >/dev/null 2>&1; then
  set_outcome mcp-tools pass "MCP tools/list covers every target probe"
else
  set_request_failure mcp-tools "$tools_curl_status" "$gateway_timeout" \
    "MCP tools/list response does not cover every target probe"
fi

run_target() {
  local index=$1
  local target_id=$2
  local outcome_id=mcp-target/$target_id
  local rpc_id=$((index + 3))
  local target_timeout call_request call_headers call_body call_json call_result
  local call_curl_status=0
  target_timeout=$("$jq_command" -r --arg id "$target_id" '.[$id].timeout' <<<"$probes_json")
  call_request=$scratch_root/tools-call-$index-request.json
  call_headers=$scratch_root/tools-call-$index.headers
  call_body=$scratch_root/tools-call-$index.body
  call_json=$scratch_root/tools-call-$index.json

  "$jq_command" -cn \
    --argjson rpc_id "$rpc_id" \
    --arg target_id "$target_id" \
    --argjson probes "$probes_json" '
      {
        jsonrpc:"2.0",
        id:$rpc_id,
        method:"tools/call",
        params:{
          name:($target_id + "_" + $probes[$target_id].tool),
          arguments:$probes[$target_id].args
        }
      }
    ' >"$call_request"

  "$curl_command" \
    --silent \
    --show-error \
    --fail-with-body \
    --max-time "$target_timeout" \
    --request POST \
    --dump-header "$call_headers" \
    --output "$call_body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$session_header_file" \
    --data-binary "@$call_request" \
    "$gateway_url" 2>/dev/null || call_curl_status=$?

  if ((call_curl_status == 0)); then
    call_result=invalid
    if decode_response "$call_headers" "$call_body" "$rpc_id" "$call_json"; then
      call_result=$("$jq_command" -r '
        def string_field($name):
          has($name) and (.[$name] | type == "string");
        def valid_resource_contents:
          type == "object"
          and string_field("uri")
          and (
            (string_field("text") and (has("blob") | not))
            or (string_field("blob") and (has("text") | not))
          );
        def valid_content_block:
          type == "object"
          and string_field("type")
          and (
            if .type == "text" then
              string_field("text")
            elif .type == "image" or .type == "audio" then
              string_field("data") and string_field("mimeType")
            elif .type == "resource_link" then
              string_field("name") and string_field("uri")
            elif .type == "resource" then
              has("resource") and (.resource | valid_resource_contents)
            else
              false
            end
          );
        def valid_error:
          type == "object"
          and (.code | type == "number" and . == floor)
          and string_field("message");
        def valid_result:
          type == "object"
          and (.content | type == "array")
          and all(.content[]; valid_content_block)
          and ((has("isError") | not) or (.isError | type == "boolean"));
        if has("result") and has("error") then
          "invalid"
        elif has("error") then
          if .error | valid_error then "mcp-error" else "invalid" end
        elif .result | valid_result | not then
          "invalid"
        elif .result.isError then
          "mcp-error"
        else
          "pass"
        end
      ' "$call_json" 2>/dev/null)
    fi
  elif ((call_curl_status == curl_http_error_status)); then
    # Streamable HTTP が session の失効や認可の拒否を HTTP status で返すため契約外の応答としての扱いは不可
    call_result=mcp-error
  else
    call_result=transport
  fi

  case $call_result in
    pass) set_outcome "$outcome_id" pass "MCP tools/call passed" ;;
    mcp-error) set_outcome "$outcome_id" fail "MCP tools/call returned an MCP error" ;;
    invalid) set_outcome "$outcome_id" fail "MCP tools/call response violates the MCP contract" ;;
    transport)
      set_request_failure "$outcome_id" "$call_curl_status" "$target_timeout" \
        "MCP tools/call connection to the gateway failed"
      ;;
  esac
  printf '%s\n%s\n' "${outcome_status[$outcome_id]}" "${outcome_message[$outcome_id]}" \
    >"$scratch_root/tools-call-$index.outcome"
}

target_ids=()
mapfile -t target_ids < <("$jq_command" -r 'keys[]' <<<"$probes_json")
target_pids=()
for index in "${!target_ids[@]}"; do
  run_target "$index" "${target_ids[$index]}" &
  target_pids+=("$!")
done
for pid in "${target_pids[@]}"; do
  wait "$pid"
done
for index in "${!target_ids[@]}"; do
  {
    IFS= read -r target_status
    IFS= read -r target_message
  } <"$scratch_root/tools-call-$index.outcome"
  set_outcome "mcp-target/${target_ids[$index]}" "$target_status" "$target_message"
done

delete_result=0
delete_session || delete_result=$?
if ((delete_result == 0)); then
  set_outcome mcp-session pass "MCP session lifecycle passed"
else
  set_request_failure mcp-session "$delete_result" "$gateway_timeout" "MCP session DELETE failed"
fi
session_cleanup_required=0

emit_envelope
