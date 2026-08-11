#!/usr/bin/env bash
set -euo pipefail

output=
url=
saw_fail=0
saw_silent=0
saw_show_error=0
saw_location=0
saw_proto=0
saw_proto_redir=0
saw_connect_timeout=0
saw_max_time=0
saw_max_redirs=0
while (($# > 0)); do
  case $1 in
    -o|--output)
      (($# >= 2)) || exit 64
      output=$2
      shift 2
      ;;
    --connect-timeout)
      (($# >= 2)) || exit 64
      [[ $2 =~ ^[1-9][0-9]*$ ]] || exit 64
      saw_connect_timeout=1
      shift 2
      ;;
    --max-time)
      (($# >= 2)) || exit 64
      [[ $2 =~ ^[1-9][0-9]*$ ]] || exit 64
      saw_max_time=1
      shift 2
      ;;
    --max-redirs)
      (($# >= 2)) || exit 64
      [[ $2 =~ ^[1-9][0-9]*$ ]] || exit 64
      saw_max_redirs=1
      shift 2
      ;;
    --proto)
      (($# >= 2)) || exit 64
      [[ $2 == '=https' ]] || exit 64
      saw_proto=1
      shift 2
      ;;
    --proto-redir)
      (($# >= 2)) || exit 64
      [[ $2 == '=https' ]] || exit 64
      saw_proto_redir=1
      shift 2
      ;;
    --fail) saw_fail=1; shift ;;
    --silent) saw_silent=1; shift ;;
    --show-error) saw_show_error=1; shift ;;
    --location) saw_location=1; shift ;;
    -* ) exit 64 ;;
    * )
      url=$1
      shift
      ;;
  esac
done

[[ -n $url ]] || exit 64
((saw_fail && saw_silent && saw_show_error && saw_location)) || exit 64
((saw_proto && saw_proto_redir && saw_connect_timeout && saw_max_time && saw_max_redirs)) || exit 64
if [[ -n ${FIXTURE_CURL_DELAY:-} ]]; then
  sleep "$FIXTURE_CURL_DELAY"
fi
printf '%s\n' "$url" >>"$FIXTURE_CURL_LOG"

case $url in
  https://api.github.com/repos/*/releases/latest)
    [[ ${output##*/} == release.json ]] || exit 64
    if [[ -n $output ]]; then
      cp -- "$FIXTURE_API_JSON" "$output"
    else
      cat "$FIXTURE_API_JSON"
    fi
    ;;
  https://github.com/*/releases/download/*)
    [[ -n $output ]] || exit 64
    [[ ${output##*/} == archive.tar.gz ]] || exit 64
    cp -- "$FIXTURE_ARCHIVE" "$output"
    ;;
  *)
    printf 'unexpected fixture URL: %s\n' "$url" >&2
    exit 65
    ;;
esac
