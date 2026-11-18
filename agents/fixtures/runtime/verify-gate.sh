#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

# 宣言した入口でない呼び出しは、成功を保存せず毎回 command を実行する。
# 外部の状態を観測する command が、repository と環境と argv の一致だけで省かれてはならない。
check_wrapper_runs_every_time() {
  local repository=$fixture/runs-every-time external=$fixture/external-state
  local counter=$fixture/runs-every-time-count status output
  mkdir "$repository"
  git init -q "$repository"
  git -C "$repository" config user.name fixture
  git -C "$repository" config user.email fixture@example.invalid
  cat >"$repository/observe.sh" <<'SCRIPT'
read -r state <"$EXTERNAL_STATE"
printf 'observed=%s\n' "$state"
test "$state" = healthy
SCRIPT
  git -C "$repository" add observe.sh
  git -C "$repository" commit -qm initial
  printf 'healthy\n' >"$external"
  output=$(cd "$repository" && EXTERNAL_STATE=$external "$VERIFY" -- "$BASH" observe.sh)
  [ "$output" = observed=healthy ]
  printf 'unhealthy\n' >"$external"
  status=0
  output=$(cd "$repository" && EXTERNAL_STATE=$external "$VERIFY" -- "$BASH" observe.sh) || status=$?
  if [ "$status" -ne 1 ] || [ "$output" != observed=unhealthy ]; then
    echo "verify reused a success for a command whose external state changed: $status $output" >&2
    exit 1
  fi

  (cd "$repository" && COUNT=$counter "$VERIFY" -- "$fixture/check" first)
  (cd "$repository" && COUNT=$counter "$VERIFY" -- "$fixture/check" first)
  test "$(cat "$counter")" = 2
  status=0
  (cd "$repository" && COUNT=$counter CHECK_STATUS=7 "$VERIFY" -- "$fixture/check" first) || status=$?
  test "$status" -eq 7
  test "$(cat "$counter")" = 3

  # stdin、argv、stdout、stderr、終了 status は command へも呼び出し側へもそのまま届く
  status=0
  printf 'input\n' | (cd "$repository" && "$VERIFY" -- "$BASH" -c 'cat; printf "%s|" "$@" >&2; exit 3' _ 'a b' '') \
    >"$fixture/stdio-stdout" 2>"$fixture/stdio-stderr" || status=$?
  test "$status" -eq 3
  test "$(<"$fixture/stdio-stdout")" = input
  test "$(<"$fixture/stdio-stderr")" = 'a b||'

  # git の外でも、同じ呼び出しを保存した成功で省かない
  mkdir "$fixture/outside"
  (cd "$fixture/outside" && COUNT=$fixture/outside-count "$VERIFY" -- "$fixture/check" outside)
  (cd "$fixture/outside" && COUNT=$fixture/outside-count "$VERIFY" -- "$fixture/check" outside)
  test "$(cat "$fixture/outside-count")" = 2
}

# Skill の読取は編集の前提ではない。以前は読取を要求した綴り(.tsx、domain、core)の編集も、読取の有無では止まらない。
# 止めるのは編集した木へ検証入口がまだ通っていないことだけで、入口を通せば終了でき、再び編集すれば止まる。
# 旧 generation が session へ残した Skill の読取記録は、読む者がいないため終了を止めず、捨てられる。
freshness_edit() {
  jq -nc --arg session "$1" --arg cwd "$2" --arg path "$3" \
    '{session_id:$session,cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$path}}' |
    "$GATE" hook arm
}

freshness_stop() {
  jq -nc --arg session "$1" --arg cwd "$2" '{session_id:$session,cwd:$cwd}' | "$GATE" hook stop
}

