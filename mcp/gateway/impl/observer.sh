# shellcheck shell=bash

set -euo pipefail

curl_command=@curlCommand@
gateway_timeout=@gatewayTimeout@
gateway_url=@gatewayUrl@
jq_command=@jqCommand@
mktemp_command=@mktempCommand@
probes_json=@probesJson@
rm_command=@rmCommand@

scratch_root=$("$mktemp_command" -d "${TMPDIR:-/tmp}/mcp-gateway-observer.XXXXXXXX")
cleanup() {
  "$rm_command" -rf -- "$scratch_root"
}
trap cleanup EXIT

declare -A outcome_status=()
declare -A outcome_message=()

set_outcome() {
  local id=$1
  outcome_status["$id"]=$2
  outcome_message["$id"]=$3
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

if ! "$curl_command" \
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
  "$gateway_url" 2>/dev/null; then
  set_outcome mcp-session fail "MCP initialize request failed"
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
session_id=${session_headers[0]}

delete_session() {
  local delete_status
  delete_status=$("$curl_command" \
    --silent \
    --show-error \
    --max-time "$gateway_timeout" \
    --request DELETE \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header "mcp-session-id: $session_id" \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    "$gateway_url" 2>/dev/null) \
    && [[ $delete_status =~ ^[0-9]{3}$ ]] \
    && { ((delete_status >= 200 && delete_status < 300)) || ((delete_status == 405)); }
}

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
  delete_session || true
  set_outcome mcp-session fail "MCP initialize response is invalid"
  emit_envelope
  exit 0
fi

"$jq_command" -cn \
  '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
  >"$notification_request"
if ! "$curl_command" \
  --silent \
  --show-error \
  --fail-with-body \
  --max-time "$gateway_timeout" \
  --request POST \
  --output /dev/null \
  --header 'content-type: application/json' \
  --header 'accept: application/json, text/event-stream' \
  --header "mcp-session-id: $session_id" \
  --header 'MCP-Protocol-Version: 2025-06-18' \
  --data-binary "@$notification_request" \
  "$gateway_url" 2>/dev/null; then
  delete_session || true
  set_outcome mcp-session fail "MCP initialized notification failed"
  emit_envelope
  exit 0
fi

tools_request=$scratch_root/tools-list-request.json
tools_headers=$scratch_root/tools-list.headers
tools_body=$scratch_root/tools-list.body
tools_json=$scratch_root/tools-list.json
"$jq_command" -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' >"$tools_request"

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
  --header 'MCP-Protocol-Version: 2025-06-18' \
  --data-binary "@$tools_request" \
  "$gateway_url" 2>/dev/null \
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
  set_outcome mcp-tools fail "MCP tools/list response does not cover every target probe"
fi

run_target() {
  local index=$1
  local target_id=$2
  local rpc_id=$((index + 3))
  local target_timeout call_request call_headers call_body call_json
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
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data-binary "@$call_request" \
    "$gateway_url" 2>/dev/null \
    && decode_response "$call_headers" "$call_body" "$rpc_id" "$call_json" \
    && "$jq_command" -e --argjson rpc_id "$rpc_id" '
      .jsonrpc == "2.0"
      and .id == $rpc_id
      and has("result")
      and (has("error") | not)
      and (.result | type == "object")
      and (.result.content | type == "array")
      and ((.result | has("isError") | not) or (.result.isError | type == "boolean"))
      and ((.result.isError // false) == false)
    ' "$call_json" >/dev/null 2>&1; then
    printf 'pass\n' >"$scratch_root/tools-call-$index.status"
  else
    printf 'fail\n' >"$scratch_root/tools-call-$index.status"
  fi
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
  target_id=${target_ids[$index]}
  if [[ $(<"$scratch_root/tools-call-$index.status") == pass ]]; then
    set_outcome "mcp-target/$target_id" pass "MCP tools/call passed"
  else
    set_outcome "mcp-target/$target_id" fail "MCP tools/call failed or returned an MCP error"
  fi
done

if delete_session; then
  set_outcome mcp-session pass "MCP session lifecycle passed"
else
  set_outcome mcp-session fail "MCP session DELETE failed"
fi

emit_envelope
