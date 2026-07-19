#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 DOCTOR_SOURCE OCI_IMAGE_STATE_SOURCE STORE_BASH NIX_IMAGE_IDENTITY_CASES" >&2
  exit 2
fi

doctor_source=$1
oci_image_state_source=$2
store_bash=$3
nix_image_identity_cases=$4
nix_image_identity=$(jq -er '.valid' "$nix_image_identity_cases")
nix_image_file=$(jq -er '.imageFile' "$nix_image_identity")
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

home=$test_root/home
current_generation=$test_root/generations/current
profile_generation=$test_root/generations/profile
manifest=$test_root/current/etc/dotfiles/doctor.json
fake_bin=$test_root/fake-bin
rendered_doctor=$test_root/doctor
empty_message_doctor=$test_root/doctor-empty-message
doctor_executable=$rendered_doctor
doctor_output=$test_root/doctor-output
unit_state=$test_root/unit-state
effect_state=$test_root/effect-state
root_state=$test_root/root-state.json
cli_version_state=$test_root/cli-version-state
mcp_scenario=$test_root/mcp-scenario
mcp_call_log=$test_root/mcp-call-log
mcp_timeout_log=$test_root/mcp-timeout-log
managed_source=$test_root/store/managed.conf
managed_runtime=$test_root/runtime/managed.conf
rules_source=$test_root/store/AGENTS.md
rules_runtime=$home/.fixture/AGENTS.md
gateway_runtime=$home/.fixture/gateway.json
gateway_source=$test_root/store/gateway.json
nix_ld_path=$test_root/lib64/ld-linux-x86-64.so.2
cli_path=$home/.local/bin/fixture-cli
skills_dir=$home/.fixture/skills
agents_dir=$home/.fixture/agents
agent_file=$agents_dir/fixture-agent.md
root_probe=$fake_bin/dotfiles-doctor-root-probe
wslview_source=$test_root/store/wslview
wslview_path=$current_generation/sw/bin/wslview
windows_command=$test_root/mnt/c/Windows/System32/cmd.exe
windows_command_state=$test_root/windows-command-state
systemctl_call_log=$test_root/systemctl-call-log
sudo_call_log=$test_root/sudo-call-log
cli_call_log=$test_root/cli-call-log
windows_call_log=$test_root/windows-call-log
docker_call_log=$test_root/docker-call-log
docker_lock_probe_log=$test_root/docker-lock-probe-log
sync_status_call_log=$test_root/sync-status-call-log
docker_state=$test_root/docker-state.json
sync_status_state=$test_root/sync-status-state
oci_state_root=$home/.local/state/dotfiles-wsl/image-sync
docker_command=$fake_bin/docker
sync_status_command=$fake_bin/dotfiles-sync-images
failed=0
mcp_max_times=5
mcp_max_filesize=1048576

mkdir -p \
  "$home/.local/bin" \
  "$home/.fixture" \
  "$current_generation/etc/dotfiles" \
  "$current_generation/sw/bin" \
  "$profile_generation" \
  "$fake_bin" \
  "$test_root/store" \
  "$test_root/runtime" \
  "$(dirname "$windows_command")" \
  "$(dirname "$nix_ld_path")"

printf '%s\n' '[user]' 'default=fixture' > "$current_generation/etc/wsl.conf"
printf '%s\n' '1' > "$current_generation/init-interface-version"
printf '%s\n' 'managed=true' > "$managed_source"
printf '%s\n' '# fixture rules' > "$rules_source"
printf '%s\n' '{"mcp":"http://127.0.0.1:1/mcp"}' > "$gateway_source"
touch "$nix_ld_path"

printf '#!%s\nexit 0\n' "$store_bash" > "$wslview_source"
printf '#!%s\n' "$store_bash" > "$windows_command"
printf '%s\n' \
  '[[ $# -eq 4 ]] || exit 2' \
  '[[ $1 == /d && $2 == /c && $3 == exit && $4 == 0 ]] || exit 2' \
  'printf "called\\n" >> "$DOCTOR_TEST_WINDOWS_CALL_LOG"' \
  'state=$(cat "$DOCTOR_TEST_WINDOWS_COMMAND_STATE")' \
  'if [[ $state == hang ]]; then sleep 30; exit 0; fi' \
  'exit "$state"' >> "$windows_command"
chmod +x "$wslview_source" "$windows_command"

ln -s "$current_generation" "$test_root/current"
ln -s "$current_generation" "$test_root/booted"
ln -s "$current_generation" "$test_root/profile"

printf '#!%s\n' "$store_bash" > "$fake_bin/systemctl"
printf '%s\n' \
  'case "${1-}" in' \
  '  show)' \
  '    unit=${2-}' \
  '    printf "%s\\n" "$unit" >> "$DOCTOR_TEST_SYSTEMCTL_CALL_LOG"' \
  '    row=$(awk -F "|" -v unit="$unit" '\''$1 == unit { print; exit }'\'' "$DOCTOR_TEST_UNIT_STATE")' \
  '    [[ -n $row ]] || exit 1' \
  '    IFS="|" read -r _ load active sub result <<< "$row"' \
  '    [[ $load != hang ]] || { sleep 30; exit 0; }' \
  '    printf "LoadState=%s\\nActiveState=%s\\nSubState=%s\\nResult=%s\\n" "$load" "$active" "$sub" "$result"' \
  '    ;;' \
  '  is-active) exit 0 ;;' \
  '  is-failed) exit 1 ;;' \
  '  status) exit 0 ;;' \
  'esac' >> "$fake_bin/systemctl"

printf '#!%s\n' "$store_bash" > "$fake_bin/dotfiles-wsl-restart-required"
printf '%s\n' \
  '[[ $# -eq 6 ]] || exit 2' \
  '[[ $1 == --plan ]] || exit 2' \
  '[[ $2 == --booted-system && $3 == "$DOCTOR_TEST_BOOTED_SYSTEM" ]] || exit 2' \
  '[[ $4 == --current-system && $5 == "$DOCTOR_TEST_CURRENT_SYSTEM" ]] || exit 2' \
  '[[ $6 == "$DOCTOR_TEST_CURRENT_SYSTEM" ]] || exit 2' \
  'cat "$DOCTOR_TEST_EFFECT_STATE"' >> "$fake_bin/dotfiles-wsl-restart-required"

printf '#!%s\n' "$store_bash" > "$fake_bin/sudo"
printf '%s\n' \
  '[[ ${1-} == -n && ${2-} == -- ]] || exit 2' \
  'shift 2' \
  '[[ $# -eq 1 && $1 == "$DOCTOR_TEST_ROOT_PROBE" ]] || exit 2' \
  'printf "called\\n" >> "$DOCTOR_TEST_SUDO_CALL_LOG"' \
  'exec "$1"' >> "$fake_bin/sudo"

printf '#!%s\n' "$store_bash" > "$root_probe"
printf '%s\n' \
  '[[ $# -eq 0 ]] || exit 2' \
  'state=$(cat "$DOCTOR_TEST_ROOT_STATE")' \
  '[[ $state != hang ]] || { sleep 30; exit 0; }' \
  'printf "%s\\n" "$state"' >> "$root_probe"

cat > "$docker_command" <<'DOCKER'
#!@STORE_BASH@
set -euo pipefail

