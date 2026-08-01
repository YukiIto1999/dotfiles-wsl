set +e

@atomicFileFunctions@

@ociImageStateFunctions@

manifest_entry="@doctorManifestPath@"
manifest=''
manifest_schema_version="@doctorSchemaVersion@"
report_schema_version=1
format=human
sudo_command=@sudoCommand@

usage() {
  printf '%s\n' 'usage: dotfiles-doctor [--format human|json]' >&2
}

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || $1 != --format || ($2 != human && $2 != json) ]]; then
    usage
    exit 2
  fi
  format=$2
fi

report_tmp=$(mktemp -d)
checks_file="$report_tmp/checks.jsonl"
: > "$checks_file"

mcp_tmp=''
mcp_url=''
mcp_check_prefix=''
mcp_endpoint_json=''
mcp_session=''
mcp_cleanup_protocol=''
mcp_cleanup_done=0
mcp_request_number=0
mcp_phase_failed=0
contract_error=0
add_check_failed=0
check_sequence=0

now_ms() {
  date +%s%3N
}

duration_since() {
  local started=$1 finished
  finished=$(now_ms)
  printf '%s\n' "$((finished - started))"
}

add_check() {
  local id=$1 phase=$2 status=$3 subject=$4 expected=$5 observed=$6 message=$7 duration=$8
  local check_tmp check_json
  check_sequence=$((check_sequence + 1))
  check_tmp="$report_tmp/check-$check_sequence"
  check_json="$check_tmp/result.json"
  if ! mkdir -m 0700 -- "$check_tmp" ||
    ! printf '%s' "$id" > "$check_tmp/id" ||
    ! printf '%s' "$phase" > "$check_tmp/phase" ||
    ! printf '%s' "$status" > "$check_tmp/status" ||
    ! printf '%s' "$subject" > "$check_tmp/subject" ||
    ! printf '%s' "$expected" > "$check_tmp/expected" ||
    ! printf '%s' "$observed" > "$check_tmp/observed" ||
    ! printf '%s' "$message" > "$check_tmp/message" ||
    ! printf '%s' "$duration" > "$check_tmp/duration" ||
    ! jq -cn \
      --rawfile id "$check_tmp/id" \
      --rawfile phase "$check_tmp/phase" \
      --rawfile status "$check_tmp/status" \
      --rawfile subject "$check_tmp/subject" \
      --rawfile expected "$check_tmp/expected" \
      --rawfile observed "$check_tmp/observed" \
      --rawfile message "$check_tmp/message" \
      --rawfile durationMs "$check_tmp/duration" \
      '{id:$id,phase:$phase,status:$status,subject:$subject,expected:$expected,observed:$observed,message:$message,durationMs:($durationMs | tonumber)}' \
      > "$check_json" ||
    ! cat -- "$check_json" >> "$checks_file"; then
    add_check_failed=1
    contract_error=1
    return 1
  fi
}

stable_component() {
  jq -rn --arg component "$1" '$component | @uri'
}

render_output() {
  local outcome=$1 checks_json_file=$2 summary_json_file=$3 output_file=$4
  if [[ $format == json ]]; then
    jq -cn \
      --argjson schemaVersion "$report_schema_version" \
      --argjson manifestSchemaVersion "$manifest_schema_version" \
      --arg outcome "$outcome" \
      --slurpfile summary "$summary_json_file" \
      --slurpfile checks "$checks_json_file" \
      '{schemaVersion:$schemaVersion,manifestSchemaVersion:$manifestSchemaVersion,outcome:$outcome,summary:$summary[0],checks:$checks[0]}' \
      > "$output_file"
  else
    jq -r '.[] | (if .status == "pass" then "OK" elif .status == "warn" then "WARN" elif .status == "fail" then "FAIL" elif .status == "error" then "ERROR" else "SKIP" end) + ": " + .message' \
      "$checks_json_file" > "$output_file"
  fi
}

render_failure_report() {
  if [[ $format == json ]]; then
    printf '{"schemaVersion":%s,"manifestSchemaVersion":%s,"outcome":"invalid","summary":{"total":1,"pass":0,"warn":0,"fail":0,"error":1,"blocked":0},"checks":[{"id":"internal.report","phase":"foundation","status":"error","subject":"result-renderer","expected":"rendered report","observed":"failed","message":"doctor result report could not be rendered","durationMs":0}]}\n' \
      "$report_schema_version" "$manifest_schema_version"
  else
    printf '%s\n' 'ERROR: doctor result report could not be rendered'
  fi
}

render_report() {
  local forced_status=${1-} outcome exit_status internal_message
  local checks_json_file="$report_tmp/checks.json"
  local summary_json_file="$report_tmp/summary.json"
  local output_file="$report_tmp/report.out"
  if [[ $add_check_failed -eq 1 ]] ||
    ! jq -s '.' "$checks_file" > "$checks_json_file" || ! jq -e '
    type == "array" and length > 0 and
    all(.[];
      (.id | type) == "string" and (.id | length) > 0 and
      (.phase == "foundation" or .phase == "local" or .phase == "system" or .phase == "active") and
      (.status == "pass" or .status == "warn" or .status == "fail" or .status == "error" or .status == "blocked") and
      (.subject | type) == "string" and
      (.expected | type) == "string" and
      (.observed | type) == "string" and
      (.message | type) == "string" and (.message | length) > 0 and
      (.durationMs | type) == "number" and .durationMs >= 0 and (.durationMs | floor) == .durationMs
    ) and
    ([.[].id] | length) == ([.[].id] | unique | length)
  ' "$checks_json_file" >/dev/null 2>&1; then
    internal_message='doctor result core violates its internal contract'
    contract_error=1
    jq -n --arg message "$internal_message" '[{
      id:"internal.report",phase:"foundation",status:"error",subject:"result-core",
      expected:"valid unique checks",observed:"invalid",message:$message,durationMs:0
    }]' > "$checks_json_file"
  fi
  if ! jq '{
    total: length,
    pass: ([.[] | select(.status == "pass")] | length),
    warn: ([.[] | select(.status == "warn")] | length),
    fail: ([.[] | select(.status == "fail")] | length),
    error: ([.[] | select(.status == "error")] | length),
    blocked: ([.[] | select(.status == "blocked")] | length)
  }' "$checks_json_file" > "$summary_json_file"; then
    internal_message='doctor result summary could not be generated'
    contract_error=1
    if ! jq -n --arg message "$internal_message" '[{
      id:"internal.report",phase:"foundation",status:"error",subject:"result-core",
      expected:"valid summary",observed:"invalid",message:$message,durationMs:0
    }]' > "$checks_json_file" ||
      ! printf '%s\n' '{"total":1,"pass":0,"warn":0,"fail":0,"error":1,"blocked":0}' > "$summary_json_file"; then
      printf 'ERROR: %s\n' "$internal_message" >&2
      return 2
    fi
  fi

  if [[ $forced_status == 2 || $contract_error -eq 1 ]] || jq -e '.error > 0' "$summary_json_file" >/dev/null; then
    outcome=invalid
    exit_status=2
  elif jq -e '.fail > 0 or .blocked > 0' "$summary_json_file" >/dev/null; then
    outcome=degraded
    exit_status=1
  else
    outcome=healthy
    exit_status=0
  fi

  if ! render_output "$outcome" "$checks_json_file" "$summary_json_file" "$output_file"; then
    render_failure_report
    return 2
  fi
  cat -- "$output_file" || return 2
  return "$exit_status"
}

mcp_remove_temp() {
  if [[ -n $mcp_tmp ]]; then
    rm -rf -- "$mcp_tmp"
    mcp_tmp=''
  fi
}

# EXIT trap から関数名で呼び出す。
# shellcheck disable=SC2329
cleanup_all() {
  local status=$?
  if declare -F mcp_cleanup_session >/dev/null; then
    mcp_cleanup_session >/dev/null 2>&1
  fi
  dotfiles_oci_release_image_lock
  mcp_remove_temp
  rm -rf -- "$report_tmp"
  return "$status"
}

# INT / TERM trap から関数名で呼び出す。
# shellcheck disable=SC2329
signal_exit() {
  local status=$1
  trap - INT TERM
  if declare -F mcp_cleanup_session >/dev/null; then
    mcp_cleanup_session >/dev/null 2>&1
  fi
  dotfiles_oci_release_image_lock
  mcp_remove_temp
  rm -rf -- "$report_tmp"
  exit "$status"
}

trap cleanup_all EXIT
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

