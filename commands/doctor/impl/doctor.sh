# shellcheck shell=bash

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: dotfiles-doctor [--json]

Reconcile the declared dotfiles deployment with the running system. Exit 0
when checks only pass or warn, 1 when any check fails.
USAGE
}

json=0
if (($# > 1)); then
  usage >&2
  exit 2
fi
case "${1-}" in
  --json) json=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

env_command=@envCommand@
head_command=@headCommand@
jq_command=@jqCommand@
mktemp_command=@mktempCommand@
observations=@observations@
probe_command=@probeCommand@
rm_command=@rmCommand@
runtime_path=@runtimePath@
timeout_command=@timeoutCommand@
wc_command=@wcCommand@

checks=()
warnings=()
failures=()
resources=()
service_restarts=()
container_restarts=()

record_fallback_failure() {
  local observation=$1 id message
  id=$($jq_command -r '.value.checkId' <<<"$observation")
  message=$($jq_command -r '.value.failureMessage' <<<"$observation")
  checks+=("$($jq_command -cn --arg id "$id" '{id:$id,status:"fail"}')")
  failures+=("$($jq_command -cn --arg id "$id" --arg message "$message" '{id:$id,message:$message}')")
}

append_fragment() {
  local fragment_file=$1 row kind target count
  while IFS= read -r row; do checks+=("$row"); done \
    < <($jq_command -c '.checks[]' "$fragment_file")
  while IFS= read -r row; do warnings+=("$row"); done \
    < <($jq_command -c '.warnings[]' "$fragment_file")
  while IFS= read -r row; do failures+=("$row"); done \
    < <($jq_command -c '.failures[]' "$fragment_file")
  while IFS= read -r row; do resources+=("$row"); done \
    < <($jq_command -c '.resources[]' "$fragment_file")
  if $jq_command -e '.restart != null' "$fragment_file" >/dev/null; then
    kind=$($jq_command -r '.restart.kind' "$fragment_file")
    target=$($jq_command -r '.restart.target' "$fragment_file")
    count=$($jq_command '.restart.count' "$fragment_file")
    if [[ $kind == service ]]; then
      service_restarts+=("$($jq_command -cn --arg unit "$target" --argjson count "$count" '{unit:$unit,count:$count}')")
    else
      container_restarts+=("$($jq_command -cn --arg container "$target" --argjson count "$count" '{container:$container,count:$count}')")
    fi
  fi
}

fragment_is_valid() {
  local fragment_file=$1
  $jq_command -e -s '
    length == 1
    and (.[0] | type) == "object"
    and (.[0] | keys | sort) == ["checks","failures","resources","restart","warnings"]
    and (.[0].checks | type) == "array"
    and (.[0].warnings | type) == "array"
    and (.[0].failures | type) == "array"
    and (.[0].resources | type) == "array"
    and all(.[0].checks[];
      type == "object"
      and (keys | sort) == ["id","status"]
      and (.id | type) == "string" and (.id | length) > 0
      and (.status == "pass" or .status == "warn" or .status == "fail"))
    and all(.[0].warnings[], .[0].failures[];
      type == "object"
      and (keys | sort) == ["id","message"]
      and (.id | type) == "string" and (.id | length) > 0
      and (.message | type) == "string" and (.message | length) > 0)
    and all(.[0].resources[];
      type == "object"
      and (keys | sort) == ["key","value"]
      and (.key | type) == "string" and (.key | length) > 0)
    and (
      .[0].restart == null
      or (
        (.[0].restart | type) == "object"
        and (.[0].restart | keys | sort) == ["count","kind","target"]
        and (.[0].restart.kind == "service" or .[0].restart.kind == "container")
        and (.[0].restart.target | type) == "string" and (.[0].restart.target | length) > 0
        and (.[0].restart.count | type) == "number"
        and .[0].restart.count >= 0
        and (.[0].restart.count | floor) == .[0].restart.count
      )
    )
  ' "$fragment_file" >/dev/null 2>&1
}

umask 077
doctor_tmp=$($mktemp_command -d "${TMPDIR:-/tmp}/dotfiles-doctor.XXXXXXXX")
cleanup() {
  $rm_command -rf -- "$doctor_tmp"
}
trap cleanup EXIT

mapfile -t observation_rows < <($jq_command -c '.[]' <<<"$observations")
for index in "${!observation_rows[@]}"; do
  observation=${observation_rows[$index]}
  observation_file=$doctor_tmp/observation-$index.json
  observation_scratch=$doctor_tmp/scratch-$index
  fragment_file=$doctor_tmp/fragment-$index.json
  timeout_seconds=$($jq_command '.value.timeoutSeconds' <<<"$observation")
  printf '%s\n' "$observation" >"$observation_file"
  mkdir -m 700 -- "$observation_scratch"

  set +e
  $timeout_command --signal=TERM --kill-after=2s "${timeout_seconds}s" \
    $env_command -i \
      HOME="${HOME:-/}" \
      USER="${USER:-}" \
      LOGNAME="${LOGNAME:-}" \
      PATH="$runtime_path" \
      TMPDIR="$observation_scratch" \
      LANG=C \
      LC_ALL=C \
      "$probe_command" "$observation_file" "$observation_scratch" \
      2>/dev/null \
    | $head_command -c 131073 >"$fragment_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  fragment_size=$($wc_command -c <"$fragment_file")

  if [[ $fragment_size =~ ^[0-9]+$ ]] \
    && ((fragment_size <= 131072)) \
    && ((pipeline_status[0] == 0 && pipeline_status[1] == 0)) \
    && fragment_is_valid "$fragment_file"; then
    append_fragment "$fragment_file"
  else
    record_fallback_failure "$observation"
  fi
done

service_restarts_json=$(printf '%s\n' "${service_restarts[@]}" | $jq_command -sc 'map(select(type == "object"))')
container_restarts_json=$(printf '%s\n' "${container_restarts[@]}" | $jq_command -sc 'map(select(type == "object"))')
resources+=("$($jq_command -cn --argjson value "$service_restarts_json" '{key:"serviceRestarts",value:$value}')")
resources+=("$($jq_command -cn --argjson value "$container_restarts_json" '{key:"containerRestarts",value:$value}')")

checks_file=$doctor_tmp/checks.jsonl
warnings_file=$doctor_tmp/warnings.jsonl
failures_file=$doctor_tmp/failures.jsonl
resources_file=$doctor_tmp/resources.jsonl
: >"$checks_file"
: >"$warnings_file"
: >"$failures_file"
: >"$resources_file"
((${#checks[@]} == 0)) || printf '%s\n' "${checks[@]}" >"$checks_file"
((${#warnings[@]} == 0)) || printf '%s\n' "${warnings[@]}" >"$warnings_file"
((${#failures[@]} == 0)) || printf '%s\n' "${failures[@]}" >"$failures_file"
((${#resources[@]} == 0)) || printf '%s\n' "${resources[@]}" >"$resources_file"

report=$($jq_command -cn \
  --slurpfile checks "$checks_file" \
  --slurpfile warnings "$warnings_file" \
  --slurpfile failures "$failures_file" \
  --slurpfile resources "$resources_file" \
  '{checks:$checks,warnings:$warnings,failures:$failures,resources:($resources | from_entries)}')

if ((json == 1)); then
  printf '%s\n' "$report"
else
  $jq_command -r '.checks[] | "\(.status): \(.id)"' <<<"$report"
  if ((${#warnings[@]} > 0)); then
    $jq_command -r '.warnings[] | "  \(.id): \(.message)"' <<<"$report" >&2
  fi
  if ((${#failures[@]} > 0)); then
    $jq_command -r '.failures[] | "  \(.id): \(.message)"' <<<"$report" >&2
  fi
fi

if ((${#failures[@]} > 0)); then
  exit 1
fi
exit 0
