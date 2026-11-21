set +x
# Side-effect-free stop invocation guidance
# Output: CLI usage on stdout
# Return: Successful help output status
usage() {
  cat <<'USAGE'
usage: dotfiles-sonarqube-stop [--help]

Stop the manually activated SonarQube backend. The operator entry is
  sudo systemctl start sonarqube-stop.service
and the backend is started again with
  sudo systemctl start sonarqube.target

Refuses while a dotfiles-sonarqube-scan run holds the analysis lock, while the
server unit is neither active nor stopped, while the active server is starting,
migrating or does not answer, and while Compute Engine tasks are pending or in
progress. Holds the analysis lock until the stop completes, so wrapper scans and
sonarqube.target starts are refused meanwhile. Stops only the SonarQube units;
named volumes and analysis history are kept.
Requires SONARQUBE_URL, SONARQUBE_ADMIN_PASSWORD_FILE and SONARQUBE_LIFECYCLE_LOCK.
USAGE
}

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ($1 == --help || $1 == -h) ]]; then
    usage
    exit 0
  fi
  usage >&2
  exit 2
fi

: "${SONARQUBE_URL:?server URL is required}"
: "${SONARQUBE_ADMIN_PASSWORD_FILE:?admin password file is required}"
: "${SONARQUBE_LIFECYCLE_LOCK:?analysis lock file is required}"

server_unit=@serverUnit@
stop_units=(@stopUnits@)

# Operator-facing refusal without any stop side effect
# Argument 1: Refusal reason
# Return: Never; exits with status 1
refuse() {
  echo "Refusing to stop SonarQube: $1" >&2
  exit 1
}

# Private curl configuration without a credential argv
# Argument 1: Single-line admin password
# Output: Basic authorization header configuration on stdout
# Return: Header encoding status
basic_header() {
  printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' "admin:$1" | base64 -w0)"
}

# 判定から停止の完了まで保持し、その間に始まる wrapper の scan を拒否させる
exec {lock_fd}<"$SONARQUBE_LIFECYCLE_LOCK" ||
  refuse "the analysis lock $SONARQUBE_LIFECYCLE_LOCK is unavailable"
flock --nonblock --exclusive "$lock_fd" ||
  refuse "a dotfiles-sonarqube-scan run holds the analysis lock; let it finish or cancel it first"

# activating や deactivating を停止済みと読むと起動中の backend を切るため受動的な状態の読取りが必須
state=$(systemctl show --property=ActiveState --value -- "$server_unit") || state=''
case $state in
  active)
    status=$(curl --silent --show-error --fail --max-time 10 "$SONARQUBE_URL/api/system/status" | jq -r '.status // empty') ||
      status=''
    case $status in
      UP)
        activity=$(
          basic_header "$(cat "$SONARQUBE_ADMIN_PASSWORD_FILE")" |
            curl --silent --show-error --fail --max-time 10 --config - "$SONARQUBE_URL/api/ce/activity_status"
        ) || refuse "could not read Compute Engine activity with the declared admin credential"
        # 失敗応答の小数・負数・指数表記を bash の算術へ渡さず、判定まで jq で閉じる
        verdict=$(
          jq -er '
            [.pending, .inProgress]
            | if all(.[]; type == "number" and . >= 0 and . == floor and (isinfinite | not))
              then if add == 0 then "idle" else "busy \(.[0]) \(.[1])" end
              else error("invalid Compute Engine counts")
              end
          ' <<<"$activity"
        ) || refuse "Compute Engine activity response has no pending and inProgress counts"
        if [[ $verdict != idle ]]; then
          read -r _ pending in_progress <<<"$verdict"
          refuse "$pending pending and $in_progress in-progress Compute Engine tasks; retry after they finish"
        fi
        ;;
      # API が答え、Compute Engine が動いていない状態
      DOWN | DB_MIGRATION_NEEDED) ;;
      '')
        refuse "$SONARQUBE_URL/api/system/status did not answer; retry once it answers, or stop the units directly as root if interrupting it is intended: ${stop_units[*]}"
        ;;
      *)
        refuse "server status is $status; retry once it is UP"
        ;;
    esac
    ;;
  inactive | failed) ;;
  *)
    refuse "$server_unit is ${state:-unobservable}; retry once it is active or stopped"
    ;;
esac

systemctl stop -- "${stop_units[@]}"
echo "SonarQube backend stopped; named volumes and analysis history are kept"
