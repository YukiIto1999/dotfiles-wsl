set -euo pipefail

powershell_command=@powershellCommand@
timeout_command=@timeoutCommand@
probe_timeout_seconds=@timeoutSeconds@
powershell_probe=@powershellProbe@

if output=$(
  "$timeout_command" --signal=TERM --kill-after=2s "${probe_timeout_seconds}s" \
    "$powershell_command" -NoLogo -NoProfile -NonInteractive -Command "$powershell_probe" 2>/dev/null
  status=$?
  printf '\x1f'
  exit "$status"
); then
  output=${output%$'\x1f'}
  if [[ $output == *$'\r\n' ]]; then
    observed_percent=${output%$'\r\n'}
  elif [[ $output == *$'\n' ]]; then
    observed_percent=${output%$'\n'}
  elif [[ $output == *$'\r' ]]; then
    observed_percent=${output%$'\r'}
  else
    observed_percent=$output
  fi
else
  exit 1
fi

if [[ $observed_percent =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((observed_percent <= 100)); then
  printf '%s\n' "$observed_percent"
  exit 0
fi

exit 1
