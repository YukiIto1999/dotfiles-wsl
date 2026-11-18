#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

expect_budget_refused() {
  local repository=$1 name=$2 status=0 litter receipts
  litter=$(stall_litter)
  receipts=$(stall_receipt_count)
  rm -f "$fixture/refused-runs"
  (cd "$repository" && PATH="$fixture/budget-bin:$PATH" DEADLINE_RUNS=$fixture/refused-runs \
    "$VERIFY" -- devenv shell -- verify) 2>"$fixture/refused-stderr" || status=$?
  if [ "$status" -ne 78 ]; then
    echo "T1 with a $name budget exited $status instead of the configuration status" >&2
    exit 1
  fi
  if [[ $(<"$fixture/refused-stderr") != *tiergate.json* ]]; then
    echo "T1 with a $name budget did not name the declaration it refused" >&2
    exit 1
  fi
  if [ -e "$fixture/refused-runs" ]; then
    echo "T1 with a $name budget ran the entry" >&2
    exit 1
  fi
  expect_closed_gate "$repository" "$name budget"
  if [ "$(stall_litter)" != "$litter" ] || [ "$(stall_receipt_count)" != "$receipts" ]; then
    echo "T1 with a $name budget left receipts or temporary state behind" >&2
    exit 1
  fi
}

budget_repo=$fixture/budget-repo
t1_repository "$budget_repo" 2
mkdir "$fixture/budget-bin"
cat >"$fixture/budget-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
if [ -n "${DEADLINE_RUNS-}" ]; then
  printf 'run\n' >>"$DEADLINE_RUNS"
fi
if [ -n "${DEADLINE_REWRITE-}" ]; then
  printf '{"version":1,"verify":{"seconds":60}}\n' >"$DEADLINE_REWRITE"
fi
if [ "${DEADLINE_SLOW-}" = 1 ]; then
  (sleep 3; touch "$DEADLINE_LATE") &
  wait
fi
if [ "${DEADLINE_SLOW-}" = session ]; then
  setsid bash -c 'printf "%s\n" "$$" >"$DEADLINE_PID"; sleep "${DEADLINE_SLEEP:-4}"; touch "$DEADLINE_LATE"' </dev/null >/dev/null 2>&1 &
  wait
fi
SCRIPT
chmod +x "$fixture/budget-bin/devenv"
sed -i "1c#!$BASH" "$fixture/budget-bin/devenv"
test "$("$GATE" budget --repo "$budget_repo")" = 2
cd "$budget_repo"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/deadline-late \
  "$VERIFY" -- devenv shell -- verify 2>"$fixture/deadline.stderr"
deadline_status=$?
set -e
cat "$fixture/deadline.stderr" >&2
test "$deadline_status" -eq 124
# 時間切れの一行は、資源の記録を持たない走行でも数値を添えずに出る
test "$(grep -c '時間切れ(124)で止まった。' "$fixture/deadline.stderr")" -eq 1
if "$GATE" check --repo "$budget_repo" >/dev/null 2>&1; then
  echo 'the timed-out T1 left an accepted source receipt' >&2
  exit 1
fi
sleep 4
test ! -e "$fixture/deadline-late"
# 期限に達した走行の後の再走は完走を期待するので、予算の宣言を書き換える
widen_budget "$budget_repo"
PATH="$fixture/budget-bin:$PATH" "$VERIFY" -- devenv shell -- verify
"$GATE" check --repo "$budget_repo" >/dev/null

reach_begin
while :; do
  escape_repo=$fixture/session-escape-budget-repo-$reach_budget
  t1_repository "$escape_repo" "$reach_budget"
  cd "$escape_repo"
  rm -f "$fixture/escaped.pid" "$fixture/escaped-late"
  set +e
  PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=session DEADLINE_SLEEP=$((reach_budget + 2)) \
    DEADLINE_PID=$fixture/escaped.pid DEADLINE_LATE=$fixture/escaped-late "$VERIFY" -- devenv shell -- verify
  escape_status=$?
  set -e
  # 期限が別 session の遅延書込みの起動より先に来た走行は、負荷の表れとして予算を伸ばしてやり直す
  if [ "$escape_status" -ne 124 ] || [ -s "$fixture/escaped.pid" ]; then break; fi
  reach_widen 'T1 entry that starts a delayed writer in its own session'
