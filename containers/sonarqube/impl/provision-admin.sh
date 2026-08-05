# 公式 image は初期 admin password を環境変数で受けない。
# 起動後に一度だけ API で変更し、二度目以降は変更済みであることを確かめる
: "${SONARQUBE_URL:?server URL is required}"
: "${SONARQUBE_ADMIN_PASSWORD_FILE:?admin password file is required}"

deadline=$((SECONDS + 300))
until [[ $(curl -sS -m 10 "$SONARQUBE_URL/api/system/status" | jq -r '.status // empty') == UP ]]; do
  if ((SECONDS > deadline)); then
    echo "FATAL: SonarQube did not reach status UP within 300s" >&2
    exit 1
  fi
  sleep 5
done

# 資格情報は argv に載せない。curl の config は quote と backslash を escape として
# 解釈するので、password を文字列として渡さず base64 と file 参照で渡す
basic_header() {
  printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' "admin:$1" | base64 -w0)"
}

validates_as() {
  basic_header "$1" \
    | curl -sS -m 20 --config - "$SONARQUBE_URL/api/authentication/validate" \
    | jq -e '.valid == true' > /dev/null
}

declared=$(cat "$SONARQUBE_ADMIN_PASSWORD_FILE")

if validates_as "$declared"; then
  exit 0
fi

if ! validates_as admin; then
  echo "FATAL: neither the declared nor the default admin credential is accepted" >&2
  exit 1
fi

status=$(
  {
    basic_header admin
    printf 'data-urlencode = "login=admin"\n'
    printf 'data-urlencode = "previousPassword=admin"\n'
    printf 'data-urlencode = "password@%s"\n' "$SONARQUBE_ADMIN_PASSWORD_FILE"
  } | curl -sS -m 20 -o /dev/null -w '%{http_code}' --config - \
    "$SONARQUBE_URL/api/users/change_password"
)

if [[ $status != 204 ]]; then
  echo "FATAL: could not set the SonarQube admin password (HTTP $status)" >&2
  exit 1
fi

# 設定した値が実際に通ることを確かめる。file 読み取りと base64 の経路が一致する保証はない
validates_as "$declared"
