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
lock_repo=$fixture/lock-repo
t1_repository "$lock_repo" 60
printf 'held\n' >"$lock_repo/tracked"
git -C "$lock_repo" add tracked
git -C "$lock_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'test: 追跡する file の追加'
touch -d '2000-01-01 00:00' "$lock_repo/tracked"
index_before=$(stat -c '%i %y' "$lock_repo/.git/index")
"$GATE" check --repo "$lock_repo" >/dev/null 2>&1 || true
(cd "$lock_repo" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
if [ "$(stat -c '%i %y' "$lock_repo/.git/index")" != "$index_before" ]; then
  echo 'the gate rewrote the index of a repository it only observes' >&2
  exit 1
fi

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
