set -euo pipefail

: "${MCP_SESSION_FRONT_EXECUTABLE:?}"
: "${MCP_SEEDED_FRONT_CONFIG:?}"
: "${MCP_SEEDED_FRONT_PORT:?}"
: "${MCP_DRIFTED_FRONT_CONFIG:?}"
: "${MCP_DRIFTED_FRONT_PORT:?}"

live_description="Mutate or read session-local state."
drifted_description="Drifted seed description."

front_pids=()
cleanup() {
  for pid in "${front_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${front_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

# Each front's children record their starts and the calls they receive in the front's own directory
start_front() {
  local name=$1 config=$2 port=$3
  mkdir "$PWD/$name.markers"
  MCP_SESSION_FIXTURE_ROOT="$PWD/$name.markers" \
    "$MCP_SESSION_FRONT_EXECUTABLE" -f "$config" >"$name.front.log" 2>&1 &
  front_pids+=("$!")
  for _ in {1..200}; do
    if ss -H -ltn | grep -Fq "127.0.0.1:$port"; then
      return 0
    fi
    kill -0 "${front_pids[-1]}"
    sleep 0.05
  done
  printf '%s front never listened on %s\n' "$name" "$port" >&2
  return 1
}
use_front() {
  endpoint=http://127.0.0.1:$2/mcp
  markers=$PWD/$1.markers
}

count_markers() {
  find "$markers" -maxdepth 1 -type f -name "$1.*" | wc -l
}
wait_for_count() {
  local kind=$1 expected=$2 attempts=$3
  for ((attempt = 0; attempt < attempts; attempt++)); do
    [[ $(count_markers "$kind") -eq $expected ]] && return 0
    sleep 0.1
  done
  printf '%s markers: got %s, expected %s\n' \
    "$kind" "$(count_markers "$kind")" "$expected" >&2
  return 1
}
# A started child writes its marker after the response that started it, so absence needs a grace period.
assert_count_stays() {
  local kind=$1 expected=$2
  sleep 1
  if [[ $(count_markers "$kind") -ne $expected ]]; then
    printf '%s markers: got %s, expected %s\n' \
      "$kind" "$(count_markers "$kind")" "$expected" >&2
    return 1
  fi
}
normalize_response() {
  local body=$1 rpc_id=$2 output=$3
  if jq -e --argjson rpc_id "$rpc_id" '.id == $rpc_id' "$body" >"$output" 2>/dev/null; then
    return 0
  fi
  sed -n 's/^data: //p' "$body" \
    | jq -ce --argjson rpc_id "$rpc_id" 'select(.id == $rpc_id)' >"$output"
}
initialize() {
  local name=$1 client=$2 protocol=$3
  jq -cn --arg client "$client" --arg protocol "$protocol" '{
    jsonrpc:"2.0",
    id:1,
    method:"initialize",
    params:{
      protocolVersion:$protocol,
      capabilities:{},
      clientInfo:{name:$client,version:"1"}
    }
  }' >"$name.initialize.request"
  curl --silent --show-error --fail-with-body --max-time 10 \
    --request POST \
    --dump-header "$name.initialize.headers" \
    --output "$name.initialize.body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --data-binary "@$name.initialize.request" \
    "$endpoint"
  session_id=$(awk '
    tolower($1) == "mcp-session-id:" {gsub("\\r", "", $2); print $2}
  ' "$name.initialize.headers")
  [[ -n $session_id ]]
  normalize_response "$name.initialize.body" 1 "$name.initialize.json"
  negotiated=$(jq -er '.result.protocolVersion' "$name.initialize.json")
  printf 'mcp-session-id: %s\nMCP-Protocol-Version: %s\n' "$session_id" "$negotiated" \
    >"$name.session.headers"
  jq -cn '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
    >"$name.initialized.request"
  test "$(curl --silent --show-error --fail-with-body --max-time 10 \
    --request POST \
    --output "$name.initialized.body" \
    --write-out '%{http_code}' \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$name.session.headers" \
    --data-binary "@$name.initialized.request" \
    "$endpoint")" = 202
}
rpc() {
  local name=$1 rpc_id=$2 body=$3 output=$4
  printf '%s' "$body" >"$name.$rpc_id.request"
  curl --silent --show-error --fail-with-body --max-time 10 \
    --request POST \
    --output "$name.$rpc_id.body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$name.session.headers" \
    --data-binary "@$name.$rpc_id.request" \
    "$endpoint"
  normalize_response "$name.$rpc_id.body" "$rpc_id" "$output"
}
state_request() {
  jq -cn --argjson rpc_id "$1" --arg action "$2" --arg value "$3" '{
    jsonrpc:"2.0",
    id:$rpc_id,
    method:"tools/call",
    params:{name:"state",arguments:{action:$action,value:$value}}
  }'
}
call_state() {
  local name=$1 rpc_id=$2 action=$3 value=$4 output=$5
  rpc "$name" "$rpc_id" "$(state_request "$rpc_id" "$action" "$value")" "$output"
}
# A rejected call is an HTTP failure or a JSON-RPC error, never a result
assert_call_rejected() {
  local name=$1 rpc_id=$2 action=$3 value=$4 status
  state_request "$rpc_id" "$action" "$value" >"$name.$rpc_id.request"
  status=$(curl --silent --show-error --max-time 10 \
    --request POST \
    --output "$name.$rpc_id.body" \
    --write-out '%{http_code}' \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$name.session.headers" \
    --data-binary "@$name.$rpc_id.request" \
    "$endpoint")
  if ((status >= 400)); then
    return 0
  fi
  normalize_response "$name.$rpc_id.body" "$rpc_id" "$name.$rpc_id.json"
  jq -e 'has("error") and (has("result") | not)' "$name.$rpc_id.json" >/dev/null
}
list_tools() {
  rpc "$1" 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$1.tools.json"
}
delete_session() {
  curl --silent --show-error --fail-with-body --max-time 10 \
    --request DELETE \
    --output /dev/null \
    --header "@$1.session.headers" \
    "$endpoint"
}
assert_session_closed() {
  test "$(curl --silent --show-error --max-time 10 \
    --request POST \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$1.session.headers" \
    --data '{"jsonrpc":"2.0","id":20,"method":"tools/list"}' \
    "$endpoint")" = 404
}
connect() {
  initialize "$1" "${2:-seeded-front-check}" "${3:-2025-06-18}"
  list_tools "$1"
}
assert_tool_description() {
  jq -e --arg description "$2" \
    '[.result.tools[] | [.name, .description]] == [["state", $description]]' "$1.tools.json" >/dev/null
}

