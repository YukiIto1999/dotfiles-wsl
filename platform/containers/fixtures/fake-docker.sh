# shellcheck shell=bash

set -euo pipefail

label_pattern='\{\{\.Label "([^"]*)"\}\}'

list() {
  local all=0 format='' id name state created key value line
  while (($#)); do
    case $1 in
      --all) all=1 ;;
      --no-trunc) ;;
      --format)
        format=$2
        shift
        ;;
      *) exit 64 ;;
    esac
    shift
  done
  [[ -n $format ]] || exit 64
  [[ ${FAKE_DOCKER_LS_STATUS-0} == 0 ]] || exit "$FAKE_DOCKER_LS_STATUS"
  while IFS='|' read -r id name state created key value; do
    [[ -n $id ]] || continue
    ((all)) || [[ $state == running ]] || continue
    line=${format//'\t'/$'\t'}
    line=${line//'{{.ID}}'/$id}
    line=${line//'{{.Names}}'/$name}
    line=${line//'{{.State}}'/$state}
    line=${line//'{{.CreatedAt}}'/$created}
    while [[ $line =~ $label_pattern ]]; do
      if [[ ${BASH_REMATCH[1]} == "$key" ]]; then
        line=${line//"${BASH_REMATCH[0]}"/$value}
      else
        line=${line//"${BASH_REMATCH[0]}"/}
      fi
    done
    # 未知の placeholder を空の値として通すと format と読み取りの不一致を見逃すため不可
    [[ $line != *'{{'* ]] || exit 64
    printf '%s\n' "$line"
  done <"$FAKE_CONTAINERS"
}

case "${1-} ${2-}" in
  'container ls')
    shift 2
    list "$@"
    ;;
  *) exit 64 ;;
esac
