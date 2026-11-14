# shellcheck shell=bash

set -euo pipefail

jq_command=@jqCommand@
reader_command=@readerCommand@
reader_timeout_seconds=@readerTimeoutSeconds@
timeout_command=@timeoutCommand@

snapshot=$("$timeout_command" --signal=TERM --kill-after=1s "${reader_timeout_seconds}s" \
  "$reader_command" 2>/dev/null) || exit 1

# 0 は正常な使用率として受理されるため取得不能時の 0 出力は不可
percent=$("$jq_command" -cse '
  if length == 1
    and (.[0] | type) == "object"
    and .[0].state == "fresh"
    and (.[0].commitUsedBytes | type) == "number"
    and (.[0].commitLimitBytes | type) == "number"
    and .[0].commitLimitBytes > 0
  then
    (.[0].commitUsedBytes * 100 / .[0].commitLimitBytes | floor) as $used
    | if $used > 100 then 100 else $used end
  else empty
  end
' <<<"$snapshot" 2>/dev/null) || exit 1

printf '%s\n' "$percent"
