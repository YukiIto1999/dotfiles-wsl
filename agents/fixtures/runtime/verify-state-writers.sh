#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

state_writers=$fixture/state-writers
state_home=$state_writers/home
state_cache=$state_home/.cache/dotfiles-wsl
state_external=$state_writers/external
state_dangling=$state_writers/dangling
state_repository=$state_writers/repository

state_fail() {
  echo "$1" >&2
  exit 1
}

external_state() {
  find "$1" -printf '%P %y %m %s %T@ %l\n' | LC_ALL=C sort
}

reset_state_home() {
  rm -rf "$state_home" "$state_external" "$state_dangling"
  mkdir -p "$state_home" "$state_external"
  printf 'sentinel\n' >"$state_external/sentinel"
  chmod 755 "$state_external"
  chmod 644 "$state_external/sentinel"
}

state_observe() {
  jq -nc --arg session "$state_session" --arg event "$1" --arg cwd "$state_repository" \
    '{session_id:$session,hook_event_name:$event,tool_use_id:"fixture-call",cwd:$cwd,tool_name:"bash",tool_input:{command:"change"}}' |
    "$GATE" hook observe
}

state_stop() {
  jq -nc --arg session "$1" --arg cwd "$state_repository" '{session_id:$session,cwd:$cwd}' |
    "$GATE" hook stop
}

state_writer() {
  case $1 in
  waive) "$GATE" waive --repo "$state_repository" --reason 'fixture reason' ;;
  arm) "$GATE" arm --session "$state_session" --path "$state_repository" ;;
  arm-hook)
    jq -nc --arg session "$state_session" --arg cwd "$state_repository" '{session_id:$session,cwd:$cwd}' |
      "$GATE" hook arm
    ;;
  observe) state_observe PreToolUse ;;
  esac
}

expect_state_writer_refusal() {
  local writer=$1 status=$2 context=$3
  case $writer in
  arm-hook | observe) [ "$status" -eq 0 ] || state_fail "$writer の拒否が hook を失敗させた($status): $context" ;;
  *) [ "$status" -ne 0 ] || state_fail "$writer が拒否すべき状態へ控えた: $context" ;;
  esac
  [ -s "$state_writers/stderr" ] || state_fail "$writer が拒否の理由を出さなかった: $context"
}

expect_state_content() {
  local writer=$1 file=$2
  case $writer in
  waive) grep -qx 'version=1' "$file" && grep -qx 'owner=' "$file" && grep -qx 'reason=fixture reason' "$file" ;;
  arm | arm-hook) [ "$(<"$file")" = "$(realpath -e -- "$state_repository")" ] ;;
  observe) [ "$(wc -l <"$file")" -eq 2 ] ;;
  esac || state_fail "$writer の控えの形が変わった: $file"
}

