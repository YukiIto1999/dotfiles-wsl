# shellcheck shell=bash

set -euo pipefail

declared_containers=(@declaredContainers@)
declared_slice=@declaredSlice@
docker_command=@dockerCommand@
envelope_version=@envelopeVersion@
jq_command=@jqCommand@
outcome_id=@outcomeId@
systemctl_command=@systemctlCommand@
undeclared_slice=@undeclaredSlice@

declare -A declared=()
for name in "${declared_containers[@]}"; do
  declared[$name]=1
done

listing=$("$docker_command" container ls --no-trunc --format $'{{.ID}}\t{{.Names}}')
declare -A names=()
units=()
while IFS=$'\t' read -r id name; do
  [[ -n $id ]] || continue
  names[docker-$id.scope]=$name
  units+=("docker-$id.scope")
done <<<"$listing"

placed=0
misplaced=()
judge() {
  local unit=$1 load=$2 slice=$3 name expected
  # 一覧の後に終わった container の scope は残らないため not-found の失敗扱いは不可
  [[ $load == loaded ]] || return 0
  name=${names[$unit]-$unit}
  if [[ -v declared[$name] ]]; then
    expected=$declared_slice
  else
    expected=$undeclared_slice
  fi
  if [[ $slice == "$expected" ]]; then
    placed=$((placed + 1))
  else
    misplaced+=("$name in ${slice:-no slice} instead of $expected")
  fi
}

if ((${#units[@]} > 0)); then
  properties=$("$systemctl_command" show --property=Id --property=LoadState --property=Slice "${units[@]}")
  unit='' load='' slice=''
  while IFS= read -r line; do
    case $line in
      Id=*) unit=${line#Id=} ;;
      LoadState=*) load=${line#LoadState=} ;;
      Slice=*) slice=${line#Slice=} ;;
      '')
        [[ -z $unit ]] || judge "$unit" "$load" "$slice"
        unit='' load='' slice=''
        ;;
    esac
  done <<<"$properties"
  [[ -z $unit ]] || judge "$unit" "$load" "$slice"
fi

if ((${#misplaced[@]} == 0)); then
  status=pass
  message="$placed running containers are in their declared slices"
else
  status=fail
  message=$(printf '%s; ' "${misplaced[@]}")
  message="misplaced containers: ${message%; }"
fi

"$jq_command" -cn \
  --argjson version "$envelope_version" \
  --arg id "$outcome_id" \
  --arg status "$status" \
  --arg message "$message" \
  '{schemaVersion:$version,outcomes:[{id:$id,status:$status,message:$message}],resources:[]}'