check_edits_gate_on_freshness_only() {
  local repository=$fixture/freshness-only-repo session=fixture-freshness-only
  local session_dir=$home/.cache/dotfiles-wsl/verification/sessions/$session
  local path status
  local -a paths=(surfaces/viewer/App.tsx core/b/domain/Invoice.cs core/library.ts)

  t1_repository "$repository" 60
  for path in "${paths[@]}"; do
    mkdir -p "$repository/${path%/*}"
    printf 'held\n' >"$repository/$path"
  done
  git -C "$repository" add -- "${paths[@]}"
  git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm paths

  for path in "${paths[@]}"; do
    printf 'edited\n' >>"$repository/$path"
    freshness_edit "$session" "$repository" "$repository/$path"
  done
  status=0
  freshness_stop "$session" "$repository" >"$fixture/freshness.stdout" 2>/dev/null || status=$?
  if [ "$status" -ne 2 ] || [[ $(<"$fixture/freshness.stdout") != *'dotfiles-agent-verify -- devenv shell -- verify'* ]]; then
    echo "stop did not hold edited sources the entrance never ran on ($status)" >&2
    exit 1
  fi

  mkdir -p "$session_dir/skills"
  printf '%s\n%s\n' "$(printf stale | sha256sum | cut -d ' ' -f 1)" "$home/.omp/agent/skills/ui-design/SKILL.md" \
    >"$session_dir/skills/ui-design"
  (cd "$repository" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
  if ! freshness_stop "$session" "$repository" >/dev/null 2>&1; then
    echo 'stop held sources the entrance ran on, or a Skill read record an earlier generation left behind' >&2
    exit 1
  fi
  if [ -e "$session_dir/skills" ]; then
    echo 'stop kept the Skill read record nobody reads' >&2
    exit 1
  fi

  printf 'edited again\n' >>"$repository/${paths[0]}"
  freshness_edit "$session" "$repository" "$repository/${paths[0]}"
  status=0
  freshness_stop "$session" "$repository" >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 2 ]; then
    echo "stop did not hold sources edited after the entrance ran ($status)" >&2
    exit 1
  fi
}

# 免除は書いた session だけに効く。持ち主は launcher が client へ渡す DOTFILES_AGENT_SESSION_ID で、同じ launcher の
# session の hook は、payload の session が違っても同じ持ち主になる。agent の外の呼び出しは持ち主が空である。
# 引数 $1: 持ち主(空なら変数を持たない)、以降: gate の引数
as_owner() {
  local owner=$1
  shift
  if [ -n "$owner" ]; then
    DOTFILES_AGENT_SESSION_ID=$owner "$GATE" "$@"
  else
    env -u DOTFILES_AGENT_SESSION_ID "$GATE" "$@"
  fi
}

# 引数 $1: 期待する status、$2: 持ち主、$3: hook の payload の session、$4: repository、$5: 場面の名前
# 入力: stop_hook_active が true なら、client が再指示の中であることを payload で伝える。gate はこの値で終了を変えない
# 出力: gate の stdout を $fixture/stop-output へ、stderr を $fixture/stop-error へ残す
stop_hook_active=false
expect_stop_status() {
  local want=$1 owner=$2 payload=$3 repository=$4 status=0
  jq -nc --arg session "$payload" --arg cwd "$repository" --argjson active "$stop_hook_active" \
    '{session_id:$session,cwd:$cwd,stop_hook_active:$active}' |
    as_owner "$owner" hook stop >"$fixture/stop-output" 2>"$fixture/stop-error" || status=$?
  if [ "$status" -ne "$want" ]; then
    echo "stop by owner '$owner' under payload session '$payload' exited $status instead of $want: $5" >&2
    exit 1
  fi
}

waiver_repository=
waiver_payload=

# 引数 $1: 期待する status、$2: 持ち主、$3: stop か check、$4: 場面の名前
# 制約: stop は waiver_payload の session の控えを問い、どちらも waiver_repository の木を調べる
expect_waiver_status() {
  local want=$1 owner=$2 kind=$3 status=0
  case $kind in
  stop)
    expect_stop_status "$want" "$owner" "$waiver_payload" "$waiver_repository" "$4"
    return
    ;;
  check) as_owner "$owner" check --repo "$waiver_repository" >"$fixture/waiver-output" 2>&1 || status=$? ;;
  esac
  if [ "$status" -ne "$want" ]; then
    echo "$kind by owner '$owner' exited $status instead of $want: $4" >&2
    exit 1
  fi
}

# 引数 $1: repository の名前。未検証の木を作り、payload の session がそれを控えた状態にする
waiver_scene() {
  waiver_repository=$fixture/waiver-$1
  waiver_payload=fixture-waiver-$1
  t1_repository "$waiver_repository" 60
  as_owner '' arm --session "$waiver_payload" --path "$waiver_repository"
}

# 引数 $1: 持ち主。出力: その持ち主の名札
waiver_tag() {
  printf '%s' "$1" | sha256sum | cut -c 1-16
}

# 出力: waiver_repository の project の状態 directory
waiver_state() {
  printf '%s/.cache/dotfiles-wsl/verification/%s\n' "$home" \
    "$(printf '%s' "$(realpath -e -- "$waiver_repository/.git")" | sha256sum | cut -d ' ' -f 1)"
}