check_gate_state_writers() {
  local -x HOME=$state_home
  local home=$state_home state_session=fixture-writer
  local writer variant index status before state_file session_dir hash name previous_index
  local -a chain files writers=(waive arm arm-hook observe)

  mkdir -p "$state_writers"
  t1_repository "$state_repository" 60

  for writer in "${writers[@]}"; do
    reset_state_home
    state_writer "$writer" >/dev/null || state_fail "$writer が通常の状態で控えられなかった"
    mapfile -t chain < <(find "$state_cache" -type d | LC_ALL=C sort)
    mapfile -t files < <(find "$state_cache" -type f)
    [ "${#chain[@]}" -ge 3 ] && [ "${#files[@]}" -eq 1 ] || state_fail "$writer の控えの置き場所が想定と違う: ${chain[*]} ${files[*]}"
    expect_state_content "$writer" "${files[0]}"
    chmod 755 "${chain[@]}"
    state_writer "$writer" >/dev/null || state_fail "$writer が旧い mode の状態へ控えられなかった"
    for name in "${chain[@]}"; do
      [ "$(stat -c %a "$name")" = 700 ] || state_fail "$writer が $name を 0700 にしなかった"
    done
    expect_state_content "$writer" "${files[0]}"

    for index in "${!chain[@]}"; do
      for variant in symlink dangling file; do
        reset_state_home
        mkdir -p "$state_home/.cache"
        for ((previous_index = 0; previous_index < index; previous_index++)); do
          mkdir -m 700 "${chain[previous_index]}"
        done
        case $variant in
        symlink)
          mkdir -p "$state_external/${chain[-1]#"${chain[index]}"}"
          find "$state_external" -type d -exec chmod 755 {} +
          ln -s "$state_external" "${chain[index]}"
          ;;
        dangling) ln -s "$state_dangling" "${chain[index]}" ;;
        file) printf 'not a directory\n' >"${chain[index]}" ;;
        esac
        before=$(external_state "$state_external")
        status=0
        state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
        expect_state_writer_refusal "$writer" "$status" "$variant ${chain[index]}"
        [ "$(external_state "$state_external")" = "$before" ] || state_fail "$writer が $variant の先を変えた: ${chain[index]}"
        case $variant in
        symlink) [ -L "${chain[index]}" ] || state_fail "$writer が symlink を置き換えた: ${chain[index]}" ;;
        dangling) [ -L "${chain[index]}" ] && [ ! -e "$state_dangling" ] || state_fail "$writer が行き先の無い symlink の先を作った" ;;
        file) [ "$(<"${chain[index]}")" = 'not a directory' ] || state_fail "$writer が directory でない祖先を変えた" ;;
        esac
      done
    done

    for variant in symlink dangling directory; do
      reset_state_home
      state_writer "$writer" >/dev/null
      mapfile -t files < <(find "$state_cache" -type f)
      state_file=${files[0]}
      rm -- "$state_file"
      case $variant in
      symlink)
        printf 'external content\n' >"$state_external/target"
        chmod 640 "$state_external/target"
        ln -s "$state_external/target" "$state_file"
        ;;
      dangling) ln -s "$state_dangling" "$state_file" ;;
      directory) mkdir "$state_file" ;;
      esac
      before=$(external_state "$state_external")
      status=0
      state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
      expect_state_writer_refusal "$writer" "$status" "state file $variant"
      [ "$(external_state "$state_external")" = "$before" ] || state_fail "$writer が控えの置き場所の symlink の先を変えた"
      case $variant in
      symlink) [ -L "$state_file" ] || state_fail "$writer が控えの symlink を置き換えた" ;;
      dangling) [ -L "$state_file" ] && [ ! -e "$state_dangling" ] || state_fail "$writer が行き先の無い控えの symlink の先を作った" ;;
      directory) [ -d "$state_file" ] && [ ! -L "$state_file" ] || state_fail "$writer が控えの置き場所の directory を変えた" ;;
      esac
    done
  done

  for state_session in .. . a/b ../escape; do
    for writer in arm arm-hook observe; do
      reset_state_home
      status=0
      state_writer "$writer" >/dev/null 2>"$state_writers/stderr" || status=$?
      expect_state_writer_refusal "$writer" "$status" "session $state_session"
      [ ! -e "$state_cache" ] || state_fail "$writer が session $state_session で状態を作った"
    done
  done
  state_session='fixture-writer'

  reset_state_home
  state_session=fixture-other state_writer arm >/dev/null
  session_dir=$state_cache/verification/sessions/$state_session
  hash=$(printf '%s' fixture-call | sha256sum | cut -d ' ' -f 1)
  mkdir "$state_external/calls"
  printf 'stale-fingerprint\n%s\n' "$state_repository" >"$state_external/calls/$hash"
  ln -s "$state_external" "$session_dir"
  before=$(external_state "$state_external")
  status=0
  state_observe PostToolUse >/dev/null 2>"$state_writers/stderr" || status=$?
  expect_state_writer_refusal observe "$status" 'post phase through a linked session'
  [ "$(external_state "$state_external")" = "$before" ] || state_fail 'PostToolUse が外の session の記録を読んで消した'

  reset_state_home
  state_observe PreToolUse
  printf 'changed\n' >"$state_repository/state-writers-change"
  state_observe PostToolUse
  rm "$state_repository/state-writers-change"
  session_dir=$state_cache/verification/sessions/$state_session
  [ ! -e "$session_dir/calls/$hash" ] || state_fail 'PostToolUse が前の記録を捨てなかった'
  [ "$(find "$session_dir" -maxdepth 1 -type f | wc -l)" -eq 1 ] || state_fail '木を変えた呼び出しが repository を控えなかった'

  reset_state_home
  state_writer arm >/dev/null
  state_writer observe >/dev/null
  status=0
  state_stop "$state_session" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || state_fail "stop が未検証の木を止めなかった($status)"
  [ ! -e "$session_dir/calls" ] || state_fail 'stop が未対の呼び出しの控えを捨てなかった'
  [ "$(find "$session_dir" -maxdepth 1 -type f | wc -l)" -eq 1 ] || state_fail 'stop が再開のための控えを捨てた'
  state_writer waive >/dev/null
  state_stop "$state_session" >/dev/null 2>&1 || state_fail 'stop が理由を残した木を止めた'

  for variant in symlink dangling directory; do
    reset_state_home
    state_writer arm >/dev/null
    state_writer waive >/dev/null
    mapfile -t files < <(find "$session_dir" -maxdepth 1 -type f)
    state_file=${files[0]}
    mv "$state_file" "$state_external/marker"
    case $variant in
    symlink) ln -s "$state_external/marker" "$state_file" ;;
    dangling) ln -s "$state_dangling" "$state_file" ;;
    directory) mkdir "$state_file" ;;
    esac
    status=0
    state_stop "$state_session" >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ] || state_fail "stop が不正な控えを検証済みと扱った: $variant ($status)"
    [ -f "$state_external/marker" ] || state_fail 'stop が外の控えを削除した'
  done

  reset_state_home
  state_observe PreToolUse
  state_file=$session_dir/calls/$hash
  mv "$state_file" "$state_external/call"
  ln -s "$state_external/call" "$state_file"
  state_observe PostToolUse
  [ -L "$state_file" ] && [ -f "$state_external/call" ] || state_fail 'PostToolUse がsymlinkの控えを消費した'

  for variant in file directory; do
    reset_state_home
    state_writer waive >/dev/null
    mapfile -t files < <(find "$state_cache" -name '*.waived' -type f)
    state_file=${files[0]}
    [[ ${state_file##*/} == *.none.waived ]] || state_fail "waive が持ち主の名札を付けた名で控えなかった: $state_file"
    "$GATE" check --repo "$state_repository" >/dev/null 2>&1 || state_fail 'check が通常の免除を受理しなかった'
    if [ "$variant" = file ]; then
      mv "$state_file" "$state_external/waiver"
      ln -s "$state_external/waiver" "$state_file"
    else
      mv "${state_file%/*}" "$state_external/project"
      ln -s "$state_external/project" "${state_file%/*}"
    fi
    status=0
    "$GATE" check --repo "$state_repository" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || state_fail "check がsymlinkの免除を受理した: $variant"
  done

  reset_state_home
  state_writer arm >/dev/null
  rm -rf "$session_dir"
  mkdir "$state_external/calls"
  printf 'stale\n' >"$state_external/calls/leftover"
  printf '%s\n' "$state_repository" >"$state_external/marker"
  ln -s "$state_external" "$session_dir"
  before=$(external_state "$state_external")
  status=0
  state_stop "$state_session" >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ -s "$state_writers/stdout" ] && [ -s "$state_writers/stderr" ] \
    || state_fail "stop が実 directory でない session を通した($status)"
  [ "$(external_state "$state_external")" = "$before" ] || state_fail 'stop が外の session の calls を消した'
  rm "$session_dir"
  ln -s "$state_dangling" "$session_dir"
  status=0
  state_stop "$state_session" >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ ! -e "$state_dangling" ] || state_fail "stop が行き先の無い session の symlink を通した($status)"
  rm "$session_dir"
  mkdir -p "$state_cache/verification/calls"
  printf 'keep\n' >"$state_cache/verification/calls/keep"
  status=0
  state_stop .. >"$state_writers/stdout" 2>"$state_writers/stderr" || status=$?
  [ "$status" -eq 2 ] && [ -f "$state_cache/verification/calls/keep" ] || state_fail "stop が名の外の directory を辿った($status)"
}

check_gate_state_writers
