# 新しい標準の作業単位ごとに公開された最新の commit を一度だけ確かめ、隔離した build で検査した不変な source を返す。
# 問い合わせ、検査、版ごとの GC root の登録、最後に検査した版の公表を一つの lock の下で順に行う。
# 失敗は新しい作業だけを止め、昇格済みの版を残す。
set -euo pipefail

admitted_ids=(@admittedIds@)
remote_url=@remoteUrl@
remote_ref=@remoteRef@
ca_bundle=@caBundle@
archive_prefix=@archivePrefix@
state_relative=@stateRelative@
validator=@validator@
validation_expression=@validationExpression@
git_command=@gitCommand@
nix_build_command=@nixBuildCommand@
lookup_seconds=@lookupSeconds@
build_seconds=@buildSeconds@
lock_seconds=@lockSeconds@

program=dotfiles-standard-package

note() {
  printf '%s: %s\n' "$program" "$1" >&2
}

usage() {
  printf 'usage: %s open ID\n       %s status\n' "$program" "$program" >&2
  exit 64
}

case "${HOME-}" in
  /*) ;;
  *)
    note 'HOME is not an absolute path'
    exit 70
    ;;
esac
package_dir="$HOME/$state_relative/standard-package"
# root 登録に成功した版だけを指す。読み手はセッションをまたいでも版固有の原版を使う。
last_good="$package_dir/last-good"

# 最後に検査した版。root が無ければ空、読めなければ非ゼロ
last_good_record() {
  local output revision root
  if [ ! -e "$last_good" ] && [ ! -L "$last_good" ]; then
    return 0
  fi
  output=$(readlink -e -- "$last_good") || return 1
  revision=$(<"$output/revision") || return 1
  root=$(readlink -- "$output/source") || return 1
  if [[ ! $revision =~ ^[0-9a-f]{40}$ ]] || [[ $root != /* ]]; then
    return 1
  fi
  jq -cn --arg revision "$revision" --arg root "$root" '{revision: $revision, root: $root}'
}

# 最後に検査した版は stderr で示し、stdout には返さない
fail_new_work() {
  local record
  note "$2; new standard work is not started"
  if ! record=$(last_good_record); then
    note "the last validated revision is unreadable: $last_good"
  elif [ -n "$record" ]; then
    note "$(jq -r '"last validated revision \(.revision) at \(.root)"' <<<"$record")"
  else
    note 'no validated revision is recorded'
  fi
  exit "$1"
}

open_package() {
  local id=$1 candidate admitted=false lock_fd revision='' hash ref output status=0
  for candidate in "${admitted_ids[@]}"; do
    if [ "$candidate" = "$id" ]; then
      admitted=true
    fi
  done
  if [ "$admitted" = false ]; then
    note "not an admitted standard Skill ID: $id (admitted: ${admitted_ids[*]})"
    exit 64
  fi

  mkdir -p -- "$HOME/$state_relative"
  mkdir -m 700 -- "$package_dir" 2>/dev/null || true
  if [ -L "$package_dir" ] || [ ! -d "$package_dir" ] || [ "$(stat -c %u -- "$package_dir")" != "$(id -u)" ]; then
    fail_new_work 70 "the state directory is not a directory of this user: $package_dir"
  fi
  mkdir -p -- "$package_dir/revisions"
  exec {lock_fd}>>"$package_dir/writer.lock"
  if ! flock -w "$lock_seconds" -x "$lock_fd"; then
    fail_new_work 75 "another standard work unit held the resolver for ${lock_seconds}s"
  fi

  # 利用者と repository の Git 設定、credential、hook を読まない匿名の問い合わせ。CA だけを host から渡す
  output=$(timeout --kill-after=5 "$lookup_seconds" env -i HOME=/var/empty PATH=/var/empty \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https \
    GIT_SSL_CAINFO="$ca_bundle" \
    "$git_command" -C / ls-remote --exit-code -- "$remote_url" "$remote_ref") || status=$?
  while IFS=$'\t' read -r hash ref; do
    [[ $ref == "$remote_ref" ]] || continue
    if [[ -n $revision || ! $hash =~ ^[0-9a-f]{40}$ ]]; then
      fail_new_work 69 "the published $remote_ref did not identify one commit"
    fi
    revision=$hash
  done <<<"$output"
  if [[ $status != 0 || -z $revision ]]; then
    fail_new_work 69 "the published $remote_ref of $remote_url could not be confirmed (status $status)"
  fi

  # root 登録に失敗して Nix が out-link だけを残す場合も、last-good は動かさない。
  output=$(timeout --kill-after=10 "$build_seconds" "$nix_build_command" \
    --out-link "$package_dir/revisions/$revision" \
    --option netrc-file /dev/null \
    --option access-tokens '' \
    "$validation_expression" \
    --argstr validator "$validator" \
    --argstr archive "$archive_prefix$revision.tar.gz" \
    --argstr revision "$revision") || status=$?
  case "$status" in
    0) ;;
    124 | 137) fail_new_work 75 "revision $revision was not fetched and validated within ${build_seconds}s" ;;
    *) fail_new_work 65 "revision $revision could not be fetched, validated, and retained" ;;
  esac
  output=$(tail -n 1 <<<"$output")

  if [[ $(readlink -e -- "$package_dir/revisions/$revision") != "$output" ]] ||
    ! ln -sfnT -- "revisions/$revision" "$last_good"; then
    fail_new_work 70 "revision $revision was validated but could not become the last validated revision"
  fi
  printf '%s\n' "$(readlink -- "$output/source")/skills/$id/SKILL.md"
}

case "${1-}" in
  open)
    if [ "$#" -ne 2 ]; then
      usage
    fi
    open_package "$2"
    ;;
  status)
    if [ "$#" -ne 1 ]; then
      usage
    fi
    if ! record=$(last_good_record); then
      note "the last validated revision is unreadable: $last_good"
      exit 70
    fi
    jq -cn --argjson record "${record:-null}" '{lastGood: $record}'
    ;;
  *) usage ;;
esac
