#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 DOCTOR_SOURCE STORE_BASH" >&2
  exit 2
fi

doctor_source=$1
store_bash=$2
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

home=$test_root/home
current_generation=$test_root/generations/current
profile_generation=$test_root/generations/profile
manifest=$test_root/current/etc/dotfiles/doctor.json
fake_bin=$test_root/fake-bin
rendered_doctor=$test_root/doctor
doctor_output=$test_root/doctor-output
unit_state=$test_root/unit-state
effect_state=$test_root/effect-state
root_state=$test_root/root-state.json
cli_version_state=$test_root/cli-version-state
mcp_scenario=$test_root/mcp-scenario
mcp_call_log=$test_root/mcp-call-log
managed_source=$test_root/store/managed.conf
managed_runtime=$test_root/runtime/managed.conf
rules_source=$test_root/store/AGENTS.md
rules_runtime=$home/.fixture/AGENTS.md
gateway_runtime=$home/.fixture/gateway.json
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
failed=0

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
touch "$nix_ld_path"

printf '#!%s\nexit 0\n' "$store_bash" > "$wslview_source"
printf '#!%s\n' "$store_bash" > "$windows_command"
printf '%s\n' \
  '[[ $# -eq 4 ]] || exit 2' \
  '[[ $1 == /d && $2 == /c && $3 == exit && $4 == 0 ]] || exit 2' \
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
  '    property=' \
  '    for arg in "$@"; do [[ $arg == --property=* ]] && property=${arg#--property=}; done' \
  '    unit=${*: -1}' \
  '    row=$(awk -F "|" -v unit="$unit" '\''$1 == unit { print; exit }'\'' "$DOCTOR_TEST_UNIT_STATE")' \
  '    [[ -n $row ]] || exit 1' \
  '    IFS="|" read -r _ load active <<< "$row"' \
  '    [[ $property == LoadState ]] && printf "%s\\n" "$load" || printf "%s\\n" "$active"' \
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
  'exec "$1"' >> "$fake_bin/sudo"

printf '#!%s\n' "$store_bash" > "$root_probe"
printf '%s\n' \
  '[[ $# -eq 0 ]] || exit 2' \
  'cat "$DOCTOR_TEST_ROOT_STATE"' >> "$root_probe"

cat > "$fake_bin/curl" <<'EOF'
#!@STORE_BASH@
set -euo pipefail

method=GET
headers_file=
body_file=
data=
request_url=
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
    --max-time|--write-out)
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
  '  *) exit 1 ;;' \
  'esac' >> "$cli_path"

chmod +x \
  "$fake_bin/systemctl" \
  "$fake_bin/dotfiles-wsl-restart-required" \
  "$fake_bin/sudo" \
  "$fake_bin/curl" \
  "$root_probe" \
  "$cli_path"

sed \
  -e "s|@doctorManifestPath@|$manifest|g" \
  "$doctor_source" > "$rendered_doctor"
chmod +x "$rendered_doctor"