[[ $# -eq 3 && ($1:$2 == image:inspect || $1:$2 == container:inspect) ]] || exit 64
kind=$1
subject=$3
printf '%s %s\n' "$kind" "$subject" >> "$DOCTOR_TEST_DOCKER_CALL_LOG"
if [[ "$kind:$subject" == "${DOCTOR_TEST_DOCKER_LOCK_PROBE:-}" ]]; then
  exec {probe_lock_fd}> "$DOCTOR_TEST_OCI_STATE_ROOT/operation.lock"
  if flock --exclusive --nonblock "$probe_lock_fd"; then
    printf '%s\n' acquired >> "$DOCTOR_TEST_DOCKER_LOCK_PROBE_LOG"
    flock --unlock "$probe_lock_fd"
  else
    printf '%s\n' blocked >> "$DOCTOR_TEST_DOCKER_LOCK_PROBE_LOG"
  fi
  exec {probe_lock_fd}>&-
fi
if jq -e --arg kind "$kind" --arg subject "$subject" '
  any(.hang[$kind][]?; . == $subject)
' "$DOCTOR_TEST_DOCKER_STATE" >/dev/null; then
  sleep 30
  exit 0
fi
jq -e --arg kind "$kind" --arg subject "$subject" '
  if .[$kind] | has($subject) then [.[$kind][$subject]] else empty end
' "$DOCTOR_TEST_DOCKER_STATE"
DOCKER
sed -i "1s|@STORE_BASH@|$store_bash|" "$docker_command"

printf '#!%s\n' "$store_bash" > "$sync_status_command"
printf '%s\n' \
  '[[ $# -eq 1 && $1 == --status ]] || exit 64' \
  'printf "status\\n" >> "$DOCTOR_TEST_SYNC_STATUS_CALL_LOG"' \
  'exit "$(cat "$DOCTOR_TEST_SYNC_STATUS_STATE")"' >> "$sync_status_command"

cat > "$fake_bin/curl" <<'EOF'
#!@STORE_BASH@
set -euo pipefail

method=GET
headers_file=
body_file=
data=
request_url=
max_time=
max_filesize=
declare -a headers=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --request|-X)
      method=$2
      shift 2
      ;;
    --dump-header)
      headers_file=$2
      shift 2
      ;;
    --output)
      body_file=$2
      shift 2
      ;;
    --data|--data-raw)
      data=$2
      shift 2
      ;;
    --header|-H)
      headers+=("$2")
      shift 2
      ;;
    --max-time)
      max_time=$2
      shift 2
      ;;
    --max-filesize)
      max_filesize=$2
      shift 2
      ;;
    --write-out)
      shift 2
      ;;
    --silent|--show-error)
      shift
      ;;
    http://*|https://*)
      request_url=$1
      shift
      ;;
    *)
      printf 'unexpected curl argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

[[ $request_url == "$DOCTOR_TEST_MCP_URL" ]] || {
  printf 'unexpected MCP URL: %s\n' "$request_url" >&2
  exit 2
}
case ",$DOCTOR_TEST_MCP_MAX_TIMES," in
  *",$max_time,"*) ;;
  *)
    printf 'unexpected MCP max time: %s\n' "$max_time" >&2
    exit 2
    ;;
esac
[[ $max_filesize == "$DOCTOR_TEST_MCP_MAX_FILESIZE" ]] || {
  printf 'unexpected MCP max filesize: %s\n' "$max_filesize" >&2
  exit 2
}

session=
version=
accept_count=0
content_type_count=0
for header in "${headers[@]}"; do
  [[ $header != 'Accept: application/json, text/event-stream' ]] || accept_count=$((accept_count + 1))
  [[ $header != 'Content-Type: application/json' ]] || content_type_count=$((content_type_count + 1))
  case ${header,,} in
    mcp-session-id:*) session=${header#*:}; session=${session# } ;;
    mcp-protocol-version:*) version=${header#*:}; version=${version# } ;;
  esac
done

[[ $accept_count -eq 1 ]] || {
  printf 'expected exactly one MCP Accept header\n' >&2
  exit 2
}
if [[ $method == POST ]]; then
  [[ -n $data && $content_type_count -eq 1 ]] || {
    printf 'expected JSON Content-Type and payload for POST\n' >&2
    exit 2
  }
elif [[ $content_type_count -ne 0 ]]; then
  printf 'unexpected Content-Type for request without payload\n' >&2
  exit 2
fi

request_data=$data
[[ -n $request_data ]] || request_data='{}'
rpc_method=$(jq -r '.method // "delete"' <<< "$request_data")
printf '%s|%s\n' "$rpc_method" "$max_time" >> "$DOCTOR_TEST_MCP_TIMEOUT_LOG"
cursor_present=0
cursor='<absent>'
if jq -e '(.params | type) == "object" and (.params | has("cursor"))' \
  <<< "$request_data" >/dev/null; then
  cursor_present=1
  cursor=$(jq -r '.params.cursor' <<< "$request_data")
  [[ -n $cursor ]] || cursor='<empty>'
fi

case $rpc_method in
  initialize)
    jq -e --arg protocol "$DOCTOR_TEST_MCP_REQUESTED_PROTOCOL" '
      . == {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: $protocol,
          capabilities: {},
          clientInfo: {name: "dotfiles-doctor", version: "1"}
        }
      }
    ' <<< "$request_data" >/dev/null || exit 2
    ;;
  notifications/initialized)
    jq -e '. == {jsonrpc:"2.0",method:"notifications/initialized"}' \
      <<< "$request_data" >/dev/null || exit 2
    ;;
esac
printf '%s|%s|%s|%s|%s\n' \
  "$method" "$rpc_method" "$session" "$version" "$cursor" >> "$DOCTOR_TEST_MCP_CALL_LOG"

scenario=$(cat "$DOCTOR_TEST_MCP_SCENARIO")
if [[ $scenario == initialize-curl-failure && $rpc_method == initialize ]]; then
  exit 7
fi
if [[ $scenario == tools-timeout && $rpc_method == tools/list ]]; then
  sleep "$max_time"
  exit 28
fi
status=200
content_type=application/json
response_session=
body=

case "$rpc_method" in
  initialize)
    response_session=fixture-session
    protocol=2024-11-05
    response_id=1
    capabilities='{"tools":{}}'
    case $scenario in
      success-sse) content_type=text/event-stream ;;
      initialize-text-plain) content_type=text/plain ;;
      protocol-mismatch) protocol=2099-01-01 ;;
      initialize-id-mismatch) response_id=99 ;;
      initialize-capability-missing) capabilities='{}' ;;
      initialize-session-missing) response_session= ;;
    esac
    body=$(jq -cn \
      --argjson id "$response_id" \
      --arg protocol "$protocol" \
      --argjson capabilities "$capabilities" \
      '{jsonrpc:"2.0",id:$id,result:{protocolVersion:$protocol,capabilities:$capabilities}}')
    ;;
  notifications/initialized)
    status=202
    [[ $scenario != initialized-failure ]] || status=500
    if [[ $scenario == signal-on-initialized ]]; then
      kill -TERM "$PPID"
    elif [[ $scenario == interrupt-on-initialized ]]; then
      kill -INT "$PPID"
    fi
    ;;
  tools/list)
    case $scenario:$cursor_present:$cursor in
      success-sse:0:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"}],"nextCursor":"page-2"}}'
        ;;
      success-sse:1:page-2)
        content_type=text/event-stream
        body='{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"searxng_search"}]}}'
        ;;
      success-empty-cursor:0:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"}],"nextCursor":""}}'
        ;;
      success-empty-cursor:1:\<empty\>)
        body='{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"searxng_search"}]}}'
        ;;
      repeated-empty-cursor:0:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"}],"nextCursor":""}}'
        ;;
      repeated-empty-cursor:1:\<empty\>)
        body='{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"searxng_search"}],"nextCursor":""}}'
        ;;
      pagination-limit:0:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"}],"nextCursor":"page-2"}}'
        ;;
      response-too-large:*:*)
        printf -v large_tool_name '%0512d' 0
        body=$(jq -cn --arg name "memory_$large_tool_name" '{jsonrpc:"2.0",id:2,result:{tools:[{name:$name}]}}')
        ;;
      success-json:*:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"},{"name":"searxng_search"}]}}'
        ;;
      tools-malformed:*:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":"not-an-array"}}'
        ;;
      target-missing:*:*)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"}]}}'
        ;;
      *)
        body='{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_recall"},{"name":"searxng_search"}]}}'
        ;;
    esac
    ;;
  delete)
    status=202
    [[ $scenario != delete-failure ]] || status=500
    ;;
  *)
    status=400
    ;;