manifest_started=$(now_ms)
manifest=$(readlink -e -- "$manifest_entry" 2>/dev/null)
if [[ -z $manifest || ! -r $manifest ]]; then
  add_check \
    foundation.manifest foundation error "$manifest_entry" \
    "readable schema version $manifest_schema_version manifest" unreadable \
    "doctor manifest is not readable: $manifest_entry" \
    "$(duration_since "$manifest_started")"
  contract_error=1
  render_report 2
  exit $?
fi

# $schema などは shell 変数ではなく、--arg で渡す jq 変数。
# shellcheck disable=SC2016
manifest_contract='
  . as $root |
  ([.. | strings] | all(length <= 4096)) and
  .schemaVersion == ($schema | tonumber) and
  (.user.name | type) == "string" and
  (.user.home | type) == "string" and
  (.generation.current | type) == "string" and
  (.generation.booted | type) == "string" and
  (.generation.profile | type) == "string" and
  (.sops.rootProbe | type) == "string" and
  (.sops.homeKey.path | type) == "string" and
  (.sops.homeKey.policy == "warn" or .sops.homeKey.policy == "reject") and
  (.units | type) == "array" and
  all(.units[];
    (.id | type) == "string" and (.id | length) > 0 and
    (.expected | type) == "object" and
    (.expected.LoadState | type) == "string" and
    (.expected.ActiveState | type) == "string" and
    (.expected.SubState == null or (.expected.SubState | type) == "string") and
    (.expected.Result == null or (.expected.Result | type) == "string")
  ) and
  ([.units[].id] | length) == ([.units[].id] | unique | length) and
  (.managedFiles | type) == "array" and
  all(.managedFiles[];
    (.id | type) == "string" and (.id | length) > 0 and
    (.path | type) == "string" and
    (.source | type) == "string"
  ) and
  ([.managedFiles[].id] | length) == ([.managedFiles[].id] | unique | length) and
  (.clis | type) == "array" and
  all(.clis[];
    (.name | type) == "string" and (.name | length) > 0 and
    (.binaryName | type) == "string" and
    (.binaryPath | type) == "string" and
    (.rules.path | type) == "string" and
    (.rules.source | type) == "string" and
    (.skills.directory | type) == "string" and
    (.skills.names | type) == "array" and
    all(.skills.names[]; type == "string") and
    (.agents == null or (
      (.agents.directory | type) == "string" and
      (.agents.files | type) == "array" and
      all(.agents.files[]; type == "string")
    )) and
    (.gatewayFile == null or (
      (.gatewayFile.path | type) == "string" and
      (.gatewayFile.source | type) == "string"
    ))
  ) and
  ([.clis[].name] | length) == ([.clis[].name] | unique | length) and
  (.mcp.endpoints | type) == "array" and
  (.mcp.endpoints | length) > 0 and
  all(.mcp.endpoints[];
    (.id | type) == "string" and (.id | test("^[a-z0-9-]+$")) and
    (.url | type) == "string" and
    (.healthUnit | type) == "string" and
    (.targets | type) == "array" and
    all(.targets[]; type == "string" and length > 0) and
    ([.targets[]] | length) == ([.targets[]] | unique | length) and
    (.resources.properties | type) == "array" and
    (.resources.properties | length) > 0 and
    all(.resources.properties[]; type == "string" and test("^[A-Za-z]+$")) and
    ([.resources.properties[]] | length) == ([.resources.properties[]] | unique | length) and
    (.resources.properties | index("MainPID")) != null and
    (.resources.expected | type) == "object" and
    all(.resources.expected | to_entries[];
      (.key | type) == "string" and (.value | type) == "string" and (.value | test("^[0-9]+$"))
    ) and
    (.resources as $resources |
      all($resources.expected | keys[]; . as $key | $resources.properties | index($key) != null))
  ) and
  ([.mcp.endpoints[].id] | length) == ([.mcp.endpoints[].id] | unique | length) and
  ([.mcp.endpoints[].url] | length) == ([.mcp.endpoints[].url] | unique | length) and
  ([.mcp.endpoints[].targets[]] | length) == ([.mcp.endpoints[].targets[]] | unique | length) and
  (. as $manifest | all($manifest.mcp.endpoints[].healthUnit; . as $health | any($manifest.units[]; .id == $health))) and
  (.mcp.requestedProtocolVersion | type) == "string" and (.mcp.requestedProtocolVersion | length) > 0 and
  (.mcp.supportedProtocolVersions | type) == "array" and
  (.mcp.supportedProtocolVersions | length) > 0 and
  all(.mcp.supportedProtocolVersions[]; type == "string" and length > 0) and
  ([.mcp.supportedProtocolVersions[]] | length) == ([.mcp.supportedProtocolVersions[]] | unique | length) and
  (.mcp.requestedProtocolVersion as $requested | .mcp.supportedProtocolVersions | index($requested) != null) and
  .oci.healthUnit == "docker.service" and
  (.oci.healthUnit as $health | any(.units[]; .id == $health)) and
  .oci.stateRoot == (.user.home + "/.local/state/dotfiles-wsl/image-sync") and
  (.oci.stateRoot | contains("\n") | not) and
  (.oci.dockerCommand | type) == "string" and (.oci.dockerCommand | startswith("/")) and
  (.oci.dockerCommand | contains("\n") | not) and
  (.oci.syncStatusCommand | type) == "string" and (.oci.syncStatusCommand | startswith("/")) and
  (.oci.syncStatusCommand | contains("\n") | not) and
  (.oci.images | type) == "array" and (.oci.images | length) > 0 and
  ([.oci.images[].id] | length) == ([.oci.images[].id] | unique | length) and
  ([.oci.images[].container] | length) == ([.oci.images[].container] | unique | length) and
  ([.oci.images[].unit] | length) == ([.oci.images[].unit] | unique | length) and
  all(.oci.images[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
    (.container | type == "string" and test("^[a-z0-9][a-z0-9_.-]{0,62}$")) and
    .unit == ("docker-" + .container + ".service") and
    (.unit as $unit | any($root.units[]; .id == $unit)) and
    (.image | type == "string" and length > 0 and (contains("\n") | not)) and
    if .kind == "upstream" then
      (.repository | type == "string" and length > 0 and (contains("\n") | not)) and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.repository as $repository | .digest as $digest | .image |
        split("@") as $parts |
        ($parts | length) == 2 and $parts[1] == $digest and
        ($parts[0] == $repository or
          (($parts[0] | startswith($repository + ":")) and
            ($parts[0] | ltrimstr($repository + ":") |
              test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"))))) and
      .imageFile == null and .expectedImageIdFile == null
    elif .kind == "nix" then
      .repository == null and .digest == null and
      (.imageFile | type == "string" and test("^/nix/store/[0-9a-z]{32}-[^/\\n]+$")) and
      (.expectedImageIdFile | type == "string" and test("^/nix/store/[0-9a-z]{32}-[^/\\n]+$"))
    else false end
  ) and
  (.probePolicy | type) == "object" and
  all([
    .probePolicy.cliTimeoutSeconds,
    .probePolicy.systemTimeoutSeconds,
    .probePolicy.windowsTimeoutSeconds,
    .probePolicy.mcpRequestTimeoutSeconds,
    .probePolicy.mcpCleanupTimeoutSeconds,
    .probePolicy.totalTimeoutSeconds,
    .probePolicy.maxPages,
    .probePolicy.maxResponseBytes
  ][]; type == "number" and . > 0 and floor == .) and
  .probePolicy.mcpCleanupTimeoutSeconds < .probePolicy.totalTimeoutSeconds and
  (.wslInterop.launcherName | type) == "string" and
  (.wslInterop.launcherPath | type) == "string" and
  (.wslInterop.launcherSource | type) == "string" and
  (.wslInterop.windowsCommand | type) == "string" and
  (.nixLdPath | type) == "string"
'

if ! jq -e --arg schema "$manifest_schema_version" "$manifest_contract" "$manifest" >/dev/null 2>&1; then
  add_check \
    foundation.manifest foundation error "$manifest_entry" \
    "schema version $manifest_schema_version" invalid \
    "doctor manifest does not match schema version $manifest_schema_version: $manifest_entry" \
    "$(duration_since "$manifest_started")"
  contract_error=1
  render_report 2
  exit $?
fi
add_check \
  foundation.manifest foundation pass "$manifest_entry" \
  "schema version $manifest_schema_version" "schema version $manifest_schema_version" \
  "doctor manifest matches schema version $manifest_schema_version" \
  "$(duration_since "$manifest_started")"

current=$(jq -r '.generation.current' "$manifest")
booted=$(jq -r '.generation.booted' "$manifest")
profile=$(jq -r '.generation.profile' "$manifest")
foundation_failed=0

started=$(now_ms)
configured_user=$(jq -r '.user.name' "$manifest")
configured_home=$(jq -r '.user.home' "$manifest")
runtime_user=$(id -un 2>/dev/null)
runtime_home=${HOME-}
if [[ $runtime_user == "$configured_user" && $runtime_home == "$configured_home" ]]; then
  add_check foundation.identity foundation pass "$runtime_user:$runtime_home" \
    "$configured_user:$configured_home" "$runtime_user:$runtime_home" \
    "doctor process identity matches the configured user and home" "$(duration_since "$started")"
else
  add_check foundation.identity foundation fail "$runtime_user:$runtime_home" \
    "$configured_user:$configured_home" "$runtime_user:$runtime_home" \
    "doctor process identity does not match the configured user and home" "$(duration_since "$started")"
  foundation_failed=1
fi

started=$(now_ms)
current_canonical=$(readlink -e -- "$current" 2>/dev/null)
if [[ -z $current_canonical ]]; then
  add_check foundation.current foundation fail "$current" resolvable unresolved \
    "current generation cannot be resolved: $current" "$(duration_since "$started")"
  foundation_failed=1
else
  add_check foundation.current foundation pass "$current" resolvable "$current_canonical" \
    "current generation is resolvable" "$(duration_since "$started")"
fi

started=$(now_ms)
expected_manifest_canonical=''
if [[ -n $current_canonical ]]; then
  expected_manifest_canonical=$(readlink -e -- "$current_canonical/etc/dotfiles/doctor.json" 2>/dev/null)
fi
if [[ -z $current_canonical ]]; then
  add_check foundation.snapshot foundation blocked "$manifest_entry" current-generation-manifest unknown \
    "generation snapshot comparison is blocked because current generation is unresolved" \
    "$(duration_since "$started")"
elif [[ -z $expected_manifest_canonical || $manifest != "$expected_manifest_canonical" ]]; then
  add_check foundation.snapshot foundation fail "$manifest_entry" "$expected_manifest_canonical" "$manifest" \
    "doctor manifest does not belong to the resolved current generation" "$(duration_since "$started")"
  foundation_failed=1
else
  add_check foundation.snapshot foundation pass "$manifest_entry" "$expected_manifest_canonical" "$manifest" \
    "doctor manifest is pinned to the current generation" "$(duration_since "$started")"
fi

started=$(now_ms)
if [[ -z $current_canonical ]]; then
  add_check foundation.profile foundation blocked "$profile" "$current" unknown \
    "system profile comparison is blocked because current generation is unresolved" \
    "$(duration_since "$started")"
else
  profile_canonical=$(readlink -e -- "$profile" 2>/dev/null)
  if [[ -z $profile_canonical ]]; then
    add_check foundation.profile foundation fail "$profile" "$current_canonical" unresolved \
      "system profile cannot be resolved: $profile" "$(duration_since "$started")"
    foundation_failed=1
  elif [[ $profile_canonical != "$current_canonical" ]]; then
    add_check foundation.profile foundation fail "$profile" "$current_canonical" "$profile_canonical" \
      "system profile does not match current generation" "$(duration_since "$started")"
    foundation_failed=1
  else
    add_check foundation.profile foundation pass "$profile" "$current_canonical" "$profile_canonical" \
      "system profile matches current generation" "$(duration_since "$started")"
  fi
fi

started=$(now_ms)
running_canonical=$(readlink -e -- "$0" 2>/dev/null)
expected_doctor_canonical=''
if [[ -n $current_canonical ]]; then
  expected_doctor_canonical=$(readlink -e -- "$current/sw/bin/dotfiles-doctor" 2>/dev/null)
fi
if [[ -z $current_canonical ]]; then
  add_check foundation.self foundation blocked "$0" current-generation-doctor unknown \
    "running doctor comparison is blocked because current generation is unresolved" \
    "$(duration_since "$started")"
elif [[ -z $running_canonical ]]; then
  add_check foundation.self foundation fail "$0" "$expected_doctor_canonical" unresolved \
    "running doctor cannot be resolved: $0" "$(duration_since "$started")"
  foundation_failed=1
elif [[ -z $expected_doctor_canonical ]]; then
  add_check foundation.self foundation fail "$0" "$current/sw/bin/dotfiles-doctor" unresolved \
    "current generation doctor cannot be resolved: $current/sw/bin/dotfiles-doctor" \
    "$(duration_since "$started")"
  foundation_failed=1
elif [[ $running_canonical != "$expected_doctor_canonical" ]]; then
  add_check foundation.self foundation fail "$0" "$expected_doctor_canonical" "$running_canonical" \
    "running doctor does not match current generation" "$(duration_since "$started")"
  foundation_failed=1
else
  add_check foundation.self foundation pass "$0" "$expected_doctor_canonical" "$running_canonical" \
    "running doctor matches current generation" "$(duration_since "$started")"
fi

started=$(now_ms)
if [[ -z $current_canonical ]]; then
  add_check foundation.cold-start foundation blocked "$booted" switch unknown \
    "WSL cold-start classification is blocked because current generation is unresolved" \
    "$(duration_since "$started")"
else
  effect=$(dotfiles-wsl-restart-required \
    --plan \
    --booted-system "$booted" \
    --current-system "$current" \
    "$current" 2>/dev/null)
  effect_status=$?
  if [[ $effect_status -ne 0 || -z $effect ]]; then
    add_check foundation.cold-start foundation fail "$booted" switch unclassified \
      "WSL cold-start state could not be classified" "$(duration_since "$started")"
    foundation_failed=1
  elif [[ $effect != switch ]]; then
    add_check foundation.cold-start foundation fail "$booted" switch "$effect" \
      "WSL cold-start state requires $effect" "$(duration_since "$started")"
    foundation_failed=1
  else
    add_check foundation.cold-start foundation pass "$booted" switch "$effect" \
      "WSL cold-start state is current" "$(duration_since "$started")"
  fi
fi

if [[ $foundation_failed -ne 0 ]]; then
  add_check phase.local local blocked local foundation-pass blocked \
    "local checks are blocked by foundation drift" 0
  add_check phase.system system blocked system foundation-pass blocked \
    "system checks are blocked by foundation drift" 0
  add_check phase.active active blocked active foundation-pass blocked \
    "active checks are blocked by foundation drift" 0
  render_report
  exit $?
fi

# Local checks are pure comparisons against the manifest and current process environment.
while IFS= read -r managed_file; do
  id=$(jq -r '.id' <<< "$managed_file")
  path=$(jq -r '.path' <<< "$managed_file")
  source=$(jq -r '.source' <<< "$managed_file")
  component=$(stable_component "$id")
  started=$(now_ms)
  if cmp --silent -- "$path" "$source" 2>/dev/null; then
    add_check "local.managed.$component" local pass "$path" "$source" identical \
      "managed file is current: $path" "$(duration_since "$started")"
  else
    add_check "local.managed.$component" local fail "$path" "$source" different \
      "managed file is stale: $path" "$(duration_since "$started")"
  fi
done < <(jq -c '.managedFiles[]' "$manifest")

declare -A cli_executable=()
while IFS= read -r cli; do
  name=$(jq -r '.name' <<< "$cli")
  component=$(stable_component "$name")
  binary_name=$(jq -r '.binaryName' <<< "$cli")
  binary_path=$(jq -r '.binaryPath' <<< "$cli")

  started=$(now_ms)
  if [[ -x $binary_path ]]; then
    cli_executable[$name]=1
    add_check "local.cli.$component.executable" local pass "$binary_path" executable executable \
      "$name CLI is executable" "$(duration_since "$started")"
  else
    cli_executable[$name]=0
    add_check "local.cli.$component.executable" local fail "$binary_path" executable unavailable \
      "CLI is not executable: $binary_path" "$(duration_since "$started")"
  fi

  started=$(now_ms)
  resolved_binary=$(type -P -- "$binary_name" 2>/dev/null)
  if [[ $resolved_binary == "$binary_path" ]]; then
    add_check "local.cli.$component.path" local pass "$binary_name" "$binary_path" "$resolved_binary" \
      "$binary_name resolves to $binary_path" "$(duration_since "$started")"
  else
    add_check "local.cli.$component.path" local fail "$binary_name" "$binary_path" "${resolved_binary:-unresolved}" \
      "$binary_name does not resolve to $binary_path" "$(duration_since "$started")"
  fi

  rules_path=$(jq -r '.rules.path' <<< "$cli")
  rules_source=$(jq -r '.rules.source' <<< "$cli")
  started=$(now_ms)
  if cmp --silent -- "$rules_path" "$rules_source" 2>/dev/null; then
    add_check "local.cli.$component.rules" local pass "$rules_path" "$rules_source" identical \
      "$name rules file is current" "$(duration_since "$started")"
  else
    add_check "local.cli.$component.rules" local fail "$rules_path" "$rules_source" different \
      "$name rules file is stale: $rules_path" "$(duration_since "$started")"
  fi

  skills_directory=$(jq -r '.skills.directory' <<< "$cli")
  mapfile -t expected_skills < <(jq -r '.skills.names[]' <<< "$cli")
  missing_skills=()
  started=$(now_ms)
  for skill_name in "${expected_skills[@]}"; do
    [[ -f $skills_directory/$skill_name/SKILL.md ]] || missing_skills+=("$skills_directory/$skill_name/SKILL.md")
  done
  if [[ ${#missing_skills[@]} -eq 0 ]]; then
    add_check "local.cli.$component.skills" local pass "$skills_directory" "${#expected_skills[@]} deployed skills" complete \
      "$name skills are deployed" "$(duration_since "$started")"
  else
    add_check "local.cli.$component.skills" local fail "$skills_directory" "${#expected_skills[@]} deployed skills" "${missing_skills[*]}" \
      "$name skill is missing: ${missing_skills[0]}" "$(duration_since "$started")"
  fi

  agents_directory=$(jq -r '.agents.directory // empty' <<< "$cli")
  if [[ -n $agents_directory ]]; then
    mapfile -t expected_agents < <(jq -r '.agents.files[]' <<< "$cli")
    missing_agents=()
    started=$(now_ms)
    for agent_name in "${expected_agents[@]}"; do
      [[ -f $agents_directory/$agent_name ]] || missing_agents+=("$agents_directory/$agent_name")
    done
    if [[ ${#missing_agents[@]} -eq 0 ]]; then
      add_check "local.cli.$component.agents" local pass "$agents_directory" "${#expected_agents[@]} deployed agents" complete \
        "$name agents are deployed" "$(duration_since "$started")"
    else
      add_check "local.cli.$component.agents" local fail "$agents_directory" "${#expected_agents[@]} deployed agents" "${missing_agents[*]}" \
        "$name agent is missing: ${missing_agents[0]}" "$(duration_since "$started")"
    fi
  fi

  gateway_path=$(jq -r '.gatewayFile.path // empty' <<< "$cli")
  gateway_source=$(jq -r '.gatewayFile.source // empty' <<< "$cli")
  if [[ -n $gateway_path ]]; then
    started=$(now_ms)
    if cmp --silent -- "$gateway_path" "$gateway_source" 2>/dev/null; then
      add_check "local.cli.$component.gateway" local pass "$gateway_path" "$gateway_source" identical \
        "$name gateway file is current" "$(duration_since "$started")"
    else
      add_check "local.cli.$component.gateway" local fail "$gateway_path" "$gateway_source" different \
        "$name gateway file is stale: $gateway_path" "$(duration_since "$started")"
    fi
  fi
done < <(jq -c '.clis[]' "$manifest")

wsl_launcher_name=$(jq -r '.wslInterop.launcherName' "$manifest")
wsl_launcher_path=$(jq -r '.wslInterop.launcherPath' "$manifest")
wsl_launcher_source=$(jq -r '.wslInterop.launcherSource' "$manifest")
started=$(now_ms)
wsl_launcher_canonical=$(readlink -e -- "$wsl_launcher_path" 2>/dev/null)
wsl_launcher_source_canonical=$(readlink -e -- "$wsl_launcher_source" 2>/dev/null)
if [[ -x $wsl_launcher_path && -n $wsl_launcher_canonical && $wsl_launcher_canonical == "$wsl_launcher_source_canonical" ]]; then
  add_check local.wsl.launcher local pass "$wsl_launcher_path" "$wsl_launcher_source_canonical" "$wsl_launcher_canonical" \
    "WSL launcher is current: $wsl_launcher_path" "$(duration_since "$started")"
else
  add_check local.wsl.launcher local fail "$wsl_launcher_path" "$wsl_launcher_source_canonical" "${wsl_launcher_canonical:-unresolved}" \
    "WSL launcher is missing or stale: $wsl_launcher_path" "$(duration_since "$started")"
fi

started=$(now_ms)
resolved_wsl_launcher=$(type -P -- "$wsl_launcher_name" 2>/dev/null)
if [[ $resolved_wsl_launcher == "$wsl_launcher_path" ]]; then
  add_check local.wsl.path local pass "$wsl_launcher_name" "$wsl_launcher_path" "$resolved_wsl_launcher" \
    "$wsl_launcher_name resolves to $wsl_launcher_path" "$(duration_since "$started")"
else
  add_check local.wsl.path local fail "$wsl_launcher_name" "$wsl_launcher_path" "${resolved_wsl_launcher:-unresolved}" \
    "$wsl_launcher_name does not resolve to $wsl_launcher_path" "$(duration_since "$started")"
fi

nix_ld_path=$(jq -r '.nixLdPath' "$manifest")
started=$(now_ms)
if [[ -e $nix_ld_path ]]; then
  add_check local.nix-ld local pass "$nix_ld_path" exists exists \
    "nix-ld dynamic linker path exists" "$(duration_since "$started")"
else
  add_check local.nix-ld local fail "$nix_ld_path" exists missing \
    "nix-ld dynamic linker path is missing: $nix_ld_path" "$(duration_since "$started")"
fi

# System checks may require systemd or privilege, but are still bounded and deterministic.
system_timeout=$(jq -r '.probePolicy.systemTimeoutSeconds' "$manifest")
declare -A mcp_resource_flags=()
while IFS= read -r endpoint; do
  unit_id=$(jq -r '.healthUnit' <<< "$endpoint")
  flags=''
  while IFS= read -r property; do
    flags+=" --property=$property"
  done < <(jq -r '.resources.properties[]' <<< "$endpoint")
  mcp_resource_flags[$unit_id]=$flags
done < <(jq -c '.mcp.endpoints[]' "$manifest")
declare -A mcp_resource_observed=()
declare -A unit_check_status=()
while IFS= read -r unit; do
  unit_id=$(jq -r '.id' <<< "$unit")
  component=$(stable_component "$unit_id")
  expected_load=$(jq -r '.expected.LoadState' <<< "$unit")
  expected_active=$(jq -r '.expected.ActiveState' <<< "$unit")
  expected_sub=$(jq -r '.expected.SubState // empty' <<< "$unit")
  expected_result=$(jq -r '.expected.Result // empty' <<< "$unit")
  expected_state=$(jq -c '.expected' <<< "$unit")
  started=$(now_ms)
  unit_show_flags=(--property=LoadState --property=ActiveState --property=SubState --property=Result)
  if [[ -n ${mcp_resource_flags[$unit_id]:-} ]]; then
    read -r -a endpoint_resource_flags <<< "${mcp_resource_flags[$unit_id]}"
    unit_show_flags+=("${endpoint_resource_flags[@]}")
  fi
  unit_output=$(timeout "${system_timeout}s" systemctl show "$unit_id" \
    "${unit_show_flags[@]}" \
    --no-pager 2>/dev/null)
  unit_status=$?
  observed_load=''
  observed_active=''
  observed_sub=''
  observed_result=''
  while IFS= read -r property; do
    property_name=${property%%=*}
    property_value=${property#*=}
    case $property_name in
      LoadState) observed_load=$property_value ;;
      ActiveState) observed_active=$property_value ;;
      SubState) observed_sub=$property_value ;;
      Result) observed_result=$property_value ;;
      '') ;;
      *)
        if [[ -n ${mcp_resource_flags[$unit_id]:-} ]]; then
          mcp_resource_observed[$unit_id|$property_name]=$property_value
        fi
        ;;
    esac
  done <<< "$unit_output"
  observed_state=$(jq -cn \
    --arg LoadState "$observed_load" \
    --arg ActiveState "$observed_active" \
    --arg SubState "$observed_sub" \
    --arg Result "$observed_result" \
    '{LoadState:$LoadState,ActiveState:$ActiveState,SubState:$SubState,Result:$Result}')
  if [[ $unit_status -eq 0 && -n $observed_load && -n $observed_active \
    && $observed_load == "$expected_load" && $observed_active == "$expected_active" \
    && (-z $expected_sub || $observed_sub == "$expected_sub") \
    && (-z $expected_result || $observed_result == "$expected_result") ]]; then
    unit_check_status[$unit_id]=pass
    add_check "system.unit.$component" system pass "$unit_id" "$expected_state" "$observed_state" \
      "$unit_id state matches manifest" "$(duration_since "$started")"
  else
    unit_check_status[$unit_id]=fail
    add_check "system.unit.$component" system fail "$unit_id" "$expected_state" "$observed_state" \
      "$unit_id state does not match manifest" "$(duration_since "$started")"
  fi
done < <(jq -c '.units[]' "$manifest")

declare -A oci_image_check_status=()
declare -A oci_image_id=()
oci_health_unit=$(jq -r '.oci.healthUnit' "$manifest")
oci_state_root=$(jq -r '.oci.stateRoot' "$manifest")
oci_docker_command=$(jq -r '.oci.dockerCommand' "$manifest")
oci_sync_status_command=$(jq -r '.oci.syncStatusCommand' "$manifest")
oci_lock_state=invalid
started=$(now_ms)
if dotfiles_oci_validate_state_root "$oci_state_root" "$EUID" "$(id -g)"; then
  dotfiles_oci_acquire_image_lock "$oci_state_root" "$EUID" "$(id -g)" shared
  oci_lock_status=$?
  if [[ $oci_lock_status -eq 0 ]]; then
    oci_lock_state=acquired
    add_check system.oci.lock system pass "$oci_state_root" \
      shared-lock acquired "OCI image state is valid and shared lock was acquired" \
      "$(duration_since "$started")"
  elif [[ $oci_lock_status -eq 1 ]]; then
    oci_lock_state=busy
    add_check system.oci.lock system blocked "$oci_state_root" \
      shared-lock busy "OCI image checks are blocked by an active synchronization" \
      "$(duration_since "$started")"
  else
    add_check system.oci.lock system fail "$oci_state_root" \
      valid-lock invalid "OCI image sync state and lock are invalid" \
      "$(duration_since "$started")"
  fi
else
  add_check system.oci.lock system fail "$oci_state_root/operation.lock" \
    valid-state-tree invalid "OCI image sync state and lock are invalid" \
    "$(duration_since "$started")"
fi

oci_docker_healthy=${unit_check_status[$oci_health_unit]:-fail}
if [[ $oci_lock_state != acquired ]]; then
  add_check system.oci.sync system blocked "$oci_sync_status_command" synchronized blocked \
    "upstream OCI image synchronization check is blocked by the image state lock" 0
  while IFS= read -r oci_image; do
    oci_id=$(jq -r '.id' <<< "$oci_image")
    oci_component=$(stable_component "$oci_id")
    oci_image_check_status["$oci_id"]=blocked
    add_check "system.oci.image.$oci_component" system blocked "$oci_id" desired-image blocked \
      "OCI image check is blocked by the image state lock: $oci_id" 0
  done < <(jq -c '.oci.images[]' "$manifest")
elif [[ $oci_docker_healthy != pass ]]; then
  add_check system.oci.sync system blocked "$oci_sync_status_command" synchronized blocked \
    "upstream OCI image synchronization check is blocked by Docker health unit" 0
  while IFS= read -r oci_image; do
    oci_id=$(jq -r '.id' <<< "$oci_image")
    oci_component=$(stable_component "$oci_id")
    oci_image_check_status["$oci_id"]=blocked
    add_check "system.oci.image.$oci_component" system blocked "$oci_id" desired-image blocked \
      "OCI image check is blocked by Docker health unit: $oci_id" 0
  done < <(jq -c '.oci.images[]' "$manifest")
else
  started=$(now_ms)
  timeout "${system_timeout}s" "$oci_sync_status_command" --status >/dev/null 2>&1
  sync_status=$?
  if [[ $sync_status -eq 0 ]]; then
    add_check system.oci.sync system pass "$oci_sync_status_command" synchronized synchronized \
      "upstream OCI images match their synchronization receipts" "$(duration_since "$started")"
  else
    add_check system.oci.sync system fail "$oci_sync_status_command" synchronized "status-$sync_status" \
      "upstream OCI image synchronization is stale" "$(duration_since "$started")"
  fi

  while IFS= read -r oci_image; do
    oci_id=$(jq -r '.id' <<< "$oci_image")
    oci_kind=$(jq -r '.kind' <<< "$oci_image")
    oci_reference=$(jq -r '.image' <<< "$oci_image")
    oci_repository=$(jq -r '.repository // empty' <<< "$oci_image")
    oci_digest=$(jq -r '.digest // empty' <<< "$oci_image")
    oci_image_file=$(jq -r '.imageFile // empty' <<< "$oci_image")
    oci_expected_image_id_file=$(jq -r '.expectedImageIdFile // empty' <<< "$oci_image")
    oci_component=$(stable_component "$oci_id")
    started=$(now_ms)
    expected_nix_image_id=''
    expected_nix_image_status=1
    oci_expected_image_id_canonical=''
    if [[ $oci_kind == nix ]]; then
      oci_expected_image_id_canonical=$(readlink -e -- "$oci_expected_image_id_file" 2>/dev/null)
    fi
    if [[ $oci_kind == nix && $oci_expected_image_id_canonical == "$oci_expected_image_id_file" \
      && -f $oci_expected_image_id_file && ! -L $oci_expected_image_id_file ]]; then
      expected_nix_image_id=$(jq -er --slurp \
        --arg reference "$oci_reference" \
        --arg imageFile "$oci_image_file" '
          if length == 1 and
            .[0].schemaVersion == 1 and
            .[0].imageReference == $reference and
            .[0].imageFile == $imageFile and
            (.[0].imageId | type == "string" and test("^sha256:[0-9a-f]{64}$"))
          then .[0].imageId
          else error("invalid Nix image identity")
          end
        ' "$oci_expected_image_id_file" 2>/dev/null)
      expected_nix_image_status=$?
    fi
    image_inspect=$(timeout "${system_timeout}s" "$oci_docker_command" image inspect "$oci_reference" 2>/dev/null)
    image_inspect_status=$?
    desired_image_id=$(jq -er '
      if type == "array" and length == 1 then .[0].Id else error("expected one image") end |
      select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
    ' <<< "$image_inspect" 2>/dev/null)
    image_id_status=$?
    image_matches=0
    if [[ $image_inspect_status -eq 0 && $image_id_status -eq 0 ]]; then
      if [[ $oci_kind == upstream ]]; then
        expected_repo_digest="${oci_repository}@${oci_digest}"
        if jq -e --arg expected "$expected_repo_digest" '
          type == "array" and length == 1 and
          (.[0].RepoDigests | type) == "array" and
          (.[0].RepoDigests | index($expected)) != null
        ' <<< "$image_inspect" >/dev/null 2>&1; then
          image_matches=1
        fi
      elif [[ $expected_nix_image_status -eq 0 && $desired_image_id == "$expected_nix_image_id" ]]; then
        image_matches=1
      fi
    fi

    if [[ $image_matches -eq 1 ]]; then
      oci_image_check_status["$oci_id"]=pass
      oci_image_id["$oci_id"]=$desired_image_id
      add_check "system.oci.image.$oci_component" system pass "$oci_reference" desired-image "$desired_image_id" \
        "OCI image matches the desired source: $oci_id" "$(duration_since "$started")"
    else
      oci_image_check_status["$oci_id"]=fail
      if [[ $oci_kind == upstream ]]; then
        add_check "system.oci.image.$oci_component" system fail "$oci_reference" \
          "${oci_repository}@${oci_digest}" "status-$image_inspect_status" \
          "OCI image does not match the desired digest: $oci_id" "$(duration_since "$started")"
      else
        add_check "system.oci.image.$oci_component" system fail "$oci_reference" \
          "${expected_nix_image_id:-immutable-image-id}" \
          "${desired_image_id:-status-$image_inspect_status}" \
          "OCI image does not match the immutable Nix image identity: $oci_id" \
          "$(duration_since "$started")"
      fi
    fi
  done < <(jq -c '.oci.images[]' "$manifest")
fi

root_probe=$(jq -r '.sops.rootProbe' "$manifest")
started=$(now_ms)
root_metadata=$(timeout "${system_timeout}s" "$sudo_command" -n -- "$root_probe" 2>/dev/null)
root_probe_status=$?
if [[ $root_probe_status -eq 0 ]] && jq -e '
  .directory.uid == 0 and .directory.gid == 0 and .directory.mode == "700" and
  .key.uid == 0 and .key.gid == 0 and .key.mode == "400"
' <<< "$root_metadata" >/dev/null 2>&1; then
  add_check system.sops.root system pass "$root_probe" root-owned-0700-and-0400 "$root_metadata" \
    "SOPS host key metadata matches root policy" "$(duration_since "$started")"
else
  add_check system.sops.root system fail "$root_probe" root-owned-0700-and-0400 "${root_metadata:-unavailable}" \
    "SOPS host key metadata does not match root policy" "$(duration_since "$started")"
fi

home_key=$(jq -r '.sops.homeKey.path' "$manifest")
home_key_policy=$(jq -r '.sops.homeKey.policy' "$manifest")
started=$(now_ms)
if [[ -e $home_key || -L $home_key ]]; then
  if [[ $home_key_policy == reject ]]; then
    add_check system.sops.home system fail "$home_key" absent present \
      "user SOPS age key must not exist after migration" "$(duration_since "$started")"
  else
    add_check system.sops.home system warn "$home_key" absent present \
      "user SOPS age key still exists during migration" "$(duration_since "$started")"
  fi
else
  add_check system.sops.home system pass "$home_key" absent absent \
    "user SOPS age key is absent" "$(duration_since "$started")"
fi

# Active probes are deliberately sequential because they may share HOME and external state.
while IFS= read -r oci_image; do
  oci_id=$(jq -r '.id' <<< "$oci_image")
  oci_container=$(jq -r '.container' <<< "$oci_image")
  oci_unit=$(jq -r '.unit' <<< "$oci_image")
  oci_component=$(stable_component "$oci_id")
  started=$(now_ms)
  if [[ ${oci_image_check_status[$oci_id]:-blocked} != pass ]]; then
    add_check "active.oci.container.$oci_component" active blocked "$oci_container" desired-image blocked \
      "OCI container check is blocked because its image did not converge: $oci_id" \
      "$(duration_since "$started")"
    continue
  fi
  if [[ ${unit_check_status[$oci_unit]:-fail} != pass ]]; then
    add_check "active.oci.container.$oci_component" active blocked "$oci_container" running-desired-image blocked \
      "OCI container check is blocked by its systemd unit: $oci_unit" \
      "$(duration_since "$started")"
    continue
  fi

  container_inspect=$(timeout "${system_timeout}s" "$oci_docker_command" container inspect "$oci_container" 2>/dev/null)
  container_inspect_status=$?
  observed_container=$(jq -cer '
    if type == "array" and length == 1 then .[0] else error("expected one container") end |
    {
      image: (.Image | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))),
      running: (.State.Running | select(type == "boolean"))
    }
  ' <<< "$container_inspect" 2>/dev/null)
  observed_container_status=$?
  desired_image_id=${oci_image_id[$oci_id]}
  if [[ $container_inspect_status -eq 0 && $observed_container_status -eq 0 ]] \
    && jq -e --arg image "$desired_image_id" '.image == $image and .running == true' \
      <<< "$observed_container" >/dev/null 2>&1; then
    add_check "active.oci.container.$oci_component" active pass "$oci_container" \
      "running:$desired_image_id" "$observed_container" \
      "OCI container runs the desired image: $oci_id" "$(duration_since "$started")"
  else
    add_check "active.oci.container.$oci_component" active fail "$oci_container" \
      "running:$desired_image_id" "${observed_container:-status-$container_inspect_status}" \
      "OCI container does not run the desired image: $oci_id" "$(duration_since "$started")"
  fi
done < <(jq -c '.oci.images[]' "$manifest")
dotfiles_oci_release_image_lock

cli_timeout=$(jq -r '.probePolicy.cliTimeoutSeconds' "$manifest")
while IFS= read -r cli; do
  name=$(jq -r '.name' <<< "$cli")
  component=$(stable_component "$name")
  binary_name=$(jq -r '.binaryName' <<< "$cli")
  binary_path=$(jq -r '.binaryPath' <<< "$cli")
  started=$(now_ms)
  if [[ ${cli_executable[$name]:-0} -ne 1 ]]; then
    add_check "active.cli.$component.version" active blocked "$binary_path" nonempty-version unavailable \
      "$binary_name version check is blocked because the CLI is not executable" \
      "$(duration_since "$started")"
    continue
  fi
  version=$(timeout "${cli_timeout}s" "$binary_path" --version 2>/dev/null)
  version_status=$?
  if [[ $version_status -eq 0 && -n $version ]]; then
    add_check "active.cli.$component.version" active pass "$binary_path" nonempty-version "$version" \
      "$binary_name version check passed" "$(duration_since "$started")"
  else
    add_check "active.cli.$component.version" active fail "$binary_path" nonempty-version "status=$version_status" \
      "$binary_name version check failed" "$(duration_since "$started")"
  fi
done < <(jq -c '.clis[]' "$manifest")

windows_command=$(jq -r '.wslInterop.windowsCommand' "$manifest")
windows_timeout=$(jq -r '.probePolicy.windowsTimeoutSeconds' "$manifest")
started=$(now_ms)
if [[ ! -x $windows_command ]]; then
  add_check active.windows active fail "$windows_command" executable unavailable \
    "Windows interop command is not executable: $windows_command" "$(duration_since "$started")"
else
  timeout "${windows_timeout}s" "$windows_command" /d /c exit 0 >/dev/null 2>&1
  windows_probe_status=$?
  if [[ $windows_probe_status -eq 0 ]]; then
    add_check active.windows active pass "$windows_command" status-0 status-0 \
      "Windows interop probe passed" "$(duration_since "$started")"
  else
    add_check active.windows active fail "$windows_command" status-0 "status-$windows_probe_status" \
      "Windows interop probe failed: $windows_command" "$(duration_since "$started")"
  fi
fi

mcp_record_fail() {
  local id=$1 message=$2 expected=${3-healthy} observed=${4-failed} duration
  duration=$(duration_since "$mcp_check_started_ms")
  add_check "$id" active fail "$mcp_url" "$expected" "$observed" "$message" "$duration"
  mcp_phase_failed=1
}

mcp_request() {
  local method=$1 url=$2 payload=$3 session=$4 protocol=$5
  local -a curl_args
  local request_timeout cleanup_timeout remaining elapsed max_response payload_file

  request_timeout=$(jq -r '.probePolicy.mcpRequestTimeoutSeconds' "$manifest")
  cleanup_timeout=$(jq -r '.probePolicy.mcpCleanupTimeoutSeconds' "$manifest")
  max_response=$(jq -r '.probePolicy.maxResponseBytes' "$manifest")
  elapsed=$((SECONDS - mcp_started_seconds))
  remaining=$((mcp_total_timeout - elapsed))
  if [[ $mcp_cleanup_done -eq 1 ]]; then
    request_timeout=$cleanup_timeout
  else
    # 整数秒の境界をまたぐ scheduling 分も確保し、cleanup reserve を active request に渡さない。
    remaining=$((remaining - cleanup_timeout - 1))
  fi
  if [[ $remaining -le 0 ]]; then
    mcp_curl_status=124
    mcp_http_status=''
    return
  fi
  if [[ $remaining -lt $request_timeout ]]; then
    request_timeout=$remaining
  fi

  mcp_request_number=$((mcp_request_number + 1))
  mcp_headers_file="$mcp_tmp/headers-$mcp_request_number"
  mcp_body_file="$mcp_tmp/body-$mcp_request_number"
  curl_args=(
    --silent
    --show-error
    --max-time "$request_timeout"
    --max-filesize "$max_response"
    --request "$method"
    --header 'Accept: application/json, text/event-stream'
    --dump-header "$mcp_headers_file"
    --output "$mcp_body_file"
    --write-out '%{http_code}'
  )
  if [[ -n $payload ]]; then
    payload_file="$mcp_tmp/payload-$mcp_request_number"
    if ! printf '%s' "$payload" > "$payload_file"; then
      mcp_curl_status=74
      mcp_http_status=''
      return
    fi
    curl_args+=(--header 'Content-Type: application/json' --data-binary "@$payload_file")
  fi
  if [[ -n $session ]]; then
    curl_args+=(--header "Mcp-Session-Id: $session")
  fi
  if [[ -n $protocol ]]; then
    curl_args+=(--header "MCP-Protocol-Version: $protocol")
  fi
  curl_args+=("$url")

  mcp_http_status=$(curl "${curl_args[@]}")
  mcp_curl_status=$?
  mcp_response_session=''
  mcp_content_type=''
  mcp_response_json=''

  if [[ -r $mcp_headers_file ]]; then
    while IFS= read -r header_line; do
      header_line=${header_line%$'\r'}
      case ${header_line,,} in
        mcp-session-id:*) mcp_response_session=${header_line#*:}; mcp_response_session=${mcp_response_session# } ;;
        content-type:*) mcp_content_type=${header_line#*:}; mcp_content_type=${mcp_content_type# } ;;
      esac
    done < "$mcp_headers_file"
  fi
  if [[ $method == POST && -z $session && -n $mcp_response_session ]]; then
    mcp_session=$mcp_response_session
  fi
}

mcp_cleanup_session() {
  if [[ $mcp_cleanup_done -eq 1 ]]; then
    return 0
  fi
  mcp_cleanup_done=1
  if [[ -z $mcp_session ]]; then
    return 0
  fi
  mcp_request DELETE "$mcp_url" '' "$mcp_session" "$mcp_cleanup_protocol"
  if [[ $mcp_curl_status -ne 0 ]]; then
    mcp_record_fail "$mcp_check_prefix.cleanup" "MCP session cleanup request failed"
    return 1
  elif [[ ! $mcp_http_status =~ ^2[0-9][0-9]$ ]]; then
    mcp_record_fail "$mcp_check_prefix.cleanup" "MCP session cleanup failed with HTTP $mcp_http_status"
    return 1
  fi
  return 0
}

mcp_parse_response() {
  local expected_id=$1 content_type_lower=${mcp_content_type,,}
  local line event_data=''
  mcp_parse_error=body
  case $content_type_lower in
    application/json*)
      mcp_response_json=$(< "$mcp_body_file")
      if [[ -n $mcp_response_json ]] && jq -e -s 'length == 1' <<< "$mcp_response_json" >/dev/null 2>&1; then
        return 0
      fi
      ;;
    text/event-stream*)
      while IFS= read -r line; do
        line=${line%$'\r'}
        if [[ -z $line ]]; then
          if mcp_select_sse_response "$expected_id" "$event_data"; then return 0; fi
          event_data=''
        elif [[ $line == data:* ]]; then
          line=${line#data:}; line=${line# }
          [[ -z $event_data ]] || event_data+=$'\n'
          event_data+=$line
        fi
      done < "$mcp_body_file"
      if mcp_select_sse_response "$expected_id" "$event_data"; then return 0; fi
      ;;
    *) mcp_parse_error=content-type; return 1 ;;
  esac
  return 1
}

mcp_select_sse_response() {
  local expected_id=$1 event_data=$2
  [[ -n $event_data ]] || return 1
  if jq -e -s --argjson id "$expected_id" 'length == 1 and .[0].jsonrpc == "2.0" and .[0].id == $id' \
    <<< "$event_data" >/dev/null 2>&1; then
    mcp_response_json=$event_data
    return 0
  fi
  return 1
}

check_mcp() {
  local requested_protocol initialize_payload initialized_payload
  local mcp_request_id=2 page_count=0 has_next_cursor=0 cursor_seen_status
  local target prefix tools_payload max_pages
  local tool_names_file="$mcp_tmp/tool-names.jsonl"
  local next_cursor_file="$mcp_tmp/next-cursor.json"
  local seen_cursors_file="$mcp_tmp/seen-cursors.jsonl"

  if ! : > "$tool_names_file" || ! : > "$seen_cursors_file"; then
    mcp_record_fail "$mcp_check_prefix.tools" "MCP response projection could not be initialized"
    return
  fi

  requested_protocol=$(jq -r '.mcp.requestedProtocolVersion' "$manifest")
  mcp_cleanup_protocol=$requested_protocol
  max_pages=$(jq -r '.probePolicy.maxPages' "$manifest")
  initialize_payload=$(jq -cn --arg protocol "$requested_protocol" '{
    jsonrpc:"2.0",id:1,method:"initialize",
    params:{protocolVersion:$protocol,capabilities:{},clientInfo:{name:"dotfiles-doctor",version:"1"}}
  }')
  mcp_request POST "$mcp_url" "$initialize_payload" '' ''
  if [[ $mcp_curl_status -ne 0 ]]; then
    mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize request failed"
  elif [[ $mcp_http_status != 200 ]]; then
    mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize failed with HTTP $mcp_http_status"
  elif ! mcp_parse_response 1; then
    if [[ $mcp_parse_error == content-type ]]; then
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize response has unsupported content type: $mcp_content_type"
    else
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize response has an invalid JSON-RPC envelope"
    fi
  else
    mcp_protocol=$(jq -r '.result.protocolVersion // empty' <<< "$mcp_response_json" 2>/dev/null)
    [[ -z $mcp_protocol ]] || mcp_cleanup_protocol=$mcp_protocol
    if ! jq -e '.jsonrpc == "2.0" and .id == 1 and (.result | type) == "object" and (.result.protocolVersion | type) == "string" and (.result.capabilities | type) == "object"' <<< "$mcp_response_json" >/dev/null 2>&1; then
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize response has an invalid JSON-RPC envelope"
    elif ! jq -e '(.result.capabilities.tools | type) == "object"' <<< "$mcp_response_json" >/dev/null 2>&1; then
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize response does not advertise tools capability"
    elif [[ -z $mcp_session ]]; then
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP initialize response is missing a session ID"
    elif ! jq -e --arg protocol "$mcp_protocol" '.mcp.supportedProtocolVersions | index($protocol) != null' "$manifest" >/dev/null 2>&1; then
      mcp_record_fail "$mcp_check_prefix.initialize" "MCP negotiated unsupported protocol version: $mcp_protocol"
    fi
  fi

  if [[ $mcp_phase_failed -eq 0 ]]; then
    initialized_payload='{"jsonrpc":"2.0","method":"notifications/initialized"}'
    mcp_request POST "$mcp_url" "$initialized_payload" "$mcp_session" "$mcp_protocol"
    if [[ $mcp_curl_status -ne 0 ]]; then
      mcp_record_fail "$mcp_check_prefix.initialized" "MCP initialized notification request failed"
    elif [[ $mcp_http_status != 202 ]]; then
      mcp_record_fail "$mcp_check_prefix.initialized" "MCP initialized notification failed with HTTP $mcp_http_status"
    fi
  fi

  while [[ $mcp_phase_failed -eq 0 ]]; do
    if [[ $page_count -ge $max_pages ]]; then
      mcp_record_fail "$mcp_check_prefix.pagination" "MCP tools/list pagination exceeded $max_pages pages"
      break
    fi
    if [[ $has_next_cursor -eq 0 ]]; then
      tools_payload=$(jq -cn --argjson id "$mcp_request_id" '{jsonrpc:"2.0",id:$id,method:"tools/list",params:{}}')
    else
      tools_payload=$(jq -cn \
        --argjson id "$mcp_request_id" \
        --slurpfile cursor "$next_cursor_file" \
        '{jsonrpc:"2.0",id:$id,method:"tools/list",params:{cursor:$cursor[0]}}')
    fi
    mcp_request POST "$mcp_url" "$tools_payload" "$mcp_session" "$mcp_protocol"
    if [[ $mcp_curl_status -ne 0 ]]; then
      mcp_record_fail "$mcp_check_prefix.tools" "MCP tools/list request failed"
      break
    elif [[ $mcp_http_status != 200 ]]; then
      mcp_record_fail "$mcp_check_prefix.tools" "MCP tools/list failed with HTTP $mcp_http_status"
      break
    elif ! mcp_parse_response "$mcp_request_id" || ! jq -e --argjson id "$mcp_request_id" '
      .jsonrpc == "2.0" and .id == $id and (.result | type) == "object" and
      (.result.tools | type) == "array" and all(.result.tools[]; (.name | type) == "string") and
      (.result.nextCursor == null or (.result.nextCursor | type) == "string")
    ' <<< "$mcp_response_json" >/dev/null 2>&1; then
      mcp_record_fail "$mcp_check_prefix.tools" "MCP tools/list response is invalid"
      break
    fi
    if ! jq -c '.result.tools[].name' <<< "$mcp_response_json" >> "$tool_names_file"; then
      mcp_record_fail "$mcp_check_prefix.tools" "MCP tool name projection failed"
      break
    fi
    if jq -e '.result | has("nextCursor") and .nextCursor != null' <<< "$mcp_response_json" >/dev/null 2>&1; then
      has_next_cursor=1
      if ! jq -c '.result.nextCursor' <<< "$mcp_response_json" > "$next_cursor_file"; then
        mcp_record_fail "$mcp_check_prefix.pagination" "MCP pagination cursor projection failed"
        break
      fi
    else
      has_next_cursor=0
    fi
    page_count=$((page_count + 1))
    mcp_request_id=$((mcp_request_id + 1))
    [[ $has_next_cursor -eq 1 ]] || break
    jq -se '.[-1] as $candidate | any(.[0:-1][]; . == $candidate)' \
      "$seen_cursors_file" "$next_cursor_file" >/dev/null 2>&1
    cursor_seen_status=$?
    case $cursor_seen_status in
      0)
        mcp_record_fail "$mcp_check_prefix.pagination" "MCP tools/list pagination cursor repeated"
        break
        ;;
      1)
        if ! cat -- "$next_cursor_file" >> "$seen_cursors_file"; then
          mcp_record_fail "$mcp_check_prefix.pagination" "MCP pagination cursor could not be recorded"
          break
        fi
        ;;
      *)
        mcp_record_fail "$mcp_check_prefix.pagination" "MCP pagination cursor state is invalid"
        break
        ;;
    esac
  done

  if [[ $mcp_phase_failed -eq 0 ]]; then
    while IFS= read -r target; do
      target_started=$(now_ms)
      prefix="${target}_"
      component=$(stable_component "$target")
      if jq -se --arg prefix "$prefix" 'any(.[]; startswith($prefix))' "$tool_names_file" >/dev/null 2>&1; then
        add_check "$mcp_check_prefix.target.$component" active pass "$target" tools-exposed tools-exposed \
          "MCP target exposes tools: $target" "$(duration_since "$target_started")"
      else
        mcp_record_fail "$mcp_check_prefix.target.$component" "MCP target has no tools: $target"
      fi
    done < <(jq -r '.targets[]' <<< "$mcp_endpoint_json")
  fi
  mcp_cleanup_session
  if [[ $mcp_phase_failed -eq 0 ]]; then
    add_check "$mcp_check_prefix.session" active pass "$mcp_url" complete complete \
      "MCP session lifecycle completed" "$(duration_since "$mcp_check_started_ms")"
  fi
}

check_mcp_resources() {
  local started=$1 endpoint=$2 check_id=$3
  local expected observed missing='' non_numeric='' mismatched='' value proc_root fd_current=''
  local unit main_pid
  local -a pairs=()
  unit=$(jq -r '.healthUnit' <<< "$endpoint")
  expected=$(jq -c '.resources.expected' <<< "$endpoint")
  while IFS= read -r property; do
    value=${mcp_resource_observed[$unit|$property]:-}
    if [[ -z $value ]]; then
      missing+=" $property"
      continue
    fi
    if [[ ! $value =~ ^[0-9]+$ ]]; then
      non_numeric+=" $property"
      continue
    fi
    pairs+=("--arg" "$property" "$value")
  done < <(jq -r '.resources.properties[]' <<< "$endpoint")

  # FD は cgroup property にないので MainPID の proc entry を数える
  proc_root=${DOCTOR_TEST_PROC_ROOT:-/proc}
  if [[ -z $missing && -z $non_numeric ]]; then
    main_pid=${mcp_resource_observed[$unit|MainPID]}
    fd_current=$(find "$proc_root/$main_pid/fd" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)
    pairs+=("--arg" "fdCurrent" "$fd_current")
  fi
  observed=$(jq -cn "${pairs[@]}" '$ARGS.named')

  if [[ -n $missing ]]; then
    add_check "$check_id" active fail "$unit" "$expected" "$observed" \
      "MCP resource metrics are incomplete:$missing" "$(duration_since "$started")"
    return
  fi
  if [[ -n $non_numeric ]]; then
    add_check "$check_id" active fail "$unit" "$expected" "$observed" \
      "MCP resource metrics are not numeric:$non_numeric" "$(duration_since "$started")"
    return
  fi
  while IFS='=' read -r property expected_value; do
    [[ -n $property ]] || continue
    if [[ ${mcp_resource_observed[$unit|$property]:-} != "$expected_value" ]]; then
      mismatched+=" $property=${mcp_resource_observed[$unit|$property]:-}"
    fi
  done < <(jq -r '.resources.expected | to_entries[] | "\(.key)=\(.value)"' <<< "$endpoint")
  if [[ -n $mismatched ]]; then
    add_check "$check_id" active fail "$unit" "$expected" "$observed" \
      "MCP file descriptor limit does not match manifest:$mismatched" "$(duration_since "$started")"
    return
  fi
  add_check "$check_id" active pass "$unit" "$expected" "$observed" \
    "MCP resources: TasksCurrent=${mcp_resource_observed[$unit|TasksCurrent]} fdCurrent=$fd_current MemoryCurrent=${mcp_resource_observed[$unit|MemoryCurrent]} MemorySwapCurrent=${mcp_resource_observed[$unit|MemorySwapCurrent]} LimitNOFILE=${mcp_resource_observed[$unit|LimitNOFILE]} LimitNOFILESoft=${mcp_resource_observed[$unit|LimitNOFILESoft]}" \
    "$(duration_since "$started")"
}

# endpoint ごとに health unit と session を独立に見る。default にも例外を作らない
mcp_total_timeout=$(jq -r '.probePolicy.totalTimeoutSeconds' "$manifest")
# totalTimeoutSeconds は MCP phase 全体の上限。endpoint ごとに起点を取り直すと上限が endpoint 数だけ伸びる
mcp_started_seconds=$SECONDS
while IFS= read -r mcp_endpoint; do
  mcp_endpoint_id=$(jq -r '.id' <<< "$mcp_endpoint")
  mcp_health_unit=$(jq -r '.healthUnit' <<< "$mcp_endpoint")
  mcp_component=$(stable_component "$mcp_endpoint_id")
  mcp_health_started=$(now_ms)
  if [[ ${unit_check_status[$mcp_health_unit]:-fail} != pass ]]; then
    add_check "active.mcp.$mcp_component.health-unit" active blocked "$mcp_health_unit" pass fail \
      "MCP health unit is not healthy: $mcp_health_unit" "$(duration_since "$mcp_health_started")"
    add_check "active.mcp.$mcp_component.resources" active blocked "$mcp_health_unit" healthy-unit blocked \
      "MCP resource metrics are blocked by their health unit" "$(duration_since "$mcp_health_started")"
    add_check "active.mcp.$mcp_component.session" active blocked "$(jq -r '.url' <<< "$mcp_endpoint")" healthy-unit blocked \
      "MCP session is blocked by its health unit" "$(duration_since "$mcp_health_started")"
    continue
  fi
  add_check "active.mcp.$mcp_component.health-unit" active pass "$mcp_health_unit" pass pass \
    "MCP health unit is healthy: $mcp_health_unit" "$(duration_since "$mcp_health_started")"
  check_mcp_resources "$(now_ms)" "$mcp_endpoint" "active.mcp.$mcp_component.resources"
  mcp_url=$(jq -r '.url' <<< "$mcp_endpoint")
  mcp_session=''
  mcp_cleanup_done=0
  mcp_request_number=0
  mcp_phase_failed=0
  mcp_tmp=$(mktemp -d)
  mcp_check_started_ms=$(now_ms)
  mcp_check_prefix="active.mcp.$mcp_component"
  mcp_endpoint_json=$mcp_endpoint
  check_mcp
  mcp_remove_temp
done < <(jq -c '.mcp.endpoints[]' "$manifest")

started=$(now_ms)
final_current_canonical=$(readlink -e -- "$current" 2>/dev/null)
final_profile_canonical=$(readlink -e -- "$profile" 2>/dev/null)
final_manifest_canonical=$(readlink -e -- "$manifest_entry" 2>/dev/null)
expected_snapshot=$(jq -cn \
  --arg current "$current_canonical" \
  --arg profile "$current_canonical" \
  --arg manifest "$manifest" \
  '{current:$current,profile:$profile,manifest:$manifest}')
observed_snapshot=$(jq -cn \
  --arg current "$final_current_canonical" \
  --arg profile "$final_profile_canonical" \
  --arg manifest "$final_manifest_canonical" \
  '{current:$current,profile:$profile,manifest:$manifest}')
if [[ $final_current_canonical == "$current_canonical" \
  && $final_profile_canonical == "$current_canonical" \
  && $final_manifest_canonical == "$manifest" ]]; then
  add_check foundation.stability foundation pass "$current" "$expected_snapshot" "$observed_snapshot" \
    "generation snapshot remained stable during doctor execution" "$(duration_since "$started")"
else
  add_check foundation.stability foundation fail "$current" "$expected_snapshot" "$observed_snapshot" \
    "generation snapshot changed during doctor execution" "$(duration_since "$started")"
fi

render_report
exit $?