start_front seeded "$MCP_SEEDED_FRONT_CONFIG" "$MCP_SEEDED_FRONT_PORT"
start_front drifted "$MCP_DRIFTED_FRONT_CONFIG" "$MCP_DRIFTED_FRONT_PORT"

use_front seeded "$MCP_SEEDED_FRONT_PORT"

# The first session after deployment negotiates and lists from the seed without a child
connect a
assert_tool_description a "$live_description"
rpc a 3 '{"jsonrpc":"2.0","id":3,"method":"ping"}' a.ping.json
jq -e '.result == {}' a.ping.json >/dev/null
# The server's own answer to a list it does not support is seeded as well
rpc a 4 '{"jsonrpc":"2.0","id":4,"method":"prompts/list"}' a.prompts.json
jq -e '.error.code == -32601' a.prompts.json >/dev/null
assert_count_stays start 0

# Every supported stateful protocol is served without a child
for protocol in 2024-11-05 2025-03-26 2025-11-25; do
  connect "protocol-$protocol" seeded-front-check "$protocol"
  assert_tool_description "protocol-$protocol" "$live_description"
done
# The HTTP transport rejects an unsupported offer before opening a session
test "$(jq -c '.params.protocolVersion = "2099-01-01"' a.initialize.request | curl \
  --silent --show-error --max-time 10 \
  --dump-header unknown.initialize.headers \
  --output unknown.initialize.body \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --header 'accept: application/json, text/event-stream' \
  --data-binary @- \
  "$endpoint")" = 400
if grep -iq '^mcp-session-id:' unknown.initialize.headers; then
  echo "unsupported initialize returned a session ID" >&2
  exit 1
fi
assert_count_stays start 0

# The first call starts the session's own child, which agrees with the seed and gets the call
call_state a 5 add alpha a.add.json
wait_for_count start 1 100
jq -e '(.result.content[0].text | fromjson) == ["alpha"]' a.add.json >/dev/null
wait_for_count call 1 100

# Another session stays dormant until its own call, then starts with fresh state
connect b
assert_count_stays start 1
call_state b 3 list "" b.list.json
wait_for_count start 2 100
jq -e '(.result.content[0].text | fromjson) == []' b.list.json >/dev/null
call_state a 6 list "" a.list.json
jq -e '(.result.content[0].text | fromjson) == ["alpha"]' a.list.json >/dev/null

# Deleting a dormant session never starts a child
connect e
delete_session e
assert_session_closed e
assert_count_stays start 2
for pid in "${front_pids[@]}"; do
  kill -0 "$pid"
done

use_front drifted "$MCP_DRIFTED_FRONT_PORT"

# A seed that disagrees with the live server is served while dormant, but no call passes it
connect d
assert_tool_description d "$drifted_description"
assert_count_stays start 0
assert_call_rejected d 3 add beta
wait_for_count start 1 100
assert_count_stays call 0

# Discovery that disagreed with the live server is no longer served from the seed
connect f
assert_tool_description f "$live_description"
for pid in "${front_pids[@]}"; do
  kill -0 "$pid"
done