esac

{
  printf 'HTTP/1.1 %s Fixture\r\n' "$status"
  printf 'Content-Type: %s\r\n' "$content_type"
  [[ -z $response_session ]] || printf 'Mcp-Session-Id: %s\r\n' "$response_session"
  printf '\r\n'
} > "$headers_file"

if [[ $scenario == response-too-large && $rpc_method == tools/list && ${#body} -gt $max_filesize ]]; then
  printf '%.*s' "$max_filesize" "$body" > "$body_file"
  printf '%s' "$status"
  exit 63
fi

if [[ $content_type == text/event-stream && -n $body ]]; then
  if [[ $rpc_method == initialize ]]; then
    printf '%s\n' \
      'event: message' \
      'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}' \
      '' \
      'event: message' \
      'data: {"jsonrpc":"2.0",' \
      "data: \"id\":$response_id,\"result\":{\"protocolVersion\":\"$protocol\",\"capabilities\":$capabilities}}" \
      '' > "$body_file"
  elif [[ $rpc_method == tools/list && $cursor == page-2 ]]; then
    printf '%s\n' \
      'event: message' \
      'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}' \
      '' \
      'event: message' \
      'data: {"jsonrpc":"2.0",' \
      'data: "id":3,"result":{"tools":[{"name":"searxng_search"}]}}' \
      '' > "$body_file"
  else
    printf 'event: message\ndata: %s\n\n' "$body" > "$body_file"
  fi
else
  printf '%s' "$body" > "$body_file"
fi
printf '%s' "$status"
EOF
sed -i "s|@STORE_BASH@|$store_bash|" "$fake_bin/curl"

printf '#!%s\n' "$store_bash" > "$cli_path"
printf '%s\n' \
  '[[ ${1-} == --version ]] || exit 1' \
  'printf "called\\n" >> "$DOCTOR_TEST_CLI_CALL_LOG"' \
  'case $(cat "$DOCTOR_TEST_CLI_VERSION_STATE") in' \
  '  ok)' \
  '    printf "%s\\n" "fixture-cli 1.0.0"' \
  '    ;;' \
  '  output-fail)' \
  '    printf "%s\\n" "fixture-cli failed"' \
  '    exit 1' \
  '    ;;' \
  '  partial-hang)' \
  '    printf "%s\\n" "fixture-cli partial"' \
  '    sleep 10' \
  '    ;;' \
  '  switch-generation)' \
  '    ln -sfn "$DOCTOR_TEST_REPLACEMENT_GENERATION" "$DOCTOR_TEST_CURRENT_LINK"' \
  '    printf "%s\\n" "fixture-cli 1.0.0"' \
  '    ;;' \
  '  *) exit 1 ;;' \
  'esac' >> "$cli_path"

chmod +x \
  "$fake_bin/systemctl" \
  "$fake_bin/dotfiles-wsl-restart-required" \
  "$fake_bin/sudo" \
  "$fake_bin/curl" \
  "$docker_command" \
  "$sync_status_command" \
  "$root_probe" \
  "$cli_path"

awk -v library="$oci_image_state_source" '
  $0 == "@ociImageStateFunctions@" {
    while ((getline line < library) > 0) print line
    close(library)
    next
  }
  { print }
' "$doctor_source" | sed \
  -e "s|@doctorManifestPath@|$manifest|g" \
  -e 's|@doctorSchemaVersion@|4|g' \
  -e "s|@sudoCommand@|$fake_bin/sudo|g" \
  > "$rendered_doctor"
chmod +x "$rendered_doctor"
sed '/local id=\$1 phase=\$2 status=\$3 subject=\$4 expected=\$5 observed=\$6 message=\$7 duration=\$8/a\  message=' \
  "$rendered_doctor" > "$empty_message_doctor"
chmod +x "$empty_message_doctor"

write_manifest() {
  jq -n \
    --arg home "$home" \
    --arg user "$(id -un)" \
    --arg current "$test_root/current" \
    --arg booted "$test_root/booted" \
    --arg profile "$test_root/profile" \
    --arg root_probe "$root_probe" \
    --arg home_key "$home/.config/sops/age/keys.txt" \
    --arg unit "fixture.service" \
    --arg docker_unit "docker.service" \
    --arg upstream_unit "docker-image-a.service" \
    --arg nix_unit "docker-agentmemory.service" \
    --arg managed_path "$managed_runtime" \
    --arg managed_source "$managed_source" \
    --arg binary_path "$cli_path" \
    --arg rules_path "$rules_runtime" \
    --arg rules_source "$rules_source" \
    --arg skills_dir "$skills_dir" \
    --arg agents_dir "$agents_dir" \
    --arg wslview_path "$wslview_path" \
    --arg wslview_source "$wslview_source" \
    --arg windows_command "$windows_command" \
    --arg gateway_path "$gateway_runtime" \
    --arg gateway_source "$gateway_source" \
    --arg gateway_url 'http://127.0.0.1:1/mcp' \
    --arg nix_ld_path "$nix_ld_path" \
    --arg docker_command "$docker_command" \
    --arg sync_status_command "$sync_status_command" \
    --arg oci_state_root "$oci_state_root" \
    --arg nix_image_identity "$nix_image_identity" \
    --arg nix_image_file "$nix_image_file" \
    '{
      schemaVersion: 4,
      user: {name: $user, home: $home},
      generation: {current: $current, booted: $booted, profile: $profile},
      sops: {
        rootProbe: $root_probe,
        homeKey: {path: $home_key, policy: "warn"}
      },
      units: [
        {
          id: $unit,
          expected: {LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success"}
        },
        {
          id: $docker_unit,
          expected: {LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success"}
        },
        {
          id: $upstream_unit,
          expected: {LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success"}
        },
        {
          id: $nix_unit,
          expected: {LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success"}
        }
      ],
      managedFiles: [{id: "managed-fixture", path: $managed_path, source: $managed_source}],
      clis: [{
        name: "fixture",
        binaryName: "fixture-cli",
        binaryPath: $binary_path,
        rules: {path: $rules_path, source: $rules_source},
        skills: {directory: $skills_dir, names: ["fixture-skill"]},
        agents: {directory: $agents_dir, files: ["fixture-agent.md"]},
        gatewayFile: {path: $gateway_path, source: $gateway_source}
      }],
      mcp: {
        url: $gateway_url,
        healthUnit: $unit,
        targets: ["memory", "searxng"],
        requestedProtocolVersion: "2025-11-25",
        supportedProtocolVersions: ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
      },
      oci: {
        healthUnit: $docker_unit,
        stateRoot: $oci_state_root,
        dockerCommand: $docker_command,
        syncStatusCommand: $sync_status_command,
        images: [
          {
            id: "agentmemory", kind: "nix", container: "agentmemory", unit: $nix_unit,
            image: "agentmemory:fixture", repository: null, digest: null,
            imageFile: $nix_image_file,
            expectedImageIdFile: $nix_image_identity
          },
          {
            id: "image-a", kind: "upstream", container: "image-a", unit: $upstream_unit,
            image: "example.test/a:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            repository: "example.test/a",
            digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            imageFile: null,
            expectedImageIdFile: null
          }
        ]
      },
      probePolicy: {
        cliTimeoutSeconds: 5,
        systemTimeoutSeconds: 5,
        windowsTimeoutSeconds: 5,
        mcpRequestTimeoutSeconds: 5,
        mcpCleanupTimeoutSeconds: 5,
        totalTimeoutSeconds: 30,
        maxPages: 20,
        maxResponseBytes: 1048576
      },
      wslInterop: {
        launcherName: "wslview",
        launcherPath: $wslview_path,
        launcherSource: $wslview_source,
        windowsCommand: $windows_command
      },
      nixLdPath: $nix_ld_path
    }' > "$manifest"
}

reset_fixture() {
  doctor_executable=$rendered_doctor
  ln -sfn "$current_generation" "$test_root/current"
  ln -sfn "$current_generation" "$test_root/booted"
  ln -sfn "$current_generation" "$test_root/profile"
  ln -sfn "$rendered_doctor" "$current_generation/sw/bin/dotfiles-doctor"
  rm -f "$fake_bin/fixture-cli" "$fake_bin/wslview" "$home/.config/sops/age/keys.txt"
  mkdir -p "$skills_dir/fixture-skill" "$agents_dir" "$(dirname "$rules_runtime")"
  printf '%s\n' '# fixture skill' > "$skills_dir/fixture-skill/SKILL.md"
  printf '%s\n' '# fixture agent' > "$agent_file"
  ln -sfn "$wslview_source" "$wslview_path"
  chmod +x "$wslview_source" "$windows_command" "$root_probe"
  cp "$managed_source" "$managed_runtime"
  cp "$rules_source" "$rules_runtime"
  cp "$gateway_source" "$gateway_runtime"
  printf '%s\n' \
    'fixture.service|loaded|active|running|success' \
    'docker.service|loaded|active|running|success' \
    'docker-image-a.service|loaded|active|running|success' \
    'docker-agentmemory.service|loaded|active|running|success' > "$unit_state"
  printf '%s\n' 'switch' > "$effect_state"
  printf '%s\n' '{"directory":{"uid":0,"gid":0,"mode":"700"},"key":{"uid":0,"gid":0,"mode":"400"}}' > "$root_state"
  printf '%s\n' 'ok' > "$cli_version_state"
  printf '%s\n' '0' > "$windows_command_state"
  printf '%s\n' 'success-sse' > "$mcp_scenario"
  mcp_max_times=5
  mcp_max_filesize=1048576
  : > "$mcp_call_log"
  : > "$mcp_timeout_log"
  : > "$systemctl_call_log"
  : > "$sudo_call_log"
  : > "$cli_call_log"
  : > "$windows_call_log"
  : > "$docker_call_log"
  : > "$docker_lock_probe_log"
  : > "$sync_status_call_log"
  printf '%s\n' '0' > "$sync_status_state"
  docker_lock_probe=''
  rm -rf -- "$oci_state_root"
  mkdir -p "${oci_state_root%/*}"
  mkdir -m 0700 "$oci_state_root"
  mkdir -m 0700 "$oci_state_root/receipts"
  : > "$oci_state_root/operation.lock"
  chmod 0600 "$oci_state_root/operation.lock"
  jq -n '{
    image: {
      "agentmemory:fixture": {
        Id: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        RepoDigests: []
      },
      "example.test/a:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
        Id: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        RepoDigests: ["example.test/a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
      }
    },
    container: {
      agentmemory: {
        Image: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        State: {Running: true}
      },
      "image-a": {
        Image: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        State: {Running: true}
      }
    },
    hang: {image: [], container: []}
  }' > "$docker_state"
  touch "$nix_ld_path"
  doctor_path="$home/.local/bin:$current_generation/sw/bin:$fake_bin:$PATH"
  chmod +x "$cli_path"
  write_manifest
}

run_doctor() {
  local -a doctor_args=("$@")
  set +e
  HOME=$home \
    PATH="$doctor_path" \
    DOCTOR_TEST_UNIT_STATE=$unit_state \
    DOCTOR_TEST_EFFECT_STATE=$effect_state \
    DOCTOR_TEST_BOOTED_SYSTEM=$test_root/booted \
    DOCTOR_TEST_CURRENT_SYSTEM=$test_root/current \
    DOCTOR_TEST_ROOT_STATE=$root_state \
    DOCTOR_TEST_ROOT_PROBE=$root_probe \
    DOCTOR_TEST_CLI_VERSION_STATE=$cli_version_state \
    DOCTOR_TEST_CURRENT_LINK=$test_root/current \
    DOCTOR_TEST_REPLACEMENT_GENERATION=$profile_generation \
    DOCTOR_TEST_WINDOWS_COMMAND_STATE=$windows_command_state \
    DOCTOR_TEST_SYSTEMCTL_CALL_LOG=$systemctl_call_log \
    DOCTOR_TEST_SUDO_CALL_LOG=$sudo_call_log \
    DOCTOR_TEST_CLI_CALL_LOG=$cli_call_log \
    DOCTOR_TEST_WINDOWS_CALL_LOG=$windows_call_log \
    DOCTOR_TEST_MCP_SCENARIO=$mcp_scenario \
    DOCTOR_TEST_MCP_CALL_LOG=$mcp_call_log \
    DOCTOR_TEST_MCP_TIMEOUT_LOG=$mcp_timeout_log \
    DOCTOR_TEST_MCP_URL='http://127.0.0.1:1/mcp' \
    DOCTOR_TEST_MCP_REQUESTED_PROTOCOL='2025-11-25' \
    DOCTOR_TEST_MCP_MAX_TIMES=$mcp_max_times \
    DOCTOR_TEST_MCP_MAX_FILESIZE=$mcp_max_filesize \
    DOCTOR_TEST_DOCKER_CALL_LOG=$docker_call_log \
    DOCTOR_TEST_DOCKER_LOCK_PROBE=$docker_lock_probe \
    DOCTOR_TEST_DOCKER_LOCK_PROBE_LOG=$docker_lock_probe_log \
    DOCTOR_TEST_DOCKER_STATE=$docker_state \
    DOCTOR_TEST_OCI_STATE_ROOT=$oci_state_root \
    DOCTOR_TEST_SYNC_STATUS_CALL_LOG=$sync_status_call_log \
    DOCTOR_TEST_SYNC_STATUS_STATE=$sync_status_state \
    "$store_bash" "$doctor_executable" "${doctor_args[@]}" > "$doctor_output" 2>&1
  doctor_status=$?
  set -e
}

expect_failure() {
  local label=$1 expected=$2 mutation=$3
  reset_fixture
  "$mutation"
  run_doctor
  if [[ $doctor_status -ne 1 ]]; then
    echo "$label: expected status 1, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
}

expect_nix_identity_failure() {
  local label=$1 mutation=$2
  reset_fixture
  "$mutation"
  run_doctor --format json
  if [[ $doctor_status -ne 1 ]]; then
    echo "$label: expected status 1, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! jq -e '
    any(.checks[]; .id == "system.oci.image.agentmemory" and .status == "fail") and
    any(.checks[]; .id == "active.oci.container.agentmemory" and .status == "blocked") and
    any(.checks[]; .id == "system.oci.image.image-a" and .status == "pass") and
    any(.checks[]; .id == "active.oci.container.image-a" and .status == "pass")
  ' "$doctor_output" >/dev/null; then
    echo "$label: invalid identity did not fail the image and block its container" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif grep -Fqx 'container agentmemory' "$docker_call_log"; then
    echo "$label: blocked Nix container was inspected" >&2
    sed 's/^/  /' "$docker_call_log" >&2
    failed=1
  fi
}

expect_warning() {
  local label=$1 expected=$2 mutation=$3
  reset_fixture
  "$mutation"
  run_doctor
  if [[ $doctor_status -ne 0 ]]; then
    echo "$label: expected status 0, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
}

expect_contract_error() {
  local label=$1 expected=$2 mutation=$3
  reset_fixture
  "$mutation"
  run_doctor
  if [[ $doctor_status -ne 2 ]]; then
    echo "$label: expected status 2, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif [[ -s $systemctl_call_log || -s $sudo_call_log || -s $cli_call_log || -s $windows_call_log \
    || -s $mcp_call_log || -s $docker_call_log || -s $sync_status_call_log ]]; then
    echo "$label: a probe ran after manifest contract failure" >&2
    failed=1
  fi
}

expect_usage_error() {
  local label=$1
  shift
  reset_fixture
  run_doctor "$@"
  if [[ $doctor_status -ne 2 ]]; then
    echo "$label: expected status 2, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx 'usage: dotfiles-doctor [--format human|json]' "$doctor_output"; then
    echo "$label: missing usage diagnostic" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
}

expect_failure_with_deadline() {
  local label=$1 expected=$2 mutation=$3 max_seconds=$4 started elapsed
  reset_fixture
  "$mutation"
  started=$SECONDS
  run_doctor
  elapsed=$((SECONDS - started))
  if [[ $doctor_status -ne 1 ]]; then
    echo "$label: expected status 1, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif [[ $elapsed -gt $max_seconds ]]; then
    echo "$label: exceeded ${max_seconds}s deadline: ${elapsed}s" >&2
    failed=1
  fi
}

assert_mcp_call_log() {
  local label=$1 expected=$2 actual
  actual=$(cat "$mcp_call_log")
  if [[ $actual != "$expected" ]]; then
    echo "$label: MCP call log mismatch" >&2
    printf '  expected:\n%s\n  actual:\n%s\n' "$expected" "$actual" >&2
    failed=1
  fi
}

assert_reserved_cleanup_timeouts() {
  local label=$1
  if ! awk -F '|' '
    NR == 1 { valid = ($1 == "initialize" && ($2 == 1 || $2 == 2)) }
    NR == 2 { valid = valid && ($1 == "notifications/initialized" && ($2 == 1 || $2 == 2)) }
    NR == 3 { valid = valid && ($1 == "tools/list" && ($2 == 1 || $2 == 2)) }
    NR == 4 { valid = valid && ($1 == "delete" && $2 == 1) }
    END { exit !(NR == 4 && valid) }
  ' "$mcp_timeout_log"; then
    echo "$label: MCP timeout reservation mismatch" >&2
    sed 's/^/  /' "$mcp_timeout_log" >&2
    failed=1
  fi
}

expect_mcp_success() {
  local label=$1 scenario=$2 expected_calls=$3
  reset_fixture
  printf '%s\n' "$scenario" > "$mcp_scenario"
  run_doctor
  if [[ $doctor_status -ne 0 ]]; then
    echo "$label: expected status 0, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
  assert_mcp_call_log "$label" "$expected_calls"
}

expect_mcp_failure() {
  local label=$1 scenario=$2 expected_diagnostic=$3 expected_calls=$4 mutation=${5-} max_seconds=${6-}
  local started elapsed
  reset_fixture
  [[ -z $mutation ]] || "$mutation"
  printf '%s\n' "$scenario" > "$mcp_scenario"
  started=$SECONDS
  run_doctor
  elapsed=$((SECONDS - started))
  if [[ $doctor_status -ne 1 ]]; then
    echo "$label: expected status 1, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected_diagnostic" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected_diagnostic" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
  if [[ -n $max_seconds && $elapsed -gt $max_seconds ]]; then
    echo "$label: exceeded ${max_seconds}s deadline: ${elapsed}s" >&2
    failed=1
  fi
  assert_mcp_call_log "$label" "$expected_calls"
}

expect_mcp_signal_cleanup() {
  local label=$1 scenario=$2 expected_status=$3 expected_calls=$4
  reset_fixture
  printf '%s\n' "$scenario" > "$mcp_scenario"
  run_doctor
  if [[ $doctor_status -ne $expected_status ]]; then
    echo "$label: expected status $expected_status, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  fi
  assert_mcp_call_log "$label" "$expected_calls"
}

profile_mismatch() { ln -sfn "$profile_generation" "$test_root/profile"; }
schema_version_mismatch() { jq '.schemaVersion = 1' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
user_home_missing() { jq 'del(.user.home)' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
self_mismatch() { printf '#!%s\nexit 0\n' "$store_bash" > "$test_root/other-doctor"; chmod +x "$test_root/other-doctor"; ln -sfn "$test_root/other-doctor" "$current_generation/sw/bin/dotfiles-doctor"; }
effect_mismatch() { printf '%s\n' 'switch-restart' > "$effect_state"; }
unit_unloaded() { printf '%s\n' 'fixture.service|not-found|inactive|dead|failure' > "$unit_state"; }
unit_inactive() { printf '%s\n' 'fixture.service|loaded|failed|failed|exit-code' > "$unit_state"; }
unit_probe_failed() { : > "$unit_state"; }
unit_probe_timed_out() { printf '%s\n' 'fixture.service|hang|active|running|success' > "$unit_state"; }
sops_mode_mismatch() { printf '%s\n' '{"directory":{"uid":0,"gid":0,"mode":"755"},"key":{"uid":0,"gid":0,"mode":"400"}}' > "$root_state"; }
sops_probe_failed() { chmod -x "$root_probe"; }
sops_probe_timed_out() { printf '%s\n' 'hang' > "$root_state"; }
home_key_present() { mkdir -p "$(dirname "$home/.config/sops/age/keys.txt")"; touch "$home/.config/sops/age/keys.txt"; }
home_key_rejected() { home_key_present; jq '.sops.homeKey.policy = "reject"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
home_key_policy_invalid() { jq '.sops.homeKey.policy = "invalid"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
requested_protocol_unsupported() { jq '.mcp.requestedProtocolVersion = "2099-01-01"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
supported_protocol_duplicated() { jq '.mcp.supportedProtocolVersions += [.mcp.supportedProtocolVersions[-1]]' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
mcp_target_empty() { jq '.mcp.targets += [""]' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
cleanup_timeout_missing() { jq 'del(.probePolicy.mcpCleanupTimeoutSeconds)' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
cleanup_timeout_exhausts_budget() { jq '.probePolicy.mcpCleanupTimeoutSeconds = .probePolicy.totalTimeoutSeconds' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
managed_file_stale() { printf '%s\n' 'stale=true' > "$managed_runtime"; }
cli_path_shadowed() { ln -s "$cli_path" "$fake_bin/fixture-cli"; doctor_path="$fake_bin:$home/.local/bin:$current_generation/sw/bin:$PATH"; }
cli_not_executable() { chmod -x "$cli_path"; }
cli_version_failed() { printf '%s\n' 'fail' > "$cli_version_state"; }
cli_version_output_failed() { printf '%s\n' 'output-fail' > "$cli_version_state"; }
cli_version_timed_out() { printf '%s\n' 'partial-hang' > "$cli_version_state"; }
rules_file_stale() { printf '%s\n' '# stale rules' > "$rules_runtime"; }
skill_missing() { rm -f "$skills_dir/fixture-skill/SKILL.md"; }
agent_missing() { rm -f "$agent_file"; }
gateway_stale() { printf '%s\n' '{"mcp":"http://127.0.0.1:1/mcp","unexpected":true}' > "$gateway_runtime"; }
wslview_missing() { rm -f "$wslview_path"; }
wslview_shadowed() { ln -s "$wslview_source" "$fake_bin/wslview"; doctor_path="$fake_bin:$home/.local/bin:$current_generation/sw/bin:$PATH"; }
windows_command_missing() { chmod -x "$windows_command"; }
windows_command_failed() { printf '%s\n' '1' > "$windows_command_state"; }
windows_command_timed_out() { printf '%s\n' 'hang' > "$windows_command_state"; }
nix_ld_missing() { rm -f "$nix_ld_path"; }
current_unresolved() { jq --arg path "$test_root/generations/missing" '.generation.current = $path' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
configured_user_mismatch() { jq '.user.name = "different-user"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
generation_switch_during_active() { printf '%s\n' 'switch-generation' > "$cli_version_state"; }
mcp_page_limit_one() { jq '.probePolicy.maxPages = 1' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
mcp_response_limit_small() { jq '.probePolicy.maxResponseBytes = 256' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; mcp_max_filesize=256; }
mcp_total_budget_short() { jq '.probePolicy.totalTimeoutSeconds = 4 | .probePolicy.mcpCleanupTimeoutSeconds = 1' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; mcp_max_times=1,2; }
oci_missing() { jq 'del(.oci)' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
oci_duplicate_container() { jq '.oci.images[1].container = .oci.images[0].container' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
oci_unit_mismatch() { jq '.oci.images[1].unit = "docker-agentmemory.service"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
oci_nix_identity_missing() { jq 'del(.oci.images[0].expectedImageIdFile)' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
oci_nix_identity_noncanonical() { jq '.oci.images[0].expectedImageIdFile = "/nix/store/../tmp/identity.json"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
oci_state_missing() { rm -rf -- "$oci_state_root"; }
oci_sync_stale() { printf '%s\n' '1' > "$sync_status_state"; }
docker_unit_inactive() { sed -i 's/docker.service|loaded|active|running|success/docker.service|loaded|failed|failed|exit-code/' "$unit_state"; }
upstream_digest_missing() { jq '.image["example.test/a:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"].RepoDigests = []' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
nix_image_missing() { jq 'del(.image["agentmemory:fixture"])' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
nix_image_retagged() { jq '.image["agentmemory:fixture"].Id = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" | .container.agentmemory.Image = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
nix_identity_case() { local path; path=$(jq -er --arg case "$1" '.[$case]' "$nix_image_identity_cases"); jq --arg path "$path" '.oci.images[0].expectedImageIdFile = $path' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
nix_identity_malformed() { nix_identity_case malformed; }
nix_identity_schema_mismatch() { nix_identity_case schema; }
nix_identity_reference_mismatch() { nix_identity_case reference; }
nix_identity_image_file_mismatch() { nix_identity_case imageFile; }
nix_identity_invalid_id() { nix_identity_case imageId; }
upstream_container_mismatch() { jq '.container["image-a"].Image = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
upstream_container_stopped() { jq '.container["image-a"].State.Running = false' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
upstream_unit_inactive() { sed -i 's/docker-image-a.service|loaded|active|running|success/docker-image-a.service|loaded|failed|failed|exit-code/' "$unit_state"; }
upstream_image_timed_out() { jq '.hang.image = ["example.test/a:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }
upstream_container_timed_out() { jq '.hang.container = ["image-a"]' "$docker_state" > "$docker_state.tmp"; mv "$docker_state.tmp" "$docker_state"; }

reset_fixture
run_doctor
if [[ $doctor_status -ne 0 ]]; then
  echo "human baseline: expected status 0, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! grep -Fqx 'OK: MCP session lifecycle completed' "$doctor_output"; then
  echo 'human baseline: missing MCP lifecycle result' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ $(grep -Fxc 'fixture.service' "$systemctl_call_log") -ne 1 ]]; then
  echo 'human baseline: systemctl show was not called exactly once for fixture.service' >&2
  sed 's/^/  /' "$systemctl_call_log" >&2
  failed=1
fi

reset_fixture
run_doctor --format json
if [[ $doctor_status -ne 0 ]]; then
  echo "JSON baseline: expected status 0, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! jq -e '
  .schemaVersion == 1 and
  .manifestSchemaVersion == 4 and
  .outcome == "healthy" and
  (.summary | keys | sort) == ["blocked", "error", "fail", "pass", "total", "warn"] and
  (.checks | type) == "array" and
  (.checks | length) > 0 and
  all(.checks[];
    (.id | type) == "string" and
    (.phase == "foundation" or .phase == "local" or .phase == "system" or .phase == "active") and
    (.status == "pass" or .status == "warn" or .status == "fail" or .status == "error" or .status == "blocked") and
    (.subject | type) == "string" and
    has("expected") and
    has("observed") and
    (.message | type) == "string" and (.message | length) > 0 and
    (.durationMs | type) == "number" and .durationMs >= 0
  ) and
  ([.checks[].id] | length) == ([.checks[].id] | unique | length) and
  any(.checks[]; .id == "system.oci.lock" and .status == "pass") and
  any(.checks[]; .id == "system.oci.sync" and .status == "pass") and
  any(.checks[]; .id == "system.oci.image.agentmemory" and .status == "pass") and
  any(.checks[]; .id == "system.oci.image.image-a" and .status == "pass") and
  any(.checks[]; .id == "active.oci.container.agentmemory" and .status == "pass") and
  any(.checks[]; .id == "active.oci.container.image-a" and .status == "pass")
' "$doctor_output" >/dev/null; then
  echo 'JSON baseline: report contract mismatch' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

reset_fixture
doctor_executable=$empty_message_doctor
ln -sfn "$doctor_executable" "$current_generation/sw/bin/dotfiles-doctor"
run_doctor --format json
if [[ $doctor_status -ne 2 ]]; then
  echo "empty result message: expected status 2, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! jq -e '
  .outcome == "invalid" and
  any(.checks[];
    .id == "internal.report" and .status == "error" and
    (.message | type) == "string" and (.message | length) > 0
  )
' "$doctor_output" >/dev/null; then
  echo 'empty result message: internal contract error was not reported' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

expect_usage_error 'unknown argument' --unknown
expect_usage_error 'missing format value' --format
expect_usage_error 'unknown format' --format yaml
expect_usage_error 'extra positional argument' --format human extra

reset_fixture
schema_version_mismatch
run_doctor --format json
if [[ $doctor_status -ne 2 ]]; then
  echo "JSON contract error: expected status 2, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! jq -e '
  .schemaVersion == 1 and
  .outcome == "invalid" and
  any(.checks[]; .id == "foundation.manifest" and .status == "error")
' "$doctor_output" >/dev/null; then
  echo 'JSON contract error: invalid outcome/report mismatch' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

reset_fixture
current_unresolved
run_doctor
if [[ $doctor_status -ne 1 ]]; then
  echo "foundation gate: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif grep -Fq 'OK: system profile matches current generation' "$doctor_output"; then
  echo 'foundation gate: profile must not report OK when current is unresolved' >&2
  failed=1
elif ! grep -Fq 'SKIP:' "$doctor_output"; then
  echo 'foundation gate: blocked phases were not rendered' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ -s $systemctl_call_log || -s $sudo_call_log || -s $cli_call_log || -s $windows_call_log \
  || -s $mcp_call_log || -s $docker_call_log || -s $sync_status_call_log ]]; then
  echo 'foundation gate: an active probe ran after foundation failure' >&2
  failed=1
fi

reset_fixture
configured_user_mismatch
run_doctor
if [[ $doctor_status -ne 1 ]]; then
  echo "configured identity gate: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! grep -Fqx 'FAIL: doctor process identity does not match the configured user and home' "$doctor_output"; then
  echo 'configured identity gate: missing identity diagnostic' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ -s $systemctl_call_log || -s $sudo_call_log || -s $cli_call_log || -s $windows_call_log \
  || -s $mcp_call_log || -s $docker_call_log || -s $sync_status_call_log ]]; then
  echo 'configured identity gate: a probe ran with the wrong identity' >&2
  failed=1
fi

reset_fixture
docker_lock_probe=container:agentmemory
run_doctor --format json
if [[ $doctor_status -ne 0 ]]; then
  echo "OCI shared lock lifetime: expected status 0, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ $(cat "$docker_lock_probe_log") != blocked ]]; then
  echo 'OCI shared lock lifetime: exclusive lock was not blocked during container observation' >&2
  sed 's/^/  /' "$docker_lock_probe_log" >&2
  failed=1
else
  exec {post_doctor_lock_fd}> "$oci_state_root/operation.lock"
  if ! flock --exclusive --nonblock "$post_doctor_lock_fd"; then
    echo 'OCI shared lock lifetime: shared lock was not released after doctor completed' >&2
    failed=1
  else
    flock --unlock "$post_doctor_lock_fd"
  fi
  exec {post_doctor_lock_fd}>&-
fi

expect_failure \
  'generation changed during active probes' \
  'FAIL: generation snapshot changed during doctor execution' \
  generation_switch_during_active

reset_fixture
managed_file_stale
run_doctor --format json
if [[ $doctor_status -ne 1 ]]; then
  echo "JSON drift: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! jq -e '
  .outcome == "degraded" and
  any(.checks[]; .id == "local.managed.managed-fixture" and .status == "fail") and
  any(.checks[]; .id == "active.mcp.session" and .status == "pass")
' "$doctor_output" >/dev/null; then
  echo 'JSON drift: report did not complete after drift' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

expect_failure 'profile mismatch' 'FAIL: system profile does not match current generation' profile_mismatch
expect_contract_error 'schema version mismatch' "ERROR: doctor manifest does not match schema version 4: $manifest" schema_version_mismatch
expect_contract_error 'required user field missing' "ERROR: doctor manifest does not match schema version 4: $manifest" user_home_missing
expect_contract_error 'OCI inventory missing' "ERROR: doctor manifest does not match schema version 4: $manifest" oci_missing
expect_contract_error 'OCI container duplicated' "ERROR: doctor manifest does not match schema version 4: $manifest" oci_duplicate_container
expect_contract_error 'OCI unit mismatched' "ERROR: doctor manifest does not match schema version 4: $manifest" oci_unit_mismatch
expect_contract_error 'Nix OCI identity missing' "ERROR: doctor manifest does not match schema version 4: $manifest" oci_nix_identity_missing
expect_contract_error 'Nix OCI identity path noncanonical' "ERROR: doctor manifest does not match schema version 4: $manifest" oci_nix_identity_noncanonical
expect_failure 'self mismatch' 'FAIL: running doctor does not match current generation' self_mismatch
expect_failure 'cold-start mismatch' 'FAIL: WSL cold-start state requires switch-restart' effect_mismatch
expect_failure 'unit not loaded' 'FAIL: fixture.service state does not match manifest' unit_unloaded
expect_failure 'unit inactive' 'FAIL: fixture.service state does not match manifest' unit_inactive
expect_failure 'systemctl show failed' 'FAIL: fixture.service state does not match manifest' unit_probe_failed
expect_failure_with_deadline 'systemctl show timed out' 'FAIL: fixture.service state does not match manifest' unit_probe_timed_out 8

expect_failure 'OCI state missing' 'FAIL: OCI image sync state and lock are invalid' oci_state_missing

reset_fixture
exec {busy_oci_lock_fd}> "$oci_state_root/operation.lock"
flock --exclusive --nonblock "$busy_oci_lock_fd"
run_doctor --format json
flock --unlock "$busy_oci_lock_fd"
exec {busy_oci_lock_fd}>&-
if [[ $doctor_status -ne 1 ]]; then
  echo "OCI image sync lock busy: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ -s $docker_call_log || -s $sync_status_call_log ]]; then
  echo 'OCI image sync lock busy: a mutable OCI probe ran without the shared lock' >&2
  failed=1
elif ! jq -e '
  any(.checks[]; .id == "system.oci.lock" and .status == "blocked") and
  any(.checks[]; .id == "system.oci.sync" and .status == "blocked") and
  ([.checks[] | select(.id | startswith("system.oci.image."))] | length) == 2 and
  ([.checks[] | select(.id | startswith("active.oci.container."))] | length) == 2 and
  all(.checks[] | select(.id | startswith("system.oci.image.")); .status == "blocked") and
  all(.checks[] | select(.id | startswith("active.oci.container.")); .status == "blocked")
' "$doctor_output" >/dev/null; then
  echo 'OCI image sync lock busy: dependent OCI checks were not blocked' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

expect_failure 'OCI sync receipt stale' 'FAIL: upstream OCI image synchronization is stale' oci_sync_stale
expect_failure 'upstream OCI digest missing' 'FAIL: OCI image does not match the desired digest: image-a' upstream_digest_missing
expect_failure 'Nix OCI image missing' 'FAIL: OCI image does not match the immutable Nix image identity: agentmemory' nix_image_missing
expect_failure 'Nix OCI tag retargeted with matching container' 'FAIL: OCI image does not match the immutable Nix image identity: agentmemory' nix_image_retagged
expect_nix_identity_failure 'Nix OCI identity malformed' nix_identity_malformed
expect_nix_identity_failure 'Nix OCI identity schema mismatch' nix_identity_schema_mismatch
expect_nix_identity_failure 'Nix OCI identity reference mismatch' nix_identity_reference_mismatch
expect_nix_identity_failure 'Nix OCI identity imageFile mismatch' nix_identity_image_file_mismatch
expect_nix_identity_failure 'Nix OCI identity ID invalid' nix_identity_invalid_id
expect_failure 'upstream OCI container image mismatch' 'FAIL: OCI container does not run the desired image: image-a' upstream_container_mismatch
expect_failure 'upstream OCI container stopped' 'FAIL: OCI container does not run the desired image: image-a' upstream_container_stopped
expect_failure_with_deadline 'upstream OCI image inspect timed out' 'FAIL: OCI image does not match the desired digest: image-a' upstream_image_timed_out 8
expect_failure_with_deadline 'upstream OCI container inspect timed out' 'FAIL: OCI container does not run the desired image: image-a' upstream_container_timed_out 8

reset_fixture
docker_unit_inactive
run_doctor --format json
if [[ $doctor_status -ne 1 ]]; then
  echo "OCI Docker health gate: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ -s $docker_call_log || -s $sync_status_call_log ]]; then
  echo 'OCI Docker health gate: Docker or sync status was called for an unhealthy daemon' >&2
  failed=1
elif ! jq -e '
  any(.checks[]; .id == "system.oci.image.image-a" and .status == "blocked") and
  any(.checks[]; .id == "active.oci.container.image-a" and .status == "blocked")
' "$doctor_output" >/dev/null; then
  echo 'OCI Docker health gate: dependent checks were not blocked' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

reset_fixture
upstream_unit_inactive
run_doctor --format json
if [[ $doctor_status -ne 1 ]]; then
  echo "OCI container unit gate: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif ! grep -Fqx 'image example.test/a:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$docker_call_log"; then
  echo 'OCI container unit gate: image cache was not inspected' >&2
  failed=1
elif grep -Fqx 'container image-a' "$docker_call_log"; then
  echo 'OCI container unit gate: unhealthy container was inspected' >&2
  failed=1
elif ! jq -e 'any(.checks[]; .id == "active.oci.container.image-a" and .status == "blocked")' "$doctor_output" >/dev/null; then
  echo 'OCI container unit gate: container check was not blocked' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi

reset_fixture
unit_inactive
run_doctor
if [[ $doctor_status -ne 1 ]]; then
  echo "MCP health gate: expected status 1, got $doctor_status" >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
elif [[ -s $mcp_call_log ]]; then
  echo 'MCP health gate: session was created for an unhealthy unit' >&2
  sed 's/^/  /' "$mcp_call_log" >&2
  failed=1
elif ! grep -Fqx 'SKIP: MCP session is blocked by its health unit' "$doctor_output"; then
  echo 'MCP health gate: missing blocked MCP result' >&2
  sed 's/^/  /' "$doctor_output" >&2
  failed=1
fi
expect_failure 'SOPS metadata mismatch' 'FAIL: SOPS host key metadata does not match root policy' sops_mode_mismatch
expect_failure 'SOPS root probe failed' 'FAIL: SOPS host key metadata does not match root policy' sops_probe_failed
expect_failure_with_deadline 'SOPS root probe timed out' 'FAIL: SOPS host key metadata does not match root policy' sops_probe_timed_out 8
expect_warning 'home key migration warning' 'WARN: user SOPS age key still exists during migration' home_key_present
expect_failure 'home key rejected' 'FAIL: user SOPS age key must not exist after migration' home_key_rejected
expect_contract_error 'home key policy invalid' "ERROR: doctor manifest does not match schema version 4: $manifest" home_key_policy_invalid
expect_contract_error 'requested MCP protocol unsupported' "ERROR: doctor manifest does not match schema version 4: $manifest" requested_protocol_unsupported
expect_contract_error 'supported MCP protocol duplicated' "ERROR: doctor manifest does not match schema version 4: $manifest" supported_protocol_duplicated
expect_contract_error 'empty MCP target' "ERROR: doctor manifest does not match schema version 4: $manifest" mcp_target_empty
expect_contract_error 'MCP cleanup timeout missing' "ERROR: doctor manifest does not match schema version 4: $manifest" cleanup_timeout_missing
expect_contract_error 'MCP cleanup timeout exhausts total budget' "ERROR: doctor manifest does not match schema version 4: $manifest" cleanup_timeout_exhausts_budget
expect_failure 'managed file stale' "FAIL: managed file is stale: $managed_runtime" managed_file_stale
expect_failure 'CLI path shadowed' "FAIL: fixture-cli does not resolve to $cli_path" cli_path_shadowed
expect_failure 'CLI not executable' "FAIL: CLI is not executable: $cli_path" cli_not_executable
expect_failure 'CLI version failed' 'FAIL: fixture-cli version check failed' cli_version_failed
expect_failure 'CLI version output then failed' 'FAIL: fixture-cli version check failed' cli_version_output_failed
expect_failure 'CLI version timed out' 'FAIL: fixture-cli version check failed' cli_version_timed_out
expect_failure 'rules file stale' "FAIL: fixture rules file is stale: $rules_runtime" rules_file_stale
expect_failure 'skill missing' "FAIL: fixture skill is missing: $skills_dir/fixture-skill/SKILL.md" skill_missing
expect_failure 'agent missing' "FAIL: fixture agent is missing: $agent_file" agent_missing
expect_failure 'gateway stale' "FAIL: fixture gateway file is stale: $gateway_runtime" gateway_stale
expect_failure 'wslview missing' "FAIL: WSL launcher is missing or stale: $wslview_path" wslview_missing
expect_failure 'wslview shadowed' "FAIL: wslview does not resolve to $wslview_path" wslview_shadowed
expect_failure 'Windows command missing' "FAIL: Windows interop command is not executable: $windows_command" windows_command_missing
expect_failure 'Windows interop probe failed' "FAIL: Windows interop probe failed: $windows_command" windows_command_failed
expect_failure_with_deadline 'Windows interop probe timed out' "FAIL: Windows interop probe failed: $windows_command" windows_command_timed_out 8
expect_failure 'nix-ld missing' "FAIL: nix-ld dynamic linker path is missing: $nix_ld_path" nix_ld_missing

initialize_call='POST|initialize|||<absent>'
initialized_call='POST|notifications/initialized|fixture-session|2024-11-05|<absent>'
tools_call='POST|tools/list|fixture-session|2024-11-05|<absent>'
delete_call='DELETE|delete|fixture-session|2024-11-05|<absent>'

expect_mcp_success \
  'MCP SSE lifecycle with pagination' \
  success-sse \
  "$initialize_call
$initialized_call
$tools_call
POST|tools/list|fixture-session|2024-11-05|page-2
$delete_call"

expect_mcp_success \
  'MCP JSON lifecycle' \
  success-json \
"$initialize_call
$initialized_call
$tools_call
$delete_call"

expect_mcp_success \
  'MCP empty cursor pagination' \
  success-empty-cursor \
  "$initialize_call
$initialized_call
$tools_call
POST|tools/list|fixture-session|2024-11-05|<empty>
$delete_call"

expect_mcp_failure \
  'MCP protocol mismatch' \
  protocol-mismatch \
  'FAIL: MCP negotiated unsupported protocol version: 2099-01-01' \
  "$initialize_call
DELETE|delete|fixture-session|2099-01-01|<absent>"

expect_mcp_failure \
  'MCP initialize id mismatch' \
  initialize-id-mismatch \
  'FAIL: MCP initialize response has an invalid JSON-RPC envelope' \
  "$initialize_call
$delete_call"

expect_mcp_failure \
  'MCP initialize capability missing' \
  initialize-capability-missing \
  'FAIL: MCP initialize response does not advertise tools capability' \
  "$initialize_call
$delete_call"

expect_mcp_failure \
  'MCP initialize session missing' \
  initialize-session-missing \
  'FAIL: MCP initialize response is missing a session ID' \
  "$initialize_call"

expect_mcp_failure \
  'MCP initialize content type unsupported' \
  initialize-text-plain \
  'FAIL: MCP initialize response has unsupported content type: text/plain' \
  "$initialize_call
DELETE|delete|fixture-session|2025-11-25|<absent>"

expect_mcp_failure \
  'MCP initialized notification failure' \
  initialized-failure \
  'FAIL: MCP initialized notification failed with HTTP 500' \
  "$initialize_call
$initialized_call
$delete_call"

expect_mcp_failure \
  'MCP malformed tools response' \
  tools-malformed \
  'FAIL: MCP tools/list response is invalid' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call"

expect_mcp_failure \
  'MCP target missing' \
  target-missing \
  'FAIL: MCP target has no tools: searxng' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call"

expect_mcp_failure \
  'MCP DELETE failure' \
  delete-failure \
  'FAIL: MCP session cleanup failed with HTTP 500' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call"

expect_mcp_failure \
  'MCP initialize curl failure' \
  initialize-curl-failure \
  'FAIL: MCP initialize request failed' \
  "$initialize_call"

expect_mcp_failure \
  'MCP page limit' \
  pagination-limit \
  'FAIL: MCP tools/list pagination exceeded 1 pages' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call" \
  mcp_page_limit_one

expect_mcp_failure \
  'MCP response size limit' \
  response-too-large \
  'FAIL: MCP tools/list request failed' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call" \
  mcp_response_limit_small

expect_mcp_failure \
  'MCP total budget with reserved cleanup' \
  tools-timeout \
  'FAIL: MCP tools/list request failed' \
  "$initialize_call
$initialized_call
$tools_call
$delete_call" \
  mcp_total_budget_short \
  10
assert_reserved_cleanup_timeouts 'MCP total budget with reserved cleanup'

expect_mcp_failure \
  'MCP repeated empty cursor' \
  repeated-empty-cursor \
  'FAIL: MCP tools/list pagination cursor repeated' \
  "$initialize_call
$initialized_call
$tools_call
POST|tools/list|fixture-session|2024-11-05|<empty>
$delete_call"

expect_mcp_signal_cleanup \
  'MCP TERM cleanup' \
  signal-on-initialized \
  143 \
  "$initialize_call
$initialized_call
$delete_call"

expect_mcp_signal_cleanup \
  'MCP INT cleanup' \
  interrupt-on-initialized \
  130 \
  "$initialize_call
$initialized_call
$delete_call"

exit "$failed"
