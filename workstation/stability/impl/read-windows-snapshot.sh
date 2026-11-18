# shellcheck shell=bash

set -euo pipefail

date_command=@dateCommand@
future_skew_seconds=@futureSkewSeconds@
head_command=@headCommand@
jq_command=@jqCommand@
kill_after_seconds=@killAfterSeconds@
maximum_age_seconds=@maximumAgeSeconds@
maximum_bytes=@maximumBytes@
read_attempts=@readAttempts@
read_timeout_seconds=@readTimeoutSeconds@
retry_delay_seconds=@retryDelaySeconds@
schema_version=@schemaVersion@
sleep_command=@sleepCommand@
snapshot_path=@snapshotPath@
timeout_command=@timeoutCommand@

emit() {
  "$jq_command" -cn \
    --arg state "$1" \
    --argjson age "${2:-null}" \
    --argjson record "${3:-null}" \
    --argjson maximum "$maximum_age_seconds" '
      ($state == "fresh") as $usable
      | {
          state: $state,
          observedAt: (if $record == null then null else $record.sampledAt end),
          ageSeconds: (if $age != null and $usable and $age < 0 then 0 else $age end),
          maximumAgeSeconds: $maximum,
          physicalTotalBytes: (if $usable then $record.physicalTotalBytes else null end),
          physicalAvailableBytes: (if $usable then $record.physicalAvailableBytes else null end),
          commitUsedBytes: (if $usable then $record.commitUsedBytes else null end),
          commitLimitBytes: (if $usable then $record.commitLimitBytes else null end),
          wslConfig: (if $usable then $record.wslConfig else null end),
          wslVmCommitBytes: (if $usable then $record.wslVmCommitBytes else null end)
        }
    '
}

# 置換と読取りの重なりで一瞬だけ失敗するため再試行なしの単発読取りは不可
content=
read_succeeded=0
for ((attempt = 1; attempt <= read_attempts; attempt++)); do
  if content=$("$timeout_command" --signal=TERM --kill-after="${kill_after_seconds}s" "${read_timeout_seconds}s" \
    "$head_command" -c "$((maximum_bytes + 1))" -- "$snapshot_path" 2>/dev/null); then
    read_succeeded=1
    break
  fi
  if ((attempt < read_attempts)); then
    "$sleep_command" "$retry_delay_seconds"
  fi
done
if ((read_succeeded == 0)); then
  emit unavailable
  exit 0
fi

# 途中までの書込みと連結した record を通すため先頭 value だけの寛容な parse は不可
# Windows 側の collector は NixOS 側の配備とは別の command で更新するため、wslVmCommitBytes を持たない旧い collector の record も有効とする
if ((${#content} > maximum_bytes)) || ! record=$("$jq_command" -cse --argjson version "$schema_version" '
  def whole_count: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
  if length == 1
    and (.[0] | type) == "object"
    and (.[0] | del(.wslVmCommitBytes) | keys) == [
      "commitLimitBytes", "commitUsedBytes", "intervalSeconds", "physicalAvailableBytes",
      "physicalTotalBytes", "sampledAt", "schemaVersion", "sequence", "wslConfig"
    ]
    and (.[0] | del(.wslConfig, .wslVmCommitBytes) | [.[]] | all(whole_count))
    and (.[0].wslVmCommitBytes == null or (.[0].wslVmCommitBytes | whole_count))
    and (.[0].wslConfig | type) == "object"
    and (.[0].wslConfig | keys) == ["memoryBytes", "processors", "state"]
    and (.[0].wslConfig.state | IN("read", "missing", "unreadable"))
    and ([.[0].wslConfig.memoryBytes, .[0].wslConfig.processors] | all(. == null or (whole_count and . > 0)))
    and (.[0].wslConfig.state == "read" or (.[0].wslConfig.memoryBytes == null and .[0].wslConfig.processors == null))
    and .[0].schemaVersion == $version
    and .[0].sampledAt > 0
    and .[0].intervalSeconds >= 1
    and .[0].physicalTotalBytes > 0
    and .[0].physicalAvailableBytes <= .[0].physicalTotalBytes
    and .[0].commitLimitBytes > 0
  then .[0]
  else empty
  end
' <<<"$content" 2>/dev/null); then
  emit invalid
  exit 0
fi

now=$("$date_command" +%s 2>/dev/null) || now=
if [[ ! $now =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
  emit unavailable
  exit 0
fi

sampled_at=$("$jq_command" -r '.sampledAt' <<<"$record")
age=$((now - sampled_at))
if ((age < -future_skew_seconds)); then
  emit future "$age" "$record"
elif ((age > maximum_age_seconds)); then
  emit stale "$age" "$record"
else
  emit fresh "$age" "$record"
fi