done
test "$escape_status" -eq 124
if process_alive "$(<"$fixture/escaped.pid")"; then
  echo 'T1 returned at its budget while a descendant in its own session was still running' >&2
  exit 1
fi
if [ -e "$fixture/escaped-late" ]; then
  echo 'a descendant in its own session wrote after T1 returned at its budget' >&2
  exit 1
fi
expect_closed_gate "$escape_repo" 'descendant in its own session'

long_budget_repo=$fixture/long-budget-repo
t1_repository "$long_budget_repo" "$completion_budget"
test "$("$GATE" budget --repo "$long_budget_repo")" = "$completion_budget"
cd "$long_budget_repo"
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/long-deadline-late \
  "$VERIFY" -- devenv shell -- verify
test -e "$fixture/long-deadline-late"
expect_open_gate "$long_budget_repo" 'project that declared a larger budget'

rewrite_repo=$fixture/rewrite-budget-repo
t1_repository "$rewrite_repo" 2
cd "$rewrite_repo"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_SLOW=1 DEADLINE_LATE=$fixture/rewrite-late \
  DEADLINE_REWRITE=$rewrite_repo/tiergate.json "$VERIFY" -- devenv shell -- verify
rewrite_status=$?
set -e
test "$rewrite_status" -eq 124
expect_closed_gate "$rewrite_repo" 'budget rewritten during the run'
sleep 4
test ! -e "$fixture/rewrite-late"

resolution_repo=$fixture/slow-resolution-repo
t1_repository "$resolution_repo" 2
cd "$resolution_repo"
litter_before=$(stall_litter)
receipts_before=$(stall_receipt_count)
rm -f "$fixture/resolution-runs"
set +e
PATH="$fixture/budget-bin:$PATH" DEADLINE_RUNS=$fixture/resolution-runs \
  "$SLOW_RESOLUTION_VERIFY" -- devenv shell -- verify
resolution_status=$?
set -e
test "$resolution_status" -eq 124
test ! -e "$fixture/resolution-runs"
expect_closed_gate "$resolution_repo" 'resolution that used the whole budget'
test "$(stall_litter)" = "$litter_before"
test "$(stall_receipt_count)" = "$receipts_before"

undeclared_repo=$fixture/undeclared-budget-repo
git init -q "$undeclared_repo"
printf 'scripts.verify.exec = "true";\n' >"$undeclared_repo/devenv.nix"
git -C "$undeclared_repo" add devenv.nix
git -C "$undeclared_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
expect_budget_refused "$undeclared_repo" absent
while read -r name content <&5; do
  printf '%s\n' "$content" >"$undeclared_repo/tiergate.json"
  expect_budget_refused "$undeclared_repo" "$name"
done 5<<'BUDGETS'
zero {"version":1,"verify":{"seconds":0}}
negative {"version":1,"verify":{"seconds":-5}}
fractional {"version":1,"verify":{"seconds":1.5}}
string {"version":1,"verify":{"seconds":"120"}}
oversized {"version":1,"verify":{"seconds":2147483648}}
version {"version":2,"verify":{"seconds":120}}
stage-missing {"version":1}
seconds-missing {"version":1,"verify":{}}
other-stage {"version":1,"verify-push":{"seconds":120}}
array []
malformed {"version":1,
BUDGETS
cd "$undeclared_repo"
COUNT=$fixture/undeclared-focused-count "$VERIFY" -- "$fixture/check" focused
test "$(cat "$fixture/undeclared-focused-count")" = 1
expect_closed_gate "$undeclared_repo" 'focused check beside an unreadable budget'
