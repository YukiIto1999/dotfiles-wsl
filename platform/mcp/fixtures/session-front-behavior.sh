set -euo pipefail

: "${MCP_SESSION_FRONT_EXECUTABLE:?}"
: "${MCP_SESSION_FRONT_CONFIG:?}"

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
  if ss -H -ltn | grep -Fq '127.0.0.1:18779'; then
    break
  fi
  kill -0 "$front_pid"
  sleep 0.05
done
listeners=$(ss -H -ltn | grep -E '(:|\])18779[[:space:]]' || true)
grep -Fq '127.0.0.1:18779' <<<"$listeners"
if grep -Eq '(\*|0\.0\.0\.0|\[::\]):18779' <<<"$listeners"; then
  exit 1
fi

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
normalize_response() {
  local body=$1 rpc_id=$2 output=$3
  if jq -e --argjson rpc_id "$rpc_id" '.id == $rpc_id' "$body" >"$output" 2>/dev/null; then
    return 0
  fi
  sed -n 's/^data: //p' "$body" \
    | jq -ce --argjson rpc_id "$rpc_id" 'select(.id == $rpc_id)' >"$output"
}
initialize() {
  local name=$1
  jq -cn '{
    jsonrpc:"2.0",
    id:1,
    method:"initialize",
    params:{
      protocolVersion:"2025-06-18",
      capabilities:{},
      clientInfo:{name:"session-front-check",version:"1"}
    }
  }' >"$name.initialize.request"
  curl --silent --show-error --fail-with-body --max-time 5 \
    --request POST \
    --dump-header "$name.initialize.headers" \
    --output "$name.initialize.body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --data-binary "@$name.initialize.request" \
    http://127.0.0.1:18779/mcp
  session_id=$(awk '
    tolower($1) == "mcp-session-id:" {gsub("\\r", "", $2); print $2}
  ' "$name.initialize.headers")
  [[ -n $session_id ]]
  printf 'mcp-session-id: %s\nMCP-Protocol-Version: 2025-06-18\n' "$session_id" \
    >"$name.session.headers"
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
    http://127.0.0.1:18779/mcp)" = 202
}
call_state() {
  local name=$1 rpc_id=$2 action=$3 value=$4 output=$5
  jq -cn \
    --argjson rpc_id "$rpc_id" \
    --arg action "$action" \
    --arg value "$value" \
    '{
      jsonrpc:"2.0",
      id:$rpc_id,
      method:"tools/call",
      params:{name:"state",arguments:{action:$action,value:$value}}
    }' >"$name.call.request"
  curl --silent --show-error --fail-with-body --max-time 5 \
    --request POST \
    --output "$name.call.body" \
    --header 'content-type: application/json' \
    --header 'accept: application/json, text/event-stream' \
    --header "@$name.session.headers" \
    --data-binary "@$name.call.request" \
    http://127.0.0.1:18779/mcp
  normalize_response "$name.call.body" "$rpc_id" "$output"
}
delete_session() {
  local name=$1
  curl --silent --show-error --fail-with-body --max-time 5 \
    --request DELETE \
    --output /dev/null \
    --header "@$name.session.headers" \
    http://127.0.0.1:18779/mcp
}

initialize a
initialize b
wait_for_count start 2 100
call_state a 2 add alpha a.add.json
call_state b 2 list "" b.list.json
jq -e '(.result.content[0].text | fromjson) == []' b.list.json >/dev/null
call_state a 3 list "" a.list.json
jq -e '(.result.content[0].text | fromjson) == ["alpha"]' a.list.json >/dev/null

delete_session a
wait_for_count exit 1 100
kill -0 "$front_pid"
call_state b 3 list "" b.after-delete.json
jq -e '(.result.content[0].text | fromjson) == []' b.after-delete.json >/dev/null
delete_session b
wait_for_count exit 2 100

initialize c
wait_for_count start 3 100
wait_for_count exit 3 400
kill -0 "$front_pid"
initialize d
wait_for_count start 4 100
delete_session d
wait_for_count exit 4 100