write_manifest() {
  jq -n \
    --arg home "$home" \
    --arg current "$test_root/current" \
    --arg booted "$test_root/booted" \
    --arg profile "$test_root/profile" \
    --arg root_probe "$root_probe" \
    --arg home_key "$home/.config/sops/age/keys.txt" \
    --arg unit "fixture.service" \
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
    --arg gateway_url 'http://127.0.0.1:1/mcp' \
    --arg nix_ld_path "$nix_ld_path" \
    '{
      schemaVersion: 2,
      user: {name: "fixture", home: $home},
      generation: {current: $current, booted: $booted, profile: $profile},
      sops: {
        rootProbe: $root_probe,
        homeKey: {path: $home_key, policy: "warn"}
      },
      units: [$unit],
      managedFiles: [{path: $managed_path, source: $managed_source}],
      clis: [{
        name: "fixture",
        binaryName: "fixture-cli",
        binaryPath: $binary_path,
        rules: {path: $rules_path, source: $rules_source},
        skills: {directory: $skills_dir, names: ["fixture-skill"]},
        agents: {directory: $agents_dir, files: ["fixture-agent.md"]},
        gatewayFile: {path: $gateway_path, contains: $gateway_url}
      }],
      mcp: {
        url: $gateway_url,
        targets: ["memory", "searxng"],
        requestedProtocolVersion: "2025-06-18",
        supportedProtocolVersions: ["2024-11-05", "2025-03-26", "2025-06-18"]
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
  ln -sfn "$current_generation" "$test_root/profile"
  ln -sfn "$rendered_doctor" "$current_generation/sw/bin/dotfiles-doctor"
  rm -f "$fake_bin/fixture-cli" "$fake_bin/wslview" "$home/.config/sops/age/keys.txt"
  mkdir -p "$skills_dir/fixture-skill" "$agents_dir" "$(dirname "$rules_runtime")"
  printf '%s\n' '# fixture skill' > "$skills_dir/fixture-skill/SKILL.md"
  printf '%s\n' '# fixture agent' > "$agent_file"
  ln -sfn "$wslview_source" "$wslview_path"
  chmod +x "$wslview_source" "$windows_command"
  cp "$managed_source" "$managed_runtime"
  cp "$rules_source" "$rules_runtime"
  printf '%s\n' '{"mcp":"http://127.0.0.1:1/mcp"}' > "$gateway_runtime"
  printf '%s\n' 'fixture.service|loaded|active' > "$unit_state"
  printf '%s\n' 'switch' > "$effect_state"
  printf '%s\n' '{"directory":{"uid":0,"gid":0,"mode":"700"},"key":{"uid":0,"gid":0,"mode":"400"}}' > "$root_state"
  printf '%s\n' 'ok' > "$cli_version_state"
  printf '%s\n' '0' > "$windows_command_state"
  printf '%s\n' 'success-sse' > "$mcp_scenario"
  : > "$mcp_call_log"
  touch "$nix_ld_path"
  doctor_path="$home/.local/bin:$current_generation/sw/bin:$fake_bin:$PATH"
  chmod +x "$cli_path"
  write_manifest
}

run_doctor() {
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
    DOCTOR_TEST_WINDOWS_COMMAND_STATE=$windows_command_state \
    DOCTOR_TEST_MCP_SCENARIO=$mcp_scenario \
    DOCTOR_TEST_MCP_CALL_LOG=$mcp_call_log \
    DOCTOR_TEST_MCP_URL='http://127.0.0.1:1/mcp' \
    DOCTOR_TEST_MCP_REQUESTED_PROTOCOL='2025-06-18' \
    "$store_bash" "$rendered_doctor" > "$doctor_output" 2>&1
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
  local label=$1 scenario=$2 expected_diagnostic=$3 expected_calls=$4
  reset_fixture
  printf '%s\n' "$scenario" > "$mcp_scenario"
  run_doctor
  if [[ $doctor_status -ne 1 ]]; then
    echo "$label: expected status 1, got $doctor_status" >&2
    sed 's/^/  /' "$doctor_output" >&2
    failed=1
  elif ! grep -Fqx "$expected_diagnostic" "$doctor_output"; then
    echo "$label: missing diagnostic: $expected_diagnostic" >&2
    sed 's/^/  /' "$doctor_output" >&2
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
unit_unloaded() { printf '%s\n' 'fixture.service|not-found|inactive' > "$unit_state"; }
unit_inactive() { printf '%s\n' 'fixture.service|loaded|failed' > "$unit_state"; }
sops_mode_mismatch() { printf '%s\n' '{"directory":{"uid":0,"gid":0,"mode":"755"},"key":{"uid":0,"gid":0,"mode":"400"}}' > "$root_state"; }
home_key_present() { mkdir -p "$(dirname "$home/.config/sops/age/keys.txt")"; touch "$home/.config/sops/age/keys.txt"; }
home_key_rejected() { home_key_present; jq '.sops.homeKey.policy = "reject"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
home_key_policy_invalid() { jq '.sops.homeKey.policy = "invalid"' "$manifest" > "$manifest.tmp"; mv "$manifest.tmp" "$manifest"; }
managed_file_stale() { printf '%s\n' 'stale=true' > "$managed_runtime"; }
cli_path_shadowed() { ln -s "$cli_path" "$fake_bin/fixture-cli"; doctor_path="$fake_bin:$home/.local/bin:$current_generation/sw/bin:$PATH"; }
cli_not_executable() { chmod -x "$cli_path"; }
cli_version_failed() { printf '%s\n' 'fail' > "$cli_version_state"; }
cli_version_output_failed() { printf '%s\n' 'output-fail' > "$cli_version_state"; }
cli_version_timed_out() { printf '%s\n' 'partial-hang' > "$cli_version_state"; }
rules_file_stale() { printf '%s\n' '# stale rules' > "$rules_runtime"; }
skill_missing() { rm -f "$skills_dir/fixture-skill/SKILL.md"; }
agent_missing() { rm -f "$agent_file"; }
gateway_stale() { printf '%s\n' '{"mcp":"http://stale.invalid/mcp"}' > "$gateway_runtime"; }
wslview_missing() { rm -f "$wslview_path"; }
wslview_shadowed() { ln -s "$wslview_source" "$fake_bin/wslview"; doctor_path="$fake_bin:$home/.local/bin:$current_generation/sw/bin:$PATH"; }
windows_command_missing() { chmod -x "$windows_command"; }
windows_command_failed() { printf '%s\n' '1' > "$windows_command_state"; }
windows_command_timed_out() { printf '%s\n' 'hang' > "$windows_command_state"; }
nix_ld_missing() { rm -f "$nix_ld_path"; }

expect_failure 'profile mismatch' 'FAIL: system profile does not match current generation' profile_mismatch
expect_failure 'schema version mismatch' "FAIL: doctor manifest does not match schema version 2: $manifest" schema_version_mismatch
expect_failure 'required user field missing' "FAIL: doctor manifest does not match schema version 2: $manifest" user_home_missing
expect_failure 'self mismatch' 'FAIL: running doctor does not match current generation' self_mismatch
expect_failure 'cold-start mismatch' 'FAIL: WSL cold-start state requires switch-restart' effect_mismatch
expect_failure 'unit not loaded' 'FAIL: fixture.service LoadState is not loaded: not-found' unit_unloaded
expect_failure 'unit inactive' 'FAIL: fixture.service ActiveState is not active: failed' unit_inactive
expect_failure 'SOPS metadata mismatch' 'FAIL: SOPS host key metadata does not match root policy' sops_mode_mismatch
expect_warning 'home key migration warning' 'WARN: user SOPS age key still exists during migration' home_key_present
expect_failure 'home key rejected' 'FAIL: user SOPS age key must not exist after migration' home_key_rejected
expect_failure 'home key policy invalid' "FAIL: doctor manifest does not match schema version 2: $manifest" home_key_policy_invalid
expect_failure 'managed file stale' "FAIL: managed file is stale: $managed_runtime" managed_file_stale
expect_failure 'CLI path shadowed' "FAIL: fixture-cli does not resolve to $cli_path" cli_path_shadowed
expect_failure 'CLI not executable' "FAIL: CLI is not executable: $cli_path" cli_not_executable
expect_failure 'CLI version failed' 'FAIL: fixture-cli version check failed' cli_version_failed
expect_failure 'CLI version output then failed' 'FAIL: fixture-cli version check failed' cli_version_output_failed
expect_failure 'CLI version timed out' 'FAIL: fixture-cli version check failed' cli_version_timed_out
expect_failure 'rules file stale' "FAIL: fixture rules file is stale: $rules_runtime" rules_file_stale
expect_failure 'skill missing' "FAIL: fixture skill is missing: $skills_dir/fixture-skill/SKILL.md" skill_missing
expect_failure 'agent missing' "FAIL: fixture agent is missing: $agent_file" agent_missing
expect_failure 'gateway stale' "FAIL: fixture gateway file is missing or stale: $gateway_runtime" gateway_stale
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
DELETE|delete|fixture-session|2025-06-18|<absent>"

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