# 通った stop は控えを消すため、免除を受け入れない stop を先に問い、受け入れる stop は最後に問う。
# 続く場面で控えが要るときは、通った stop の後に控え直す。
check_waiver_is_scoped_to_its_session() {
  local state key file count

  # X の免除は X の stop と check だけを通す。別の持ち主と、持ち主が空の呼び出しは通らず、通らない理由を知らされる
  waiver_scene owners
  expect_waiver_status 2 X stop 'unverified tree before any waiver'
  as_owner X waive --repo "$waiver_repository" --reason 'owner x' >/dev/null
  expect_waiver_status 0 X check 'check of the owner that waived'
  expect_waiver_status 2 Y stop 'stop of another owner'
  expect_waiver_status 1 Y check 'check of another owner'
  if ! grep -qF '別の session が残した免除' "$fixture/waiver-output"; then
    echo 'check did not say that another session waived the tree' >&2
    exit 1
  fi
  expect_waiver_status 1 '' check 'check of an empty owner'
  expect_waiver_status 2 '' stop 'stop of an empty owner'
  expect_waiver_status 0 X stop 'stop of the owner that waived'
  as_owner '' arm --session "$waiver_payload" --path "$waiver_repository"

  # 同じ木を二つの session が免除しても、互いを上書きせず、それぞれが自分の分だけを通す
  as_owner Y waive --repo "$waiver_repository" --reason 'owner y' >/dev/null
  state=$(waiver_state)
  count=$(find "$state" -name '*.waived' -type f | wc -l)
  [ "$count" -eq 2 ] || { echo "two owners waiving one tree left $count files" >&2; exit 1; }
  expect_waiver_status 0 X check 'owner x after owner y waived the same tree'
  expect_waiver_status 0 Y check 'owner y that waived the same tree'
  expect_waiver_status 1 Z check 'a third owner next to two waivers'

  # 持ち主の行が名札と合わない記録は、他の持ち主の記録を自分の名札の名へ写しても通らない
  file=$(find "$state" -name "*.$(waiver_tag X).waived" -type f)
  key=${file##*/}
  key=${key%%.*}
  cp -- "$file" "$state/$key.$(waiver_tag Z).waived"
  expect_waiver_status 1 Z check 'record of owner x copied to the name of owner z'
  expect_waiver_status 2 Z stop 'record of owner x copied to the name of owner z'

  # 持ち主が空の免除は、持ち主が空の呼び出しだけを通す
  waiver_scene empty
  as_owner '' waive --repo "$waiver_repository" --reason 'no owner' >/dev/null
  expect_waiver_status 0 '' check 'check of an empty owner after an empty-owner waiver'
  expect_waiver_status 1 X check 'check of an owner next to an empty-owner waiver'
  expect_waiver_status 2 X stop 'stop of an owner next to an empty-owner waiver'
  expect_waiver_status 0 '' stop 'stop of an empty owner after an empty-owner waiver'

  # 旧い名の免除は、誰も通さない
  waiver_scene legacy
  as_owner X waive --repo "$waiver_repository" --reason 'to be renamed' >/dev/null
  state=$(waiver_state)
  file=$(find "$state" -name '*.waived' -type f)
  key=${file##*/}
  key=${key%%.*}
  rm -- "$file"
  printf 'version=1\nsource=%s\nreason=legacy\nat=then\n' "$key" >"$state/$key.waived"
  expect_waiver_status 1 X check 'legacy waiver, check of an owner'
  expect_waiver_status 1 '' check 'legacy waiver, check of an empty owner'
  expect_waiver_status 2 X stop 'legacy waiver, stop of an owner'

  # 同じ launcher の session は、payload の session が違っても同じ持ち主として免除を通す
  waiver_scene payloads
  as_owner X waive --repo "$waiver_repository" --reason 'shared launcher' >/dev/null
  waiver_payload="fixture-waiver-payloads-other"
  as_owner '' arm --session "$waiver_payload" --path "$waiver_repository"
  expect_waiver_status 2 Y stop 'another owner under another payload session'
  expect_waiver_status 0 X stop 'same owner under another payload session'

  # 改行を含む理由は、読む側が行を取り違えるため控えない
  waiver_scene multiline
  if as_owner X waive --repo "$waiver_repository" --reason $'first\nsecond' >/dev/null 2>&1; then
    echo 'waive accepted a reason that spans two lines' >&2
    exit 1
  fi
  if [ -n "$(find "$(waiver_state)" -name '*.waived' 2>/dev/null)" ]; then
    echo 'waive left a file for a reason it refused' >&2
    exit 1
  fi
}

# subagent は自分の session ID で hook を呼ぶが、終了の hook は親にしか来ない。控えは launcher の session ID(持ち主)の下にも
# 置かれ、親の終了が subagent だけの変更を拾う。hook の session の控えは、再開が同じ ID で拾うため残る。
# launcher の ID は PROJECT_ID.CLIENT.PID.SUFFIX の形で、名として使える。
check_stop_covers_subagent_changes() {
  local repository=$fixture/subagent-held resumed=$fixture/subagent-resumed external=$fixture/subagent-external
  local sessions=$home/.cache/dotfiles-wsl/verification/sessions count status=0 project l1 l2 l3
  project=$(printf subagent | sha256sum | cut -d ' ' -f 1)
  l1=$project.omp.1111.aaaaaaaaaaaa
  l2=$project.omp.2222.bbbbbbbbbbbb
  l3=$project.omp.3333.cccccccccccc

  t1_repository "$repository" 60
  as_owner "$l1" arm --session fixture-subagent --path "$repository"
  expect_stop_status 2 "$l1" fixture-parent "$repository" 'parent stop after a subagent changed the repository'
  expect_stop_status 0 "$l2" fixture-parent "$repository" 'stop under another launcher id'
  expect_stop_status 0 '' fixture-parent "$repository" 'stop outside any launcher session'

  # 同じ repository が二つの directory にあっても、一度だけ報告する
  as_owner "$l1" arm --session fixture-parent --path "$repository"
  expect_stop_status 2 "$l1" fixture-parent "$repository" 'repository armed under both directories'
  count=$(grep -c 'の検証入口が' "$fixture/stop-output" || true)
  if [ "$count" -ne 1 ]; then
    echo "stop reported a repository armed under both directories $count times" >&2
    exit 1
  fi
  (cd "$repository" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
  expect_stop_status 0 "$l1" fixture-parent "$repository" 'stop after the entrance ran'

  # 再開では、別の launcher の下でも、hook の session の控えが同じ ID の stop を止める
  t1_repository "$resumed" 60
  as_owner "$l1" arm --session fixture-resume --path "$resumed"
  expect_stop_status 2 "$l2" fixture-resume "$resumed" 'resume under another launcher id'

  # launcher の directory にも、hook の directory と同じ実 directory の検査が掛かる。symlink の先へは控えず、通しても読まない
  mkdir "$external"
  ln -s "$external" "$sessions/$l3"
  as_owner "$l3" arm --session fixture-linked --path "$resumed" 2>/dev/null || status=$?
  if [ "$status" -eq 0 ] || [ -n "$(find "$external" -mindepth 1)" ]; then
    echo "arm wrote through a launcher session directory that is a symlink, or reported success ($status)" >&2
    exit 1
  fi
  expect_stop_status 2 "$l3" fixture-unarmed "$resumed" 'stop through a launcher session directory that is a symlink'

  # 名として使えない launcher の ID は、状態を作らず、hook の session の控えだけを残す
  as_owner 'a/b' arm --session fixture-plain --path "$resumed"
  [ ! -e "$sessions/a" ] && [ -e "$sessions/fixture-plain" ] || {
    echo 'arm under an unusable launcher id created state outside the session directories' >&2
    exit 1
  }
}

# 同じ project の作業木は別の控えになる。片方の作業木だけを検証しても、もう片方を控えた session の終了は止まる。
# 作業木の中身が同じだと証跡は共有されるため、二つ目の作業木には未追跡の file を足して別の木にする。
check_worktrees_of_one_project_are_held_apart() {
  local first=$fixture/worktree-first second=$fixture/worktree-second session=fixture-worktrees

  t1_repository "$first" 60
  git -C "$first" worktree add -q --detach "$second"
  printf 'second only\n' >"$second/note"
  as_owner '' arm --session "$session" --path "$first"
  as_owner '' arm --session "$session" --path "$second"
  (cd "$second" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
  expect_stop_status 2 '' "$session" "$first" 'stop after only the second worktree was verified'
  if ! grep -qF "$(realpath -e -- "$first")" "$fixture/stop-output"; then
    echo 'stop did not name the worktree that was not verified' >&2
    exit 1
  fi
  (cd "$first" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
  expect_stop_status 0 '' "$session" "$first" 'stop after both worktrees were verified'
}

# 終了の確認に通った repository の控えは両方の directory から消え、通らなかった repository の控えは残る。
# 控えが消えた後は、他の session が変えた木で終了が止まらず、その session が再び変えれば止まる。
disarm_repository=
disarm_payload=
disarm_owner=

# 引数 $1: 場面の名前。未検証の木を作り、session が編集した状態にする。hook の session と launcher の session は場面ごとに別にする
disarm_scene() {
  disarm_repository=$fixture/disarm-$1
  disarm_payload=fixture-disarm-$1
  disarm_owner=fixture-disarm-owner-$1
  t1_repository "$disarm_repository" 60
  disarm_arm "$disarm_repository"
}

# 引数 $1: repository。session の編集として控える
disarm_arm() {
  as_owner "$disarm_owner" arm --session "$disarm_payload" --path "$1"
}

# 引数 $1: 期待する status、$2: 場面の名前
expect_disarm_stop() {
  expect_stop_status "$1" "$disarm_owner" "$disarm_payload" "$disarm_repository" "$2"
}

# 引数 $1: directory の名前。出力: session のその directory にある控えの数
marker_count() {
  find "$home/.cache/dotfiles-wsl/verification/sessions/$1" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l
}

# 引数 $1: 期待する数、$2: 場面の名前。hook の session と launcher の session の両方の directory を数える
expect_markers() {
  local directory
  for directory in "$disarm_payload" "$disarm_owner"; do
    if [ "$(marker_count "$directory")" -ne "$1" ]; then
      echo "session directory '$directory' holds $(marker_count "$directory") markers instead of $1: $2" >&2
      exit 1
    fi
  done
}

# 引数 $1: repository
verify_tree() {
  (cd "$1" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
}

# 引数 $1: PreToolUse か PostToolUse。disarm_repository を作業場所にした shell の呼び出しの観察
disarm_observe() {
  jq -nc --arg session "$disarm_payload" --arg event "$1" --arg cwd "$disarm_repository" \
    '{session_id:$session,hook_event_name:$event,tool_use_id:"disarm-call",cwd:$cwd,tool_name:"bash",tool_input:{command:"change"}}' |
    as_owner "$disarm_owner" hook observe
}

check_marker_is_released_by_a_passing_stop() {
  local second marker

  # 通った stop の後に他の session が木を変えても止まらず、その session が再び編集するか shell で変えれば止まる
  disarm_scene released
  expect_markers 1 'repository armed by an edit'
  verify_tree "$disarm_repository"
  expect_disarm_stop 0 'verified tree'
  expect_markers 0 'markers after the passing stop'
  printf 'another session\n' >"$disarm_repository/foreign"
  expect_disarm_stop 0 'tree changed by another session after the markers were released'
  disarm_arm "$disarm_repository"
  expect_disarm_stop 2 'own edit after the markers were released'
  verify_tree "$disarm_repository"
  expect_disarm_stop 0 'verified again'
  disarm_observe PreToolUse
  printf 'own shell change\n' >"$disarm_repository/own"
  disarm_observe PostToolUse
  expect_disarm_stop 2 'own shell change after the markers were released'

  # 通らない stop は控えを残す。client が再指示の中であると伝えても、終了は 2 のまま控えが残る
  disarm_scene failing
  expect_disarm_stop 2 'first failing stop'
  expect_markers 1 'markers after a failing stop'
  stop_hook_active=true
  expect_disarm_stop 2 'second failing stop with stop_hook_active'
  stop_hook_active=false
  expect_markers 1 'markers after a failing stop that was told it is inside a re-instruction'
  verify_tree "$disarm_repository"
  expect_disarm_stop 0 'verified after the failing stops'
  expect_markers 0 'markers after the verified stop'

  # 自分の免除で通った stop も控えを消す。通っていない木を他の session が変えても止まらず、自分が変えれば止まる
  disarm_scene waived
  as_owner "$disarm_owner" waive --repo "$disarm_repository" --reason 'own waiver' >/dev/null
  expect_disarm_stop 0 'stop passed by own waiver'
  expect_markers 0 'markers after the stop passed by own waiver'
  printf 'another session\n' >"$disarm_repository/foreign"
  expect_disarm_stop 0 'tree changed by another session after own waiver'
  disarm_arm "$disarm_repository"
  expect_disarm_stop 2 'own change after own waiver'

  # 別の持ち主の免除では通らず、控えは残る
  disarm_scene foreign-waiver
  as_owner "$disarm_owner-other" waive --repo "$disarm_repository" --reason 'another session' >/dev/null
  expect_disarm_stop 2 'stop with the waiver of another owner'
  expect_markers 1 'markers after a stop the waiver of another owner did not pass'

  # 入口を宣言しない repository では通り、控えは消える。入口が宣言された木を自分が編集すれば止まる
  disarm_scene no-entry
  rm "$disarm_repository/devenv.nix"
  expect_disarm_stop 0 'repository without a declared entry'
  expect_markers 0 'markers after the stop of a repository without a declared entry'
  git -C "$disarm_repository" checkout -q -- devenv.nix
  disarm_arm "$disarm_repository"
  expect_disarm_stop 2 'entry declared again and edited'

  # 木の鍵を採れない間は止まって控えが残り、直して検証すれば通って控えが消える
  disarm_scene untakable
  git init -q "$disarm_repository/nested"
  expect_disarm_stop 2 'tree whose key cannot be taken'
  expect_markers 1 'markers after a stop on a tree whose key cannot be taken'
  rm -rf "$disarm_repository/nested"
  verify_tree "$disarm_repository"
  expect_disarm_stop 0 'tree readable and verified'
  expect_markers 0 'markers after the stop that passed'

  # 二つの repository のうち通った方の控えだけが消え、通らない方の控えは残る
  disarm_scene two
  second=$fixture/disarm-two-second
  t1_repository "$second" 60
  disarm_arm "$second"
  verify_tree "$disarm_repository"
  expect_disarm_stop 2 'one of two repositories verified'
  expect_markers 1 'markers after one of two repositories passed'
  marker=$(find "$home/.cache/dotfiles-wsl/verification/sessions/$disarm_payload" -mindepth 1 -maxdepth 1 -type f)
  if [ "$(<"$marker")" != "$(realpath -e -- "$second")" ]; then
    echo 'the marker that stayed does not name the repository that did not pass' >&2
    exit 1
  fi

  # CLI の check は、通っても控えに触れない
  disarm_scene cli
  verify_tree "$disarm_repository"
  as_owner "$disarm_owner" check --repo "$disarm_repository" >/dev/null
  expect_markers 1 'markers after a passing CLI check'
}

# 検査の間に控え直された控えは、検査より後の変更を指すため、検査が通っても消さない。
# 入口の解決の最初の呼び出しで gate の arm を呼ぶ入口を挟み、検査の途中の控え直しを再現する。
check_marker_rearmed_during_the_check_is_kept() {
  local repository=$fixture/disarm-rearm payload=fixture-rearm owner=fixture-rearm-owner status=0

  t1_repository "$repository" 60
  as_owner "$owner" arm --session "$payload" --path "$repository"
  verify_tree "$repository"
  jq -nc --arg session "$payload" --arg cwd "$repository" '{session_id:$session,cwd:$cwd}' |
    REARM_SESSION=$payload REARM_PATH=$repository REARM_DONE=$fixture/rearm-done \
      DOTFILES_AGENT_SESSION_ID=$owner "$REARMING_GATE" hook stop >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ] || [ ! -e "$fixture/rearm-done" ]; then
    echo "the stop did not pass the verified tree, or the re-arm never happened during the check: $status" >&2
    exit 1
  fi
  if [ "$(marker_count "$payload")" -ne 1 ] || [ "$(marker_count "$owner")" -ne 1 ]; then
    echo 'a stop released a marker that was armed again while it was checking' >&2
    exit 1
  fi
  expect_stop_status 0 "$owner" "$payload" "$repository" 'stop after the re-arm, on the same verified tree'
  if [ "$(marker_count "$payload")" -ne 0 ] || [ "$(marker_count "$owner")" -ne 0 ]; then
    echo 'a stop that passed did not release the marker armed during the earlier check' >&2
    exit 1
  fi
}

# 門は、入口を宣言する repository でだけ「通っていない」と答える。
# 宣言が無ければ何も要求しない。
gate_repo=$fixture/gate-repo
mkdir -p "$gate_repo"
git -C "$gate_repo" init -q
git -C "$gate_repo" config user.name fixture
git -C "$gate_repo" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$gate_repo/devenv.nix"
printf 'held\n' >"$gate_repo/tracked"
declare_budget "$gate_repo" 60
git -C "$gate_repo" add devenv.nix tracked tiergate.json
git -C "$gate_repo" commit -qm initial
test "$("$GATE" entry --repo "$gate_repo")" = 'devenv shell -- verify'
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree the entrance never ran on' >&2
  exit 1
fi

# 門を開けるのは、宣言した入口を repository の根で通した走行だけである。部分的な検査や
# 下の directory での入口が通っても、この木で入口が通ったことにはならない。
mkdir -p "$fixture/entry-bin" "$gate_repo/nested"
cat >"$fixture/entry-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
chmod +x "$fixture/entry-bin/devenv"
sed -i "1c#!$BASH" "$fixture/entry-bin/devenv"
cd "$gate_repo"
COUNT=$fixture/gate-focused-count "$VERIFY" -- "$fixture/check" focused
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree on which only a focused check ran' >&2
  exit 1
fi
(cd "$gate_repo/nested" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree on which the entrance ran below the repository root' >&2
  exit 1
fi
PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$gate_repo" >/dev/null
printf 'changed\n' >"$gate_repo/tracked"
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree that changed after the entrance ran' >&2
  exit 1
fi
"$GATE" waive --repo "$gate_repo" --reason 'fixture' >/dev/null
"$GATE" check --repo "$gate_repo" >/dev/null 2>&1

# 入口を宣言しない repository は素通りする。
rm "$gate_repo/devenv.nix"
"$GATE" check --repo "$gate_repo" >/dev/null

# 門が問うのは T1 の verify だけである。push 前や全量の段だけを宣言する repository は止めない。
printf 'scripts.verify-push.exec = "true";\nscripts.verify-full.exec = "true";\n' >"$gate_repo/devenv.nix"
test -z "$("$GATE" entry --repo "$gate_repo")"
"$GATE" check --repo "$gate_repo" >/dev/null

# T2 の予算の欠けは push の時に初めて拒否されるので、作業の終わりの T1 で知らせる。push と関係の無い T1 は止めない
push_declared=$fixture/push-declared
t1_repository "$push_declared" 60
printf 'scripts.verify-push.exec = "true";\n' >>"$push_declared/devenv.nix"
git -C "$push_declared" -c user.name=fixture -c user.email=fixture@example.invalid commit -qam 'test: T2 の入口の追加'
(cd "$push_declared" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify) 2>"$fixture/push-declared-stderr"
expect_open_gate "$push_declared" 'T1 in a repository whose T2 budget is undeclared'
if ! grep -qF 'push は pre-push に拒否される' "$fixture/push-declared-stderr"; then
  echo 'T1 did not warn that the push will be refused for the undeclared T2 budget' >&2
  exit 1
fi
printf '{"version":1,"verify":{"seconds":60},"verify-push":{"seconds":60}}\n' >"$push_declared/tiergate.json"
git -C "$push_declared" -c user.name=fixture -c user.email=fixture@example.invalid commit -qam 'test: T2 の予算の追加'
(cd "$push_declared" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify) 2>"$fixture/push-declared-stderr"
if grep -qF 'push は pre-push に拒否される' "$fixture/push-declared-stderr"; then
  echo 'T1 warned about a T2 declaration that the push accepts' >&2
  exit 1
fi

# 門と T1 の照合は観察だけなので、作業木の stat が index と違っても index を書き直さない。
# 書き直しは index.lock を取り、hook の期限の SIGKILL で lock が残ると、その repository の commit を止める。
# 木の鍵のための index の写しと object は一時 directory へ置くため、実の .git の内容も、分割 index の共有 file も、作業木も変えない。
lock_repo=$fixture/lock-repo
t1_repository "$lock_repo" 60
printf 'held\n' >"$lock_repo/tracked"
git -C "$lock_repo" add tracked
git -C "$lock_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'test: 追跡する file の追加'
touch -d '2000-01-01 00:00' "$lock_repo/tracked"
lock_observe() {
  printf '{"session_id":"fixture-lock","hook_event_name":"%s","tool_use_id":"lock-call","cwd":"%s","tool_name":"bash","tool_input":{"command":"x"}}' \
    "$1" "$lock_repo" | "$GATE" hook observe
}
for lock_state in stat-dirty split-index; do
  if [ "$lock_state" = split-index ]; then
    git -C "$lock_repo" update-index --split-index
    printf 'edited\n' >"$lock_repo/tracked"
  fi
  index_before=$(stat -c '%i %y' "$lock_repo/.git/index")
  git_before=$(git_content_digest "$lock_repo")
  listing_before=$(tree_listing "$lock_repo")
  "$GATE" check --repo "$lock_repo" >/dev/null 2>&1 || true
  lock_observe PreToolUse
  lock_observe PostToolUse
  (cd "$lock_repo" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
  if [ "$(stat -c '%i %y' "$lock_repo/.git/index")" != "$index_before" ]; then
    echo "the gate rewrote the index of a repository it only observes ($lock_state)" >&2
    exit 1
  fi
  if [ "$(git_content_digest "$lock_repo")" != "$git_before" ] || [ -e "$lock_repo/.git/index.lock" ]; then
    echo "the gate changed the .git directory of a repository it only observes ($lock_state)" >&2
    exit 1
  fi
  if [ "$(tree_listing "$lock_repo")" != "$listing_before" ]; then
    echo "the gate left something in the work tree of a repository it only observes ($lock_state)" >&2
    exit 1
  fi
done

# 未追跡の綴りが増えた木も、通した木とは別物として扱う。
printf 'scripts.verify.exec = "true";\n' >"$gate_repo/devenv.nix"
git -C "$gate_repo" checkout -q -- tracked
PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$gate_repo" >/dev/null
printf 'new\n' >"$gate_repo/untracked"
if "$GATE" check --repo "$gate_repo" >/dev/null 2>&1; then
  echo 'gate passed a tree that gained an untracked file' >&2
  exit 1
fi

# shell の呼び出しは、作業場所の木を変えた時だけ stop で問う repository に加わる。
# 読むだけの呼び出しは、未検証の木の上でも stop を止めない。
shell_repo=$fixture/shell-repo
mkdir -p "$shell_repo"
git -C "$shell_repo" init -q
git -C "$shell_repo" config user.name fixture
git -C "$shell_repo" config user.email fixture@example.invalid
printf 'scripts.verify.exec = "true";\n' >"$shell_repo/devenv.nix"
printf 'held\n' >"$shell_repo/tracked"
declare_budget "$shell_repo" 60
git -C "$shell_repo" add devenv.nix tracked tiergate.json
git -C "$shell_repo" commit -qm initial
shell_observe() {
  printf '{"session_id":"fixture-shell","hook_event_name":"%s","tool_use_id":"%s","cwd":"%s","tool_name":"bash","tool_input":%s}' \
    "$1" "$2" "$3" "$4" | "$GATE" hook observe
}
shell_stop() {
  printf '{"session_id":"fixture-shell","cwd":"%s"}' "$shell_repo" |
    "$GATE" hook stop >/dev/null 2>&1
}
shell_observe PreToolUse read "$shell_repo" '{"command":"git status"}'
shell_observe PostToolUse read "$shell_repo" '{"command":"git status"}'
shell_stop
# 作業場所は tool の cwd を先に採り、session の cwd からの相対も解く。失敗した呼び出しでも、
# 変えた木は問う。
shell_observe PreToolUse write "$fixture" '{"command":"change","cwd":"shell-repo"}'
printf 'changed\n' >"$shell_repo/tracked"
shell_observe PostToolUseFailure write "$fixture" '{"command":"change","cwd":"shell-repo"}'
set +e
shell_stop
shell_stop_status=$?
set -e
if [ "$shell_stop_status" -ne 2 ]; then
  echo "stop did not hold a tree a shell call changed: $shell_stop_status" >&2
  exit 1
fi
(cd "$shell_repo" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
shell_stop

native_budget_repo=$fixture/native-missing-budget-repo
git init -q "$native_budget_repo"
printf '{ outputs = { self }: { apps.x86_64-linux.verify = { type = "app"; program = "/bin/false"; }; }; }\n' \
  >"$native_budget_repo/flake.nix"
printf '{"version":1,"frontend":"nix","entries":["verify"]}\n' >"$native_budget_repo/tiergate.json"
git -C "$native_budget_repo" add flake.nix tiergate.json
"$GATE" arm --session fixture-native-budget --path "$native_budget_repo/flake.nix"
set +e
printf '{"session_id":"fixture-native-budget","cwd":"%s"}' "$native_budget_repo" |
  "$GATE" hook stop >"$fixture/native-budget-stop.stdout" 2>"$fixture/native-budget-stop.stderr"
native_budget_stop_status=$?
set -e
test "$native_budget_stop_status" -eq 2
rm "$native_budget_repo/tiergate.json"
expect_closed_gate "$native_budget_repo" 'removed tracked native metadata'

check_wrapper_runs_every_time
check_edits_gate_on_freshness_only
check_waiver_is_scoped_to_its_session
check_stop_covers_subagent_changes
check_worktrees_of_one_project_are_held_apart
check_marker_is_released_by_a_passing_stop
check_marker_rearmed_during_the_check_is_kept
