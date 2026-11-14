set -euo pipefail

: "${MCP_SESSION_FRONT_EXECUTABLE:?}"
: "${MCP_SESSION_FRONT_CONFIG:?}"
: "${MCP_SESSION_FRONT_PORT:?}"

endpoint=http://127.0.0.1:$MCP_SESSION_FRONT_PORT/mcp
export MCP_SESSION_FIXTURE_ROOT="$PWD/markers"
mkdir "$MCP_SESSION_FIXTURE_ROOT"
"$MCP_SESSION_FRONT_EXECUTABLE" -f "$MCP_SESSION_FRONT_CONFIG" >front.log 2>&1 &
front_pid=$!
cleanup() {
  kill -TERM "$front_pid" 2>/dev/null || true
  wait "$front_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..200}; do
  if ss -H -ltn | grep -Fq "127.0.0.1:$MCP_SESSION_FRONT_PORT"; then
    break
  fi
  kill -0 "$front_pid"
  sleep 0.05
done
listeners=$(ss -H -ltn)
grep -Fq "127.0.0.1:$MCP_SESSION_FRONT_PORT" <<<"$listeners"

count_markers() {
  find "$MCP_SESSION_FIXTURE_ROOT" -maxdepth 1 -type f -name "$1.*" | wc -l
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
  local name=$1 client=$2
  jq -cn --arg client "$client" '{
    jsonrpc:"2.0",
    id:1,
    method:"initialize",
    params:{
      protocolVersion:"2025-06-18",
      capabilities:{},
      clientInfo:{name:$client,version:"1"}
    }
  }' >"$name.initialize.request"
  curl --silent --show-error --fail-with-body --max-time 5 \
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
  printf 'mcp-session-id: %s\nMCP-Protocol-Version: 2025-06-18\n' "$session_id" \
    >"$name.session.headers"
  normalize_response "$name.initialize.body" 1 "$name.initialize.json"
  jq -cn '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
    >"$name.initialized.request"
  test "$(curl --silent --show-error --fail-with-body --max-time 5 \
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
  curl --silent --show-error --fail-with-body --max-time 5 \
    --request POST \
    --output "$name.$rpc_id.body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$name.session.headers" \
    --data-binary "@$name.$rpc_id.request" \
    "$endpoint"
  normalize_response "$name.$rpc_id.body" "$rpc_id" "$output"
}
list_tools() {
  rpc "$1" 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$1.tools.json"
}
call_state() {
  local name=$1 rpc_id=$2 action=$3 value=$4 output=$5
  rpc "$name" "$rpc_id" "$(jq -cn \
    --argjson rpc_id "$rpc_id" \
    --arg action "$action" \
    --arg value "$value" \
    '{
      jsonrpc:"2.0",
      id:$rpc_id,
      method:"tools/call",
      params:{name:"state",arguments:{action:$action,value:$value}}
    }')" "$output"
}
delete_session() {
  curl --silent --show-error --fail-with-body --max-time 5 \
    --request DELETE \
    --output /dev/null \
    --header "@$1.session.headers" \
    "$endpoint"
}
assert_session_closed() {
  test "$(curl --silent --show-error --max-time 5 \
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
  initialize "$1" "${2:-lazy-front-check}"
  list_tools "$1"
}
same_discovery() {
  diff <(jq -S 'del(.id)' "$1.initialize.json") <(jq -S 'del(.id)' "$2.initialize.json")
  diff <(jq -S 'del(.id)' "$1.tools.json") <(jq -S 'del(.id)' "$2.tools.json")
}

# Two live sessions of one client confirm the discovery; each starts its own child
connect a
connect b
wait_for_count start 2 100
jq -e '[.result.tools[].name] == ["state"]' a.tools.json >/dev/null
same_discovery a b

# A confirmed identical session is served without a child
connect c
assert_count_stays start 2
same_discovery a c

# The first call starts the session's own child with fresh state
call_state c 3 add gamma c.add.json
wait_for_count start 3 100
jq -e '(.result.content[0].text | fromjson) == ["gamma"]' c.add.json >/dev/null
connect d
assert_count_stays start 3
call_state d 3 list "" d.list.json
wait_for_count start 4 100
jq -e '(.result.content[0].text | fromjson) == []' d.list.json >/dev/null
call_state c 4 list "" c.list.json
jq -e '(.result.content[0].text | fromjson) == ["gamma"]' c.list.json >/dev/null

# Deleting a dormant session never starts a child
connect e
assert_count_stays start 4
delete_session e
assert_session_closed e
assert_count_stays start 4

# Discovery is scoped to the exact client initialize request
connect g other-client
wait_for_count start 5 100
same_discovery a g

# An idle dormant session expires without ever starting a child
connect f
assert_count_stays start 5
sleep 35
assert_session_closed f
assert_count_stays start 5
kill -0 "$front_pid"
