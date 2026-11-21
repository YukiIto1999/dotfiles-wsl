# shellcheck shell=bash

set -euo pipefail

application=@application@
units=(@units@)
containers=(@containers@)
images=(@images@)
health_method=@healthMethod@
health_url=@healthUrl@
health_timeout=@healthTimeout@
curl_command=@curlCommand@
docker_command=@dockerCommand@
envelope_version=@envelopeVersion@
jq_command=@jqCommand@
outcome_id="container-manual/$application"
systemctl_command=@systemctlCommand@

# Single-outcome normalized envelope
# Argument 1: pass, warn, or fail
# Argument 2: Operator-facing message
# Output: Envelope JSON on stdout
emit() {
  "$jq_command" -cn \
    --argjson version "$envelope_version" \
    --arg id "$outcome_id" \
    --arg status "$1" \
    --arg message "$2" \
    '{schemaVersion:$version,outcomes:[{id:$id,status:$status,message:$message}],resources:[]}'
}

active=()
stopped=()
transitional=()
failed=()
unit='' state='' result=''
# Unit state classification from one systemctl show block
# Globals: unit, state, result; appends to the state arrays
classify() {
  case $state/$result in
    active/*) active+=("$unit") ;;
    inactive/success) stopped+=("$unit") ;;
    activating/* | deactivating/* | reloading/*) transitional+=("$unit $state") ;;
    *) failed+=("$unit $state/${result:-unknown}") ;;
  esac
  unit='' state='' result=''
}

properties=$("$systemctl_command" show --property=Id --property=ActiveState --property=Result -- "${units[@]}")
while IFS= read -r line; do
  case $line in
    Id=*) unit=${line#Id=} ;;
    ActiveState=*) state=${line#ActiveState=} ;;
    Result=*) result=${line#Result=} ;;
    '') [[ -z $unit ]] || classify ;;
  esac
done <<<"$properties"
[[ -z $unit ]] || classify

if ((${#active[@]} + ${#stopped[@]} + ${#transitional[@]} + ${#failed[@]} != ${#units[@]})); then
  emit fail "could not observe every unit of $application"
  exit 0
fi
if ((${#failed[@]} > 0)); then
  message=$(printf '%s; ' "${failed[@]}")
  emit fail "$application has failed units: ${message%; }"
  exit 0
fi
if ((${#stopped[@]} == ${#units[@]})); then
  # manual activation の停止は operator の意図した状態のため fault 扱いは不可
  emit pass "$application is stopped (manual activation)"
  exit 0
fi
if ((${#active[@]} != ${#units[@]})); then
  message=$(printf '%s; ' "${transitional[@]}" "${stopped[@]/%/ inactive}")
  emit warn "$application is partially running: ${message%; }"
  exit 0
fi

for index in "${!containers[@]}"; do
  container=${containers[$index]}
  image=${images[$index]}
  if ! declared=$("$docker_command" image inspect "$image" --format '{{.Id}}' 2>/dev/null) \
    || ! running=$("$docker_command" inspect "$container" --format '{{.Image}}' 2>/dev/null) \
    || [[ -z $declared || $declared != "$running" ]]; then
    emit fail "$container is not running the declared image $image"
    exit 0
  fi
done

if ! "$curl_command" --silent --show-error --fail-with-body --max-time "$health_timeout" \
  --request "$health_method" --output /dev/null "$health_url" >/dev/null 2>&1; then
  emit fail "$health_method $health_url failed"
  exit 0
fi
emit pass "$application is running the declared images and $health_url answers"
