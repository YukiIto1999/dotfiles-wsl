set +x
usage() {
  cat <<'USAGE'
usage: dotfiles-sonarqube-provision [--help]

Validate the declared admin password, or replace the initial default password.
Requires SONARQUBE_URL and SONARQUBE_ADMIN_PASSWORD_FILE.
The credential file must contain the non-default password; never pass its value as an argument.
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

if [[ ! -s "$SONARQUBE_ADMIN_PASSWORD_FILE" ]]; then
  echo "SonarQube admin credential file is empty or unavailable" >&2
  exit 1
fi

deadline=$((SECONDS + 300))
until [[ $(curl --silent --show-error --max-time 10 "$SONARQUBE_URL/api/system/status" | jq -r '.status // empty') == UP ]]; do
  if ((SECONDS >= deadline)); then
    echo "SonarQube did not reach status UP within 300 seconds" >&2
    exit 1
  fi
  sleep 5
done

basic_header() {
  printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' "admin:$1" | base64 -w0)"
}

validates_as() {
  basic_header "$1" |
    curl --silent --show-error --max-time 20 --config - "$SONARQUBE_URL/api/authentication/validate" |
    jq -e '.valid == true' > /dev/null
}

declared=$(cat "$SONARQUBE_ADMIN_PASSWORD_FILE")
if [[ "$declared" == admin || "$declared" == *$'\n'* || "$declared" == *$'\r'* ]]; then
  echo "SonarQube admin password must be a non-default single-line value" >&2
  exit 1
fi
if validates_as "$declared"; then
  exit 0
fi
if ! validates_as admin; then
  echo "Neither the declared nor the default SonarQube admin credential is accepted" >&2
  exit 1
fi

status=$(
  {
    basic_header admin
    printf 'data-urlencode = "login=admin"\n'
    printf 'data-urlencode = "previousPassword=admin"\n'
    printf 'data-urlencode = "password@%s"\n' "$SONARQUBE_ADMIN_PASSWORD_FILE"
  } | curl --silent --show-error --max-time 20 --output /dev/null --write-out '%{http_code}' --config - \
    "$SONARQUBE_URL/api/users/change_password"
)
if [[ "$status" != 204 ]]; then
  echo "Could not set the SonarQube admin password (HTTP $status)" >&2
  exit 1
fi
validates_as "$declared"
