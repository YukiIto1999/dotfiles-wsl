# shellcheck shell=bash

set -euo pipefail

collector_source=@collectorSource@
expected_sha256=@expectedSha256@
interval_seconds=@intervalSeconds@
jq_command=@jqCommand@
manage_script=@manageScript@
operation_timeout_seconds=@operationTimeoutSeconds@
powershell_command=@powershellCommand@
publish_wait_seconds=@publishWaitSeconds@
reader_command=@readerCommand@
reader_timeout_seconds=@readerTimeoutSeconds@
retry_seconds=@retrySeconds@
sleep_command=@sleepCommand@
snapshot_name=@snapshotName@
task_name=@taskName@
timeout_command=@timeoutCommand@
windows_directory=@windowsDirectory@
wslpath_command=@wslpathCommand@

usage() {
  printf '%s\n' \
    'Usage: dotfiles-windows-resource-collector install|status|uninstall' \
    '  install    copy the collector into the Windows snapshot directory, register its scheduled task and start it;' \
    '             running it again updates the collector and the task' \
    '  status     print the collector state on Windows and the freshness of its snapshot' \
    '  uninstall  stop and unregister only this collector task and remove only its own files' \
    'Privileges: runs as the current Windows user and never elevates. install and uninstall need permission to' \
    'create or remove the snapshot directory under %ProgramData% and to register or unregister a scheduled task' \
    'for that user; this tool does not verify that the Windows policy grants either. A denied step stops the' \
    'run, is named in the error, and the steps already applied are listed.' \
    'Ownership: install and uninstall change an existing scheduled task or snapshot directory only when it is' \
    'recognizably this collector (same principal, marker, script path; restricted ACL, only its own files).' \
    'Anything else is left untouched and reported.' \
    'Execution policy: never overridden. The management script runs from a temporary local copy and the collector' \
    'from the snapshot directory, so the effective policy must allow local unsigned scripts (RemoteSigned or looser).' \
    'Otherwise PowerShell reports it, and install ends without a fresh snapshot.'
}

fail() {
  printf 'dotfiles-windows-resource-collector: %s\n' "$1" >&2
  return 1
}

windows_path() {
  local converted
  converted=$("$wslpath_command" -w "$1" 2>/dev/null) || return 1
  [[ -n $converted && $converted != *$'\n'* ]] || return 1
  printf '%s\n' "$converted"
}

ps_literal() {
  local text=${1//\'/\'\'}
  printf "'%s'" "$text"
}

# UNC 上の script は RemoteSigned に拒否されるため UNC からの直接実行は不可
run_manage() {
  local action=$1 collector_windows=${2-} manage_windows invocation script
  manage_windows=$(windows_path "$manage_script") || fail 'could not convert the management script path' || return 1
  invocation="& \$copy -Action $(ps_literal "$action") -Directory $(ps_literal "$windows_directory") -TaskName $(ps_literal "$task_name")"
  invocation+=" -IntervalSeconds $interval_seconds -SnapshotName $(ps_literal "$snapshot_name") -ExpectedSha256 $(ps_literal "$expected_sha256")"
  if [[ -n $collector_windows ]]; then
    invocation+=" -CollectorSource $(ps_literal "$collector_windows")"
  fi
  script="\$ErrorActionPreference = 'Stop'; \$copy = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-collector-manage.' + [Guid]::NewGuid().ToString('N') + '.ps1'); \$code = 1; "
  script+="try { [IO.File]::Copy($(ps_literal "$manage_windows"), \$copy); $invocation; \$code = \$LASTEXITCODE } "
  script+="finally { if ([IO.File]::Exists(\$copy)) { [IO.File]::Delete(\$copy) } }; exit \$code"
  "$timeout_command" --signal=TERM --kill-after=5s "${operation_timeout_seconds}s" \
    "$powershell_command" -NoLogo -NoProfile -NonInteractive -Command "$script"
}

read_snapshot() {
  local snapshot
  snapshot=$("$timeout_command" --signal=TERM --kill-after=1s "${reader_timeout_seconds}s" \
    "$reader_command" 2>/dev/null) || snapshot=
  "$jq_command" -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' \
    <<<"$snapshot" 2>/dev/null || printf '{"state":"unavailable"}\n'
}

install_collector() {
  local collector_windows started_at deadline snapshot
  collector_windows=$(windows_path "$collector_source") || fail 'could not convert the collector path' || return 1
  printf -v started_at '%(%s)T' -1
  run_manage install "$collector_windows" >/dev/null || fail 'the Windows installation did not complete' || return 1
  deadline=$((SECONDS + publish_wait_seconds))
  while :; do
    snapshot=$(read_snapshot)
    if "$jq_command" -e --argjson started "$started_at" \
      '.state == "fresh" and .observedAt >= $started' <<<"$snapshot" >/dev/null 2>&1; then
      printf '%s\n' "$snapshot"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      fail "the collector did not publish a fresh snapshot within ${publish_wait_seconds}s" || return 1
    fi
    "$sleep_command" "$retry_seconds"
  done
}

collector_status() {
  local collector snapshot combined
  collector=$(run_manage status 2>/dev/null) || collector=
  collector=$("$jq_command" -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' \
    <<<"$collector" 2>/dev/null) || collector=null
  snapshot=$(read_snapshot)
  combined=$("$jq_command" -cn --argjson collector "$collector" --argjson snapshot "$snapshot" \
    '{collector: $collector, snapshot: $snapshot}')
  printf '%s\n' "$combined"
  "$jq_command" -e '
    .collector != null
    and .collector.directoryTrusted == true
    and .collector.collectorCurrent == true
    and .collector.taskRegistered == true
    and .collector.taskOwned == true
    and .collector.taskState == "Running"
    and .snapshot.state == "fresh"
  ' <<<"$combined" >/dev/null
}

uninstall_collector() {
  run_manage uninstall >/dev/null || fail 'the Windows removal did not complete' || return 1
  printf '%s\n' 'the collector task and its files were removed'
}

if (($# == 1)) && [[ $1 == --help || $1 == -h ]]; then
  usage
  exit 0
fi
if (($# != 1)); then
  usage >&2
  exit 64
fi
case $1 in
  install) install_collector ;;
  status) collector_status ;;
  uninstall) uninstall_collector ;;
  *)
    usage >&2
    exit 64
    ;;
esac
