usage() {
  cat <<'USAGE'
usage: dotfiles-doctor [--json]

Reconcile the declared dotfiles deployment with the running system. Exit 0
when every check passes, 1 when any check fails.
USAGE
}

json=0
case "${1-}" in
  --json) json=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

agent_table=@agentTable@
artifact_table=@artifactTable@
secret_table=@secretTable@
service_table=@serviceTable@
container_table=@containerTable@
health_table=@healthTable@
mcp_table=@mcpTable@
gateway_json=@gatewayUrl@

curl_command=@curlCommand@
docker_command=@dockerCommand@
jq_command=@jqCommand@
cmp_command=@cmpCommand@
readlink_command=@readlinkCommand@
stat_command=@statCommand@
systemctl_command=@systemctlCommand@

checks=()
failures=()

record_pass() {
  local id=$1
  local check
  check=$("$jq_command" -cn --arg id "$id" '{id:$id,status:"pass"}')
  checks+=("$check")
}

record_failure() {
  local id=$1
  local message=$2
  local check failure
  check=$("$jq_command" -cn --arg id "$id" '{id:$id,status:"fail"}')
  failure=$("$jq_command" -cn --arg id "$id" --arg message "$message" '{id:$id,message:$message}')
  checks+=("$check")
  failures+=("$failure")
}

probe_unit() {
  local id=$1
  local unit=$2
  local load_state active_state result

  if load_state=$("$systemctl_command" show "$unit" --property=LoadState --value 2>&1) \
    && active_state=$("$systemctl_command" show "$unit" --property=ActiveState --value 2>&1) \
    && result=$("$systemctl_command" show "$unit" --property=Result --value 2>&1); then
    if [[ $load_state == loaded && $active_state == active && $result == success ]]; then
      record_pass "$id"
    else
      record_failure "$id" "$unit is $load_state/$active_state/$result"
    fi
  else
    record_failure "$id" "could not read systemd state for $unit"
  fi
}

decode_response() {
  local headers=$1
  local body=$2
  local expected_id=$3
  local output=$4
  local line header_name header_value media_type
  local data_seen=0
  local payload=
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
    ' "$body" >"$output"
    return
  fi

  [[ $media_type == text/event-stream ]] || return 1
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
    ' >/dev/null <<<"$payload"; then
      ((response_count += 1))
      printf '%s\n' "$payload" >"$output"
    elif ! "$jq_command" -e '
      .jsonrpc == "2.0"
      and (.method | type == "string")
      and (has("result") | not)
      and (has("error") | not)
    ' >/dev/null <<<"$payload"; then
      return 1
    fi
  done

  ((response_count == 1))
}

