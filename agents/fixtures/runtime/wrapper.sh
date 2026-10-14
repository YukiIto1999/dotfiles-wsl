#!/usr/bin/env bash
# mkWrapper が作った実際の wrapper を通して、共通の方針、lifecycle、保護が一度ずつ順に働くことを、
# 起動された client が見る環境と GC root から読む。
set -euo pipefail

fixture=$PWD/wrapper-fixture
home=$fixture/home
project=$fixture/project
cache=$home/.cache/dotfiles-wsl
mkdir -p "$home" "$project"
export HOME=$home
export CAPTURE=$fixture/capture
export NIX_STORE_LOG=$fixture/nix-store.log
export SYSTEMCTL_LOG=$fixture/systemctl.log
export SYSTEMD_RUN_CAPTURE=$fixture/systemd-run
mkdir -p "$CAPTURE"
: > "$NIX_STORE_LOG"
unset CARGO_HOME CARGO_TARGET_DIR CARGO_BUILD_BUILD_DIR XDG_CACHE_HOME TMPDIR
cd "$project"

fail() {
  echo "$*" >&2
  exit 1
}

read_capture() {
  cat "$CAPTURE/$1"
}

store_object() {
  local path=$1 rest
  rest=${path#/nix/store/}
  echo "/nix/store/${rest%%/*}"
}

# Unset cache variables get the shared defaults once, and the client starts in a registered session.
wrapper_args=('' 'space arg' $'line\narg' 'ユニコード' -- --protect)
status=0
FAKE_STATUS=19 "$WRAPPER" "${wrapper_args[@]}" || status=$?
test "$status" -eq 19
test "$(read_capture env-CARGO_HOME)" = "set:$cache/shared/cargo-home"
test "$(read_capture env-XDG_CACHE_HOME)" = "set:$cache/shared/xdg-cache"
test "$(read_capture env-CARGO_BUILD_BUILD_DIR)" = "set:$cache/cargo-build/{workspace-path-hash}"
test "$(read_capture env-CARGO_TARGET_DIR)" = unset
case "$(read_capture nix-command)" in
  /nix/store/*-dotfiles-nix-build-shims/bin/nix) ;;
  *) fail "the client does not see the shared no-result-link shims: $(read_capture nix-command)" ;;
esac
case "$(read_capture nix-build-command)" in
  /nix/store/*-dotfiles-nix-build-shims/bin/nix-build) ;;
  *) fail "the client does not see the no-result-link nix-build shim" ;;
esac
test "$(read_capture env-TMPDIR)" = "set:$(read_capture session-dir)/tmp"
test "$(read_capture argv0)" = "$FAKE_AGENT"
mapfile -d '' -t argv < "$CAPTURE/argv"
test "${#argv[@]}" -eq 6
test -z "${argv[0]}"
test "${argv[1]}" = 'space arg'
test "${argv[2]}" = $'line\narg'
test "${argv[3]}" = 'ユニコード'
test "${argv[4]}" = --
test "${argv[5]}" = --protect
test "$(read_capture cwd)" = "$(realpath "$project")"

# The wrapper, the lifecycle, every declared dependency, and the executable are rooted for the session.
wrapper_object=$(store_object "$(realpath "$WRAPPER")")
launcher_object=$(store_object "$(realpath "$LAUNCHER")")
printf '%s\n' \
  "${wrapper_object##*/} $wrapper_object" \
  "${launcher_object##*/} $launcher_object" \
  "${DEPENDENCY_A##*/} $DEPENDENCY_A" \
  "${DEPENDENCY_B##*/} $DEPENDENCY_B" \
  "${FAKE_AGENT##*/} $FAKE_AGENT" | sort > "$fixture/expected-roots"
diff "$fixture/expected-roots" "$CAPTURE/roots"

# Explicit values, including empty strings, and a project's own Cargo setting survive both layers.
env 'CARGO_HOME=' 'XDG_CACHE_HOME=' 'CARGO_BUILD_BUILD_DIR=' 'TMPDIR=' "$WRAPPER"
test "$(read_capture env-CARGO_HOME)" = 'set:'
test "$(read_capture env-XDG_CACHE_HOME)" = 'set:'
test "$(read_capture env-CARGO_BUILD_BUILD_DIR)" = 'set:'
test "$(read_capture env-TMPDIR)" = 'set:'
mkdir -p "$project/.cargo"
printf '[build]\ntarget-dir = "project-output"\n' > "$project/.cargo/config.toml"
"$WRAPPER"
test "$(read_capture env-CARGO_BUILD_BUILD_DIR)" = unset
test "$(read_capture env-CARGO_HOME)" = "set:$cache/shared/cargo-home"
rm "$project/.cargo/config.toml"

# A dependency that cannot be protected stops the wrapper before the client starts.
rm -f "$CAPTURE/agent-pid"
status=0
FAKE_NIX_STORE_FAIL=${DEPENDENCY_B##*/} "$WRAPPER" 2>/dev/null || status=$?
test "$status" -ne 0
test ! -e "$CAPTURE/agent-pid"
test -z "$(ls -A "$cache/sessions")"

: "${MODULE_WRAPPER:?}" "${WRAPPER_CLOSURE:?}" "${GATE:?}" "${STANDARD_ROOT:?}" "${SKILL_ROOT:?}" "${SKILL_SOURCE:?}"
store=$fixture/store
gcroots=$fixture/gcroots
audited=$fixture/audited
report=$fixture/report.json
deployed=$home/$SKILL_ROOT/standard-conformance
mkdir -p "$store" "$gcroots" "$audited/docs" "$home/$SKILL_ROOT"

declare -A references=() live=()
while read -r object && read -r _ && read -r _ && read -r _ && read -r count; do
  found=()
  for ((index = 0; index < count; index++)); do
    read -r reference
    found+=("$reference")
  done
  references[$object]=${found[*]}
done < "$WRAPPER_CLOSURE/registration"

# 生存 root から到達する store object の模擬 GC 用の記録
# 引数 $1: 保持する Nix store object の絶対 path
# 前提: module wrapper の実参照 graph の読込済み状態
# 副作用: 参照 closure の live への追記
# 戻り値: 到達記録完了時の0
mark_live() {
  local object=$1 reference
  [ -z "${live[$object]:-}" ] || return 0
  live[$object]=1
  for reference in ${references[$object]:-}; do
    mark_live "$reference"
  done
}

# sandbox の store は削除不能のため実 store への GC は不可
# Nix の GC は root の closure を保持するため root 名の一致だけでの判定は不可
# 生存 root の closure に含まれない私有 store の写しの削除
# 前提: 当該 fixture の session root と参照 graph の初期化済み状態
# 副作用: 当該 fixture の私有 store だけの GC
# 戻り値: 回収完了時の0
fixture_gc() {
  local root entry object
  live=()
  for root in "$cache"/sessions/*/roots/* "$gcroots"/*; do
    [ -L "$root" ] || continue
    mark_live "$(store_object "$(readlink -- "$root")")"
  done
  for entry in "$store"/*; do
    [ -e "$entry" ] || continue
    object=/nix/store/${entry##*/}
    [ -n "${live[$object]:-}" ] || rm -rf -- "$entry"
  done
}

# session の起動と解放の同期に用いる file 出現待機
# 引数 $1: 出現を観測する fixture file の絶対 path
# 戻り値: 対象 file の出現時の0
# 失敗: 待機上限の超過による fixture 終了
wait_for_file() {
  local path=$1
  for _ in $(seq 1 1500); do
    [ -e "$path" ] && return 0
    sleep 0.02
  done
  fail "timed out waiting for $path"
}

# 旧世代 Skill の実読取情報による gate の学習記録
# 引数 $1: wrapper が発行した当該 session の ID
# 引数 $2: 論理配備先から読み取る Skill 本文の path
# 副作用: 指定 session の読取記録の更新
# 戻り値: gate の学習 command の終了 status
skill_read_event() {
  local session=$1 body=$2 resolved
  resolved=$(realpath -e -- "$body")
  jq -nc --rawfile text "$body" --arg session "$session" --arg cwd "$project" --arg path "$body" \
    --arg resolved "$resolved" '
    ($text | gsub("\r\n?"; "\n") | sub("^\uFEFF"; "")) as $normalized |
    ($normalized | sub("\n$"; "")) as $display |
    ($normalized | split("\n") | if last == "" then .[:-1] else . end | length) as $lines |
    {session_id: $session, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "read",
      tool_input: {path: $path},
      tool_result: {content: [{type: "text", text: $display}],
        details: {resolvedPath: $resolved, totalLines: $lines,
          displayContent: {text: $display, startLine: 1, lineNumbers: [range(1; $lines + 1)]}}}}
  ' | "$GATE" hook learn
}

# 読取済み Skill の conformance を含む session 終了可否の照会
# 引数 $1: 終了可否を照会する当該 session の ID
# 戻り値: 終了許可なら0でそれ以外は gate の拒否 status
conformance_stop() {
  jq -nc --arg session "$1" --arg cwd "$project" '{session_id: $session, cwd: $cwd}' |
    "$GATE" hook stop
}

git -C "$audited" init -q
git -C "$audited" config user.name fixture
git -C "$audited" config user.email fixture@example.invalid
printf 'source\n' >"$audited/tracked"
printf '{"violations":[]}\n' >"$audited/docs/conformance-baseline.json"
git -C "$audited" add tracked docs/conformance-baseline.json
git -C "$audited" commit -qm initial

old_object=$(store_object "$SKILL_SOURCE")
old_name=${old_object##*/}
skill_relative=${SKILL_SOURCE#"$old_object"}
new_name=$(printf '%s' "$old_name" | sha256sum | cut -c1-32)-standard-conformance
old_package=$store/$old_name$skill_relative
cp -r --no-preserve=mode,ownership "$old_object" "$store/$old_name"
ln -s "$old_package" "$deployed"
ln -s "$old_object" "$gcroots/generation"

trap ': > "$fixture/old-session.release"' EXIT
HOLD_READY=$fixture/old-session.ready HOLD_RELEASE=$fixture/old-session.release "$MODULE_WRAPPER" &
old_session_pid=$!
wait_for_file "$fixture/old-session.ready"
session_id=$(read_capture session-id)

skill_read_event "$session_id" "$deployed/SKILL.md"
status=0
output=$(conformance_stop "$session_id" 2>&1) || status=$?
test "$status" -eq 2 || fail "the gate did not require conformance after the session read the Skill ($status): $output"
node "$old_package/scripts/check-coverage.mjs" inventory --standard-root "$STANDARD_ROOT" --project-root "$audited" |
  jq '{violations: [], baseline: {file: "docs/conformance-baseline.json"},
    coverage: {standardDigest, projectDigest, entries: [.documents[] |
      {document: ., disposition: "checked", evidence: ["fixture:source-read"],
        checks: [{kind: "review", status: "passed", evidence: "fixture:completed-review"}]}]}}' >"$report"

cp -r --no-preserve=mode,ownership "$old_object" "$store/$new_name"
printf '\nNext generation procedure.\n' >>"$store/$new_name$skill_relative/SKILL.md"
ln -sfn "$store/$new_name$skill_relative" "$deployed"
ln -sfn "/nix/store/$new_name" "$gcroots/generation"
fixture_gc
test -d "$store/$new_name"

if ! output=$("$GATE" conformance --session "$session_id" --repo "$audited" \
  --standard-root "$STANDARD_ROOT" --report "$report" 2>&1); then
  fail "the old session lost the Skill package it read after the generation changed and a GC ran: $output"
fi
printf '%s' "$output" | jq -e '.status == "PASS"' >/dev/null || fail "the old checker did not pass: $output"
conformance_stop "$session_id" >/dev/null || fail "the gate did not accept the old session's conformance at its end"

: > "$fixture/old-session.release"
status=0
wait "$old_session_pid" || status=$?
test "$status" -eq 0
trap - EXIT
test -z "$(ls -A "$cache/sessions")"
fixture_gc
test ! -e "$store/$old_name"
test -d "$store/$new_name"
