#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

check_receipt_boundaries() {
  local control=$fixture/stall-control previous=$PWD
  local name utility when pattern initial_runs retry_runs repository litter_before receipts_before status wrapper
  local proof limit foreign process_stat boot_id
  local denial_trace
  local -a process_fields
  local -x DOTFILES_AGENT_TEST_STALL=$control
  local -x STALL_RUNS=
  local -x PATH="$fixture/stall-bin:$PATH"

  mkdir "$fixture/stall-bin"
  cat >"$fixture/stall-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count=0
test ! -e "$STALL_RUNS" || count=$(cat "$STALL_RUNS")
printf '%s\n' "$((count + 1))" >"$STALL_RUNS"
SCRIPT
  chmod +x "$fixture/stall-bin/devenv"
  sed -i "1c#!$BASH" "$fixture/stall-bin/devenv"

  while read -r name utility when pattern initial_runs retry_runs <&3; do
    printf 'receipt boundary: %s\n' "$name" >&2
    reach_begin
    while :; do
      repository=$fixture/stall-$name-$reach_budget
      t1_repository "$repository" "$reach_budget"
      STALL_RUNS=$fixture/stall-$name-$reach_budget-runs
      litter_before=$(stall_litter)
      receipts_before=$(stall_receipt_count)
      cd "$repository"

      printf '%s %s %s\n' "$utility" "$when" "$pattern" >"$control"
      rm -f "$control.ready"
      set +e
      "$STALLING_VERIFY" -- devenv shell -- verify
      status=$?
      set -e
      rm -f "$control"
      # 期限が止める段階より先に来た走行は、負荷の表れとして予算を伸ばしてやり直す。印が無いまま 124 で返る場合のほか、
      # 段階を通る前の取消の後始末が同じ command を止める印を書いて取消を待ち続け、猶予の後の KILL で 137 になる場合もある
      if [ "$status" -eq 124 ] && [ -s "$control.ready" ]; then break; fi
      if [ "$status" -ne 124 ] && [ "$status" -ne 137 ]; then break; fi
      reach_widen "T1 stopped at $name"
    done
    if [ "$status" -ne 124 ]; then
      echo "T1 stopped at $name exited $status instead of the deadline status" >&2
      exit 1
    fi
    test "$(cat "$STALL_RUNS" 2>/dev/null || printf 0)" = "$initial_runs"
    expect_closed_gate "$repository" "$name"
    if [ "$(stall_litter)" != "$litter_before" ] || [ "$(stall_receipt_count)" != "$receipts_before" ]; then
      echo "T1 stopped at $name left receipts or temporary state behind" >&2
      printf 'temporary state before:\n%s\nafter:\n%s\nreceipts before=%s after=%s\n' \
        "$litter_before" "$(stall_litter)" "$receipts_before" "$(stall_receipt_count)" >&2
      exit 1
    fi

    widen_budget "$repository"
    "$STALLING_VERIFY" -- devenv shell -- verify
    expect_open_gate "$repository" "retry after $name"
    if [ "$(cat "$STALL_RUNS")" != "$retry_runs" ]; then
      echo "retry after $name ran the command $(cat "$STALL_RUNS") times instead of $retry_runs" >&2
      exit 1
    fi
    test "$(stall_litter)" = "$litter_before"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  done 3<<'SCENARIOS'
staged-after mv after */.pending.* 0 1
witness-cleanup-after rm after */.witness.* 0 1
publish-before mv before *.verified 1 2
publish-after mv after *.verified 1 2
SCENARIOS

  while read -r name utility when pattern initial_runs retry_runs <&4; do
    printf 'receipt cancellation: %s\n' "$name" >&2
    repository=$fixture/stall-$name
    t1_repository "$repository" 60
    STALL_RUNS=$fixture/stall-$name-runs
    litter_before=$(stall_litter)
    receipts_before=$(stall_receipt_count)
    cd "$repository"
    printf '%s %s %s\n' "$utility" "$when" "$pattern" >"$control"
    rm -f "$control.ready"
    "$STALLING_VERIFY" -- devenv shell -- verify &
    wrapper=$!
    for _ in $(seq 1 "$mark_polls"); do
      [ ! -s "$control.ready" ] || break
      sleep 0.05
    done
    if [ ! -s "$control.ready" ]; then
      kill -KILL "$wrapper"
      echo "T1 never reached the stage to cancel at: $name" >&2
      exit 1
    fi
    expect_closed_gate "$repository" "$name while publication is still running"
    kill -TERM "$wrapper"
    set +e
    wait "$wrapper"
    status=$?
    set -e
    rm -f "$control"
    if [ "$status" -eq 0 ]; then
      echo "a T1 cancelled at $name reported success" >&2
      exit 1
    fi
    test "$(cat "$STALL_RUNS" 2>/dev/null || printf 0)" = "$initial_runs"
    expect_closed_gate "$repository" "$name"
    if [ "$(stall_litter)" != "$litter_before" ] || [ "$(stall_receipt_count)" != "$receipts_before" ]; then
      echo "a T1 cancelled at $name left receipts or temporary state behind" >&2
      exit 1
    fi
    "$STALLING_VERIFY" -- devenv shell -- verify
    expect_open_gate "$repository" "retry after $name"
    test "$(cat "$STALL_RUNS")" = "$retry_runs"
    test "$(stall_litter)" = "$litter_before"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  done 4<<'SCENARIOS'
cancel-staged mv after */.pending.* 0 1
cancel-published mv after *.verified 1 2
SCENARIOS

  for name in late-source capture-source; do
    repository=$fixture/stall-$name
    git init -q "$repository"
    printf '.PHONY: verify\nverify:\n\tprintf old >> ../%s-result\n' "$name" >"$repository/Makefile"
    declare_budget "$repository" 60
    git -C "$repository" add Makefile tiergate.json
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    litter_before=$(stall_litter)
    cd "$repository"
    if [ "$name" = late-source ]; then pattern='*.verified'; else pattern='*/.pending.*'; fi
    printf 'mv after %s\n' "$pattern" >"$control"
    rm -f "$control.ready" "$control.release"
    "$STALLING_VERIFY" -- make verify &
    wrapper=$!
    for _ in $(seq 1 "$mark_polls"); do
      [ ! -s "$control.ready" ] || break
      sleep 0.05
    done
    if [ ! -s "$control.ready" ]; then
      kill -TERM "$wrapper"
      wait "$wrapper" || true
      echo "T1 never reached the source replacement boundary: $name" >&2
      exit 1
    fi
    printf '.PHONY: verify\nverify:\n\tprintf new >> ../%s-result\n' "$name" >Makefile
    touch "$control.release"
    wait "$wrapper"
    rm -f "$control" "$control.ready" "$control.release"
    expect_closed_gate "$repository" "$name unchecked replacement"
    if [ "$name" = late-source ]; then
      test "$(cat "$fixture/$name-result")" = old
    else
      test "$(cat "$fixture/$name-result")" = new
      printf '.PHONY: verify\nverify:\n\tprintf old >> ../%s-result\n' "$name" >Makefile
      expect_closed_gate "$repository" "$name discarded capture"
      printf '.PHONY: verify\nverify:\n\tprintf new >> ../%s-result\n' "$name" >Makefile
    fi
    "$STALLING_VERIFY" -- make verify
    expect_open_gate "$repository" "$name checked replacement"
    if [ "$name" = late-source ]; then
      test "$(cat "$fixture/$name-result")" = oldnew
    else
      test "$(cat "$fixture/$name-result")" = newnew
    fi
    test "$(stall_litter)" = "$litter_before"
  done

  for name in partial-marker producer-identity; do
    repository=$fixture/stall-$name
    git init -q "$repository"
    printf '.PHONY: verify\nverify:\n\tprintf once >> ../%s-result\n' "$name" >"$repository/Makefile"
    declare_budget "$repository" 60
    git -C "$repository" add Makefile tiergate.json
    git -C "$repository" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial
    cd "$repository"
    if [ "$name" = partial-marker ]; then
      printf 'mv after *.verified\n' >"$control"
      rm -f "$control.ready" "$control.release"
    fi
    "$STALLING_VERIFY" -- make verify &
    wrapper=$!
    if [ "$name" = partial-marker ]; then
      for _ in $(seq 1 "$mark_polls"); do
        [ ! -s "$control.ready" ] || break
        sleep 0.05
      done
      if [ ! -s "$control.ready" ]; then
        kill -TERM "$wrapper"
        wait "$wrapper" || true
        echo 'T1 never reached the partial completion boundary' >&2
        exit 1
      fi
      proof=$(find "$home/.cache/dotfiles-wsl/verification" -type f -name "*.$wrapper.verified")
      limit=$(($(stat -c %s "$proof") + 14))
      prlimit --pid "$wrapper" --fsize="$limit:"
      touch "$control.release"
      status=0
      wait "$wrapper" || status=$?
      rm -f "$control" "$control.ready" "$control.release"
      test "$status" -ne 0
      expect_closed_gate "$repository" 'failed partial completion'
      test ! -e "$proof"
      "$STALLING_VERIFY" -- make verify &
      wait "$!"
    else
      wait "$wrapper"
    fi
    expect_open_gate "$repository" "$name completed run"
    # 成功した走行を再利用しないため、失敗した完了記録の後の再試行は command を実行し直す
    if [ "$name" = partial-marker ]; then
      test "$(cat "$fixture/$name-result")" = onceonce
    else
      test "$(cat "$fixture/$name-result")" = once
    fi

    if [ "$name" = producer-identity ]; then
      proof=$(find "$home/.cache/dotfiles-wsl/verification" -type f -name "*.$wrapper.verified")
      truncate -s -1 "$proof"
      expect_closed_gate "$repository" 'unterminated completion marker'
      printf '\n' >>"$proof"
      expect_open_gate "$repository" 'restored complete marker'
      (
        sleep 60 &
        foreign=$!
        trap 'kill "$foreign" 2>/dev/null || true; wait "$foreign" 2>/dev/null || true' EXIT
        mv -- "$proof" "${proof%.*.verified}.$foreign.verified"
        proof=${proof%.*.verified}.$foreign.verified
        expect_open_gate "$repository" 'modeled reused producer PID'
        status=0
        strace -f -qq -e trace=openat -P "/proc/$foreign/stat" \
          -e inject=openat:error=EACCES -o "$fixture/producer-stat-denial.log" \
          "$GATE" check --repo "$repository" >/dev/null 2>&1 || status=$?
        denial_trace=$(<"$fixture/producer-stat-denial.log")
        if [ "$status" -ne 1 ] \
          || ! [[ $denial_trace == *"/proc/$foreign/stat"*EACCES*"(INJECTED)"* ]]; then
          echo 'gate did not reject a denied producer identity read' >&2
          exit 1
        fi
        expect_open_gate "$repository" 'recovered producer identity read'
        process_stat=$(<"/proc/$foreign/stat")
        read -r -a process_fields <<<"${process_stat##*) }"
        sed -i "s/^producer_start_time=.*/producer_start_time=${process_fields[19]}/" "$proof"
        expect_closed_gate "$repository" 'complete receipt with matching live producer'
        IFS= read -r boot_id </proc/sys/kernel/random/boot_id
        if [ "$boot_id" = 00000000-0000-0000-0000-000000000000 ]; then
          boot_id=11111111-1111-1111-1111-111111111111
        else
          boot_id=00000000-0000-0000-0000-000000000000
        fi
        sed -i \
          -e "s/^boot_id=.*/boot_id=$boot_id/" \
          -e "s/^producer_start_time=.*/producer_start_time=${process_fields[19]}/" "$proof"
        expect_open_gate "$repository" 'modeled previous boot producer'
      )
    fi
  done

  name=survivor
  reach_begin
  while :; do
    repository=$fixture/stall-$name-$reach_budget
    t1_repository "$repository" "$reach_budget"
    STALL_RUNS=$fixture/stall-$name-$reach_budget-runs
    litter_before=$(stall_litter)
    receipts_before=$(stall_receipt_count)
    cd "$repository"
    # 同じ木へ四度走らせるため、予算は書き換えられない。完走を期待する三走行のどれかが期限に達した、
    # または止める一走行が公開の前に期限に達したなら、負荷の表れとして予算を伸ばして最初からやり直す
    status=0
    "$STALLING_VERIFY" -- devenv shell -- verify || status=$?
    if [ "$status" -eq 124 ]; then
      reach_widen "T1 on the same tree ($name)"
      continue
    fi
    test "$status" -eq 0
    expect_open_gate "$repository" "$name completed run"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
    printf 'mv after *.verified\n' >"$control"
    rm -f "$control.ready"
    status=0
    "$STALLING_VERIFY" -- devenv shell -- verify || status=$?
    rm -f "$control"
    if [ "$status" -eq 124 ] && [ ! -s "$control.ready" ]; then
      reach_widen "T1 on the same tree ($name)"
      continue
    fi
    if [ "$status" -ne 124 ]; then
      echo "the second T1 on the same tree was not stopped during publication: $status" >&2
      exit 1
    fi
    expect_open_gate "$repository" "$name earlier completed receipt"
    test "$(stall_receipt_count)" = "$((receipts_before + 1))"
    for _ in 1 2; do
      status=0
      "$STALLING_VERIFY" -- devenv shell -- verify || status=$?
      if [ "$status" -eq 124 ]; then
        reach_widen "T1 on the same tree ($name)"
        continue 2
      fi
      test "$status" -eq 0
    done
    break
  done
  expect_open_gate "$repository" "$name repeated runs"
  # 公開で止めた二回目も含め、各走行は command を実行する
  test "$(cat "$STALL_RUNS")" = 4
  test "$(stall_receipt_count)" = "$((receipts_before + 1))"
  test "$(stall_litter)" = "$litter_before"

  cd "$previous"
}

check_receipt_boundaries