emit_json() {
  local checks_file=$doctor_tmp/checks.jsonl
  local failures_file=$doctor_tmp/failures.jsonl

  : >"$checks_file"
  : >"$failures_file"
  if ((${#checks[@]} > 0)); then
    printf '%s\n' "${checks[@]}" >"$checks_file"
  fi
  if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}" >"$failures_file"
  fi

  "$jq_command" -cn \
    --slurpfile checks "$checks_file" \
    --slurpfile failures "$failures_file" \
    '{checks:$checks,failures:$failures}'
}

doctor_tmp=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-doctor.XXXXXX")
trap 'rm -rf -- "$doctor_tmp"' EXIT

# 1. System generation reconciliation.
if current_system=$("$readlink_command" -f /run/current-system 2>&1) \
  && profile_system=$("$readlink_command" -f /nix/var/nix/profiles/system 2>&1); then
  if [[ $current_system == "$profile_system" ]]; then
    record_pass system-generation
  else
    record_failure system-generation "/run/current-system does not match the system profile"
  fi
else
  record_failure system-generation "could not resolve the current system generation"
fi

# 2. Home Manager activation is operationally distinct from the general roster.
mapfile -t service_rows < <("$jq_command" -c '.[]' <<<"$service_table")
mapfile -t home_manager_rows < <("$jq_command" -c '.[] | select(.role == "home-manager")' <<<"$service_table")
if ((${#home_manager_rows[@]} == 1)); then
  home_manager_unit=$("$jq_command" -r '.unit' <<<"${home_manager_rows[0]}")
  probe_unit home-manager "$home_manager_unit"
else
  record_failure home-manager "service roster must contain exactly one Home Manager unit"
fi

# 3. Agent executables and version commands.
mapfile -t agent_rows < <("$jq_command" -c '.[]' <<<"$agent_table")
if ((${#agent_rows[@]} == 0)); then
  record_failure agent-roster "agent roster is empty"
else
  for row in "${agent_rows[@]}"; do
    agent_id=$("$jq_command" -r '.id' <<<"$row")
    binary=$("$jq_command" -r '.binary' <<<"$row")
    mapfile -t version_args < <("$jq_command" -r '.versionArgs[]' <<<"$row")

    if binary_path=$(command -v -- "$binary") \
      && [[ -x $binary_path ]] \
      && "$binary_path" "${version_args[@]}" >/dev/null 2>&1; then
      record_pass "agent/$agent_id"
    else
      record_failure "agent/$agent_id" "$binary is unavailable or its version command failed"
    fi
  done
fi

# 4. Immutable sources must still match their deployed destinations.
mapfile -t artifact_rows < <("$jq_command" -c '.[]' <<<"$artifact_table")
for row in "${artifact_rows[@]}"; do
  artifact_id=$("$jq_command" -r '.id' <<<"$row")
  source_path=$("$jq_command" -r '.source' <<<"$row")
  destination=$("$jq_command" -r '.destination' <<<"$row")
  check_id="artifact/$artifact_id"

  if [[ -L $destination ]]; then
    if resolved_destination=$("$readlink_command" -f "$destination" 2>&1) \
      && [[ $resolved_destination == "$source_path" ]]; then
      record_pass "$check_id"
    else
      record_failure "$check_id" "$destination does not resolve to $source_path"
    fi
  elif [[ -f $destination ]]; then
    if "$cmp_command" --silent "$source_path" "$destination"; then
      record_pass "$check_id"
    else
      record_failure "$check_id" "$destination differs from $source_path"
    fi
  else
    record_failure "$check_id" "$destination is missing or has an unsupported file type"
  fi
done

# 5. Secret contents are never read; only ownership and mode are compared.
mapfile -t secret_rows < <("$jq_command" -c '.[]' <<<"$secret_table")
for row in "${secret_rows[@]}"; do
  secret_id=$("$jq_command" -r '.id' <<<"$row")
  secret_path=$("$jq_command" -r '.path' <<<"$row")
  secret_owner=$("$jq_command" -r '.owner' <<<"$row")
  secret_group=$("$jq_command" -r '.group' <<<"$row")
  secret_mode=$("$jq_command" -r '.mode' <<<"$row")
  expected_metadata="$secret_owner:$secret_group:${secret_mode#0}"

  if actual_metadata=$("$stat_command" --format %U:%G:%a "$secret_path" 2>&1) \
    && [[ $actual_metadata == "$expected_metadata" ]]; then
    record_pass "secret/$secret_id"
  else
    record_failure "secret/$secret_id" "$secret_path metadata does not match $expected_metadata"
  fi
done

# 6. Typed service roster.
if ((${#service_rows[@]} == 0)); then
  record_failure service-roster "service roster is empty"
else
  for row in "${service_rows[@]}"; do
    role=$("$jq_command" -r '.role' <<<"$row")
    [[ $role == home-manager ]] && continue
    unit=$("$jq_command" -r '.unit' <<<"$row")
    probe_unit "service/$unit" "$unit"
  done
fi

# 7. Running containers must use the image IDs declared by their image references.
mapfile -t container_rows < <("$jq_command" -c '.[]' <<<"$container_table")
if ((${#container_rows[@]} == 0)); then
  record_failure container-roster "container roster is empty"
else
  for row in "${container_rows[@]}"; do
    container=$("$jq_command" -r '.container' <<<"$row")
    image=$("$jq_command" -r '.image' <<<"$row")
    if declared_image_id=$("$docker_command" image inspect "$image" --format '{{.Id}}' 2>&1) \
      && running_image_id=$("$docker_command" inspect "$container" --format '{{.Image}}' 2>&1) \
      && [[ $declared_image_id == "$running_image_id" ]]; then
      record_pass "container-image/$container"
    else
      record_failure "container-image/$container" "$container is not running the declared image $image"
    fi
  done
fi

# 8. Application health endpoints.
mapfile -t health_rows < <("$jq_command" -c '.[]' <<<"$health_table")
for row in "${health_rows[@]}"; do
  application=$("$jq_command" -r '.application' <<<"$row")
  method=$("$jq_command" -r '.method' <<<"$row")
  timeout=$("$jq_command" -r '.timeout' <<<"$row")
  url=$("$jq_command" -r '.url' <<<"$row")
  if "$curl_command" \
    --silent \
    --show-error \
    --fail-with-body \
    --max-time "$timeout" \
    --request "$method" \
    --output /dev/null \
    "$url"; then
    record_pass "container-health/$application"
  else
    record_failure "container-health/$application" "$method $url failed"
  fi
done

# MCP Streamable HTTP session lifecycle.
mapfile -t mcp_rows < <("$jq_command" -c '.[]' <<<"$mcp_table")
if ((${#mcp_rows[@]} == 0)); then
  record_failure mcp-roster "MCP target roster is empty"
else
  gateway_url=$("$jq_command" -r '.' <<<"$gateway_json")
  gateway_timeout=$("$jq_command" -r '[.[].probe.timeout] | max' <<<"$mcp_table")
  initialize_headers=$doctor_tmp/initialize.headers
  initialize_body=$doctor_tmp/initialize.body
  initialize_json=$doctor_tmp/initialize.json
  initialize_request=$doctor_tmp/initialize-request.json
  notification_request=$doctor_tmp/notification-request.json

  "$jq_command" -cn \
    '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"dotfiles-doctor",version:"1"}}}' \
    >"$initialize_request"

  has_session=0
  has_protocol=0
  session_initialized=0
  if "$curl_command" \
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
    "$gateway_url"; then
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

    if ((${#session_headers[@]} == 1)) && [[ -n ${session_headers[0]} ]]; then
      session_id=${session_headers[0]}
      has_session=1
      if decode_response "$initialize_headers" "$initialize_body" 1 "$initialize_json" \
        && "$jq_command" -e \
          '.jsonrpc == "2.0"
           and .id == 1
           and has("result")
           and (has("error") | not)
           and (.result.protocolVersion | type == "string")
           and (.result.protocolVersion | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' \
          "$initialize_json" >/dev/null; then
        protocol_version=$("$jq_command" -r '.result.protocolVersion' "$initialize_json")
        has_protocol=1
        "$jq_command" -cn \
          '{jsonrpc:"2.0",method:"notifications/initialized",params:{}}' \
          >"$notification_request"
        if "$curl_command" \
          --silent \
          --show-error \
          --fail-with-body \
          --max-time "$gateway_timeout" \
          --request POST \
          --output /dev/null \
          --header 'content-type: application/json' \
          --header 'accept: application/json, text/event-stream' \
          --header "mcp-session-id: $session_id" \
          --header "MCP-Protocol-Version: $protocol_version" \
          --data-binary "@$notification_request" \
          "$gateway_url"; then
          record_pass mcp-session
          session_initialized=1
        else
          record_failure mcp-session "MCP initialized notification failed"
        fi
      else
        record_failure mcp-session "MCP initialize response is invalid"
      fi
    else
      record_failure mcp-session "MCP initialize did not return exactly one session ID"
    fi
  else
    record_failure mcp-session "MCP initialize request failed"
  fi

  if ((session_initialized == 1)); then
    tools_request=$doctor_tmp/tools-list-request.json
    tools_body=$doctor_tmp/tools-list.body
    tools_headers=$doctor_tmp/tools-list.headers
    tools_json=$doctor_tmp/tools-list.json
    "$jq_command" -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}' >"$tools_request"

    tools_valid=0
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
      --header "MCP-Protocol-Version: $protocol_version" \
      --data-binary "@$tools_request" \
      "$gateway_url" \
      && decode_response "$tools_headers" "$tools_body" 2 "$tools_json" \
      && "$jq_command" -e \
        '.jsonrpc == "2.0" and .id == 2 and (.result.tools | type == "array") and (has("error") | not)' \
        "$tools_json" >/dev/null; then
      tools_valid=1
      for row in "${mcp_rows[@]}"; do
        target_id=$("$jq_command" -r '.id' <<<"$row")
        probe_tool=$("$jq_command" -r '.probe.tool' <<<"$row")
        expected_tool="${target_id}_${probe_tool}"
        if ! "$jq_command" -e --arg prefix "${target_id}_" --arg expected "$expected_tool" \
          'any(.result.tools[]; (.name | type == "string") and (.name | startswith($prefix)))
           and any(.result.tools[]; .name == $expected)' \
          "$tools_json" >/dev/null; then
          tools_valid=0
        fi
      done
    fi

    if ((tools_valid == 1)); then
      record_pass mcp-tools
    else
      record_failure mcp-tools "MCP tools/list response does not cover every target probe"
    fi

    call_id=3
    for row in "${mcp_rows[@]}"; do
      target_id=$("$jq_command" -r '.id' <<<"$row")
      target_timeout=$("$jq_command" -r '.probe.timeout' <<<"$row")
      call_request=$doctor_tmp/tools-call-$call_id-request.json
      call_body=$doctor_tmp/tools-call-$call_id.body
      call_headers=$doctor_tmp/tools-call-$call_id.headers
      call_json=$doctor_tmp/tools-call-$call_id.json

      "$jq_command" -c --argjson rpc_id "$call_id" \
        '{jsonrpc:"2.0",id:$rpc_id,method:"tools/call",params:{name:(.id + "_" + .probe.tool),arguments:.probe.args}}' \
        <<<"$row" \
        >"$call_request"

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
        --header "MCP-Protocol-Version: $protocol_version" \
        --data-binary "@$call_request" \
        "$gateway_url" \
        && decode_response "$call_headers" "$call_body" "$call_id" "$call_json" \
        && "$jq_command" -e --argjson rpc_id "$call_id" \
          '.jsonrpc == "2.0"
           and .id == $rpc_id
           and has("result")
           and (has("error") | not)
           and ((.result.isError // false) == false)' \
          "$call_json" >/dev/null; then
        record_pass "mcp-target/$target_id"
      else
        record_failure "mcp-target/$target_id" "MCP tools/call failed or returned a JSON-RPC error"
      fi
      ((call_id += 1))
    done
  fi

  if ((has_session == 1 && has_protocol == 1)); then
    if delete_status=$("$curl_command" \
      --silent \
      --show-error \
      --max-time "$gateway_timeout" \
      --request DELETE \
      --output /dev/null \
      --write-out '%{http_code}' \
      --header "mcp-session-id: $session_id" \
      --header "MCP-Protocol-Version: $protocol_version" \
      "$gateway_url") \
      && [[ $delete_status =~ ^[0-9]{3}$ ]] \
      && { ((delete_status >= 200 && delete_status < 300)) || ((delete_status == 405)); }; then
      :
    else
      record_failure mcp-session "MCP session DELETE failed"
    fi
  fi
fi

report=$(emit_json)
if ((json == 1)); then
  printf '%s\n' "$report"
else
  "$jq_command" -r '.checks[] | "\(.status): \(.id)"' <<<"$report"
  if ((${#failures[@]} > 0)); then
    "$jq_command" -r '.failures[] | "  \(.id): \(.message)"' <<<"$report" >&2
  fi
fi

if ((${#failures[@]} > 0)); then
  exit 1
fi
exit 0
