# 実 resolver と実検査器を、公開 ref の問い合わせ、取得と build、GC root だけを置き換えて動かす。
# 候補 A/B/C の採用、作業中の root の保持、不正と非互換、upstream の停止と曖昧な応答、lock の競合と直列化を確かめる。
# 置き換えた command は作業 directory の control を読むため、resolver はこの directory から起動する
set -euo pipefail

resolver=@resolver@
state_relative=@stateRelative@
candidate_a=@candidateA@
candidate_b=@candidateB@
candidate_c=@candidateC@
rejected_candidates=(@rejectedCandidates@)

work=$PWD
export HOME="$work/home"
# 匿名の問い合わせへ漏れてはならない呼出し元の環境
export STANDARD_PACKAGE_SCENARIO=1
control="$work/control"
mkdir -p "$control/sources"
last_good="$HOME/$state_relative/standard-package/last-good"
# 管理 launcher を経由しない client でも原版を開ける。
unset DOTFILES_AGENT_SESSION_ID

fail() {
  printf 'standard-package scenario: %s\n' "$1" >&2
  cat "$work/err" >&2 2>/dev/null || true
  exit 1
}

revision_of() {
  printf '%040d' 0 | tr 0 "$1"
}

offer() {
  printf '%s\n' "$2" >"$control/sources/$1"
}

publish() {
  printf '%s\n' "$1" >"$control/published"
}

lookups() {
  if [ -f "$control/lookups.log" ]; then
    wc -l <"$control/lookups.log"
  else
    echo 0
  fi
}

expect_open() {
  local expected=$1 status=0
  shift
  "$resolver" open "$@" >"$work/out" 2>"$work/err" || status=$?
  [ "$status" -eq "$expected" ] || fail "open $* exited $status instead of $expected"
  [ "$expected" -eq 0 ] || [ ! -s "$work/out" ] || fail "a failed open $* printed a path"
}

expect_path() {
  [ "$(cat "$work/out")" = "$1/skills/$2/SKILL.md" ] || fail "open did not return $2 of $1"
}

expect_last_good() {
  "$resolver" status >"$work/status" || fail 'status failed'
  jq -e --arg revision "$1" --arg root "$2" '.lastGood == {revision: $revision, root: $root}' "$work/status" >/dev/null \
    || fail "the last good revision is not $1 at $2"
}

revision_a=$(revision_of a)
revision_b=$(revision_of b)
revision_c=$(revision_of c)
offer "$revision_a" "$candidate_a"
offer "$revision_b" "$candidate_b"
offer "$revision_c" "$candidate_c"

"$resolver" status >"$work/status" || fail 'status without a last good revision failed'
jq -e '. == {lastGood: null}' "$work/status" >/dev/null || fail 'status without a last good revision is not null'

# 採用していない ID は、問い合わせの前に拒否する
expect_open 64 cli-design
[ "$(lookups)" -eq 0 ] || fail 'a rejected open queried upstream'

touch "$control/outage"
expect_open 69 standard-apply
grep -qF 'no validated revision is recorded' "$work/err" || fail 'the outage did not report the missing last good revision'
rm "$control/outage"

publish "$revision_a"
expect_open 0 standard-apply
expect_path "$candidate_a" standard-apply
expect_last_good "$revision_a" "$candidate_a"
retained_a="${last_good%/*}/revisions/$revision_a"
[ "$(readlink -e "$retained_a")" = "$(readlink -e "$last_good")" ] || fail 'the published A is not retained'

# A の呼出しは終了済み。別のプロセスで B を開いても、受け手は A を参照できる。
publish "$revision_b"
expect_open 0 standard-update
expect_path "$candidate_b" standard-update
expect_last_good "$revision_b" "$candidate_b"
[ "$(readlink "$(readlink -e "$retained_a")/source")" = "$candidate_a" ] || fail 'the handoff lost A while B was opened'

# 不正、非互換、取得できない版、upstream の停止は新しい作業だけを止め、B を残す
index=0
for candidate in "${rejected_candidates[@]}" missing; do
  index=$((index + 1))
  revision=$(printf '%040d' "$index")
  if [ "$candidate" != missing ]; then
    offer "$revision" "$candidate"
  fi
  publish "$revision"
  expect_open 65 standard-apply
  grep -qF "last validated revision $revision_b at $candidate_b" "$work/err" \
    || fail "rejecting $candidate did not report B"
  expect_last_good "$revision_b" "$candidate_b"
done
touch "$control/outage"
expect_open 69 standard-apply
grep -qF "last validated revision $revision_b at $candidate_b" "$work/err" || fail 'the outage did not report B'
before=$(lookups)
expect_last_good "$revision_b" "$candidate_b"
[ "$(lookups)" -eq "$before" ] || fail 'status queried upstream'
rm "$control/outage"
touch "$control/extra-ref"
expect_open 69 standard-apply
rm "$control/extra-ref"
expect_last_good "$revision_b" "$candidate_b"

# lock を待ちきれない作業は止まり、B を残す
publish "$revision_c"
exec {held}>>"$HOME/$state_relative/standard-package/writer.lock"
flock -x "$held"
expect_open 75 standard-apply
flock -u "$held"
exec {held}>&-
expect_last_good "$revision_b" "$candidate_b"

# Nix が C の out-link を作った後で登録に失敗しても、B を公表したままにする。
touch "$control/registration-failure"
expect_open 65 standard-apply
[ -L "${last_good%/*}/revisions/$revision_c" ] || fail 'the fixture did not reach indirect-root registration'
rm "$control/registration-failure"
grep -qF "last validated revision $revision_b at $candidate_b" "$work/err" || fail 'partial registration hid B'
expect_last_good "$revision_b" "$candidate_b"

# A を検査中の作業の後に C を問い合わせた作業は、A の昇格を待ってから C を昇格する
publish "$revision_a"
touch "$control/hold-$revision_a"
"$resolver" open standard-apply >"$work/first" 2>"$work/first-err" &
first=$!
for _ in $(seq 200); do
  [ ! -e "$control/building-$revision_a" ] || break
  sleep 0.05
done
[ -e "$control/building-$revision_a" ] || fail 'the first open did not reach the build'
publish "$revision_c"
"$resolver" open standard-apply >"$work/second" 2>"$work/second-err" &
second=$!
sleep 0.5
touch "$control/release-$revision_a"
wait "$first" || fail "the first open failed: $(cat "$work/first-err")"
wait "$second" || fail "the second open failed: $(cat "$work/second-err")"
[ "$(cat "$work/first")" = "$candidate_a/skills/standard-apply/SKILL.md" ] || fail 'the first open did not return A'
[ "$(cat "$work/second")" = "$candidate_c/skills/standard-apply/SKILL.md" ] || fail 'the second open did not return C'
expect_last_good "$revision_c" "$candidate_c"

# 読めない最後の版を空の版として報告しない
mkdir "$work/unreadable"
ln -sfn "$work/unreadable" "$last_good"
status=0
"$resolver" status >"$work/status" 2>"$work/err" || status=$?
if [ "$status" -ne 70 ] || [ -s "$work/status" ]; then
  fail "status of an unreadable last good revision exited $status"
fi
