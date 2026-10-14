event=$1
export client=$2
export client_root=$3
: "${FIXTURE_HOOK_DIR:?}" "${FIXTURE_NIX_LOG:?}"

printf 'hook %s %s\n' "$event" "$client" >>"$FIXTURE_NIX_LOG"
hook=$FIXTURE_HOOK_DIR/$event
if [[ -f $hook ]]; then
  # 一度だけ実行する。試験が書いた処理は $client と $client_root を使う
  mv -- "$hook" "$hook.done"
  # shellcheck disable=SC1090
  source "$hook.done"
fi
