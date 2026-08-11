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
  local fragment_file=$1 observation_file=$2
  $jq_command -e -s --slurpfile observation "$observation_file" '
    length == 1
    and ($observation | length) == 1
    and (
      .[0] as $fragment
      | $observation[0].value as $contract
      | (
          if $contract.kind == "normalized-protocol"
          then $contract.allowedOutcomeIds
          else [$contract.checkId]
          end
        ) as $allowed_check_ids
      | (
          if $contract.kind == "normalized-protocol"
          then $contract.requiredOutcomeIds
          elif $contract.kind == "roster" and $contract.failureOnly
          then []
          else [$contract.checkId]
          end
        ) as $required_check_ids
      | (
          if $contract.kind == "normalized-protocol"
          then $contract.requiredResourceKeys
          elif $contract.resourceKey == null
          then []
          else [$contract.resourceKey]
          end
        ) as $allowed_resource_keys
      | ($fragment.checks | map(.id)) as $check_ids
      | ($fragment.warnings | map(.id)) as $warning_ids
      | ($fragment.failures | map(.id)) as $failure_ids
      | ($fragment.resources | map(.key)) as $resource_keys
      | ($fragment.checks | map(select(.status == "warn") | .id)) as $warn_check_ids
      | ($fragment.checks | map(select(.status == "fail") | .id)) as $fail_check_ids
      | ($fragment | type) == "object"
      and ($fragment | keys | sort) == ["checks","failures","resources","restart","warnings"]
      and ($fragment.checks | type) == "array"
      and ($fragment.warnings | type) == "array"
      and ($fragment.failures | type) == "array"
      and ($fragment.resources | type) == "array"
      and all($fragment.checks[];
        type == "object"
        and (keys | sort) == ["id","status"]
        and (.id | type) == "string" and (.id | length) > 0
        and (.status == "pass" or .status == "warn" or .status == "fail"))
      and all($fragment.warnings[], $fragment.failures[];
        type == "object"
        and (keys | sort) == ["id","message"]
        and (.id | type) == "string" and (.id | length) > 0
        and (.message | type) == "string" and (.message | length) > 0)
      and all($fragment.resources[];
        type == "object"
        and (keys | sort) == ["key","value"]
        and (.key | type) == "string" and (.key | length) > 0)
      and ($check_ids | length) == ($check_ids | unique | length)
      and all($check_ids[]; . as $id | ($allowed_check_ids | index($id)) != null)
      and all($required_check_ids[]; . as $id | ($check_ids | index($id)) != null)
      and ($warning_ids | sort) == ($warn_check_ids | sort)
      and ($failure_ids | sort) == ($fail_check_ids | sort)
      and ($resource_keys | length) == ($resource_keys | unique | length)
      and all($resource_keys[]; . as $key | ($allowed_resource_keys | index($key)) != null)
      and (
        $contract.kind != "normalized-protocol"
        or ($resource_keys | sort) == ($contract.requiredResourceKeys | sort)
      )
      and (
        if $contract.kind != "restart-counter"
        then $fragment.restart == null
        elif $fragment.restart == null
        then any($fragment.checks[];
          .id == $contract.checkId and .status == "fail")
        else
          ($fragment.restart | type) == "object"
          and ($fragment.restart | keys | sort) == ["count","kind","target"]
          and ($fragment.restart.target | type) == "string"
          and ($fragment.restart.target | length) > 0
          and $fragment.restart.target == $contract.target
          and (
            if $contract.sourceKind == "systemd-service"
            then $fragment.restart.kind == "service"
            elif $contract.sourceKind == "container"
            then $fragment.restart.kind == "container"
            else false
            end
          )
          and ($fragment.restart.count | type) == "number"
          and $fragment.restart.count >= 0
          and ($fragment.restart.count | floor) == $fragment.restart.count
        end
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
    && fragment_is_valid "$fragment_file" "$observation_file"; then
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
