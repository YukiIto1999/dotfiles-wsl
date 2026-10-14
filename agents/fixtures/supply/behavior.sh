#!/usr/bin/env bash
set -euo pipefail

: "${SUPPLY:?}"
: "${SUPPLY_OTHER_UID:?}"
: "${SUPPLY_HOME_MISMATCH:?}"
: "${SUPPLY_LOSSLESS:?}"
: "${FIXTURE_GC:?}"
: "${FIXTURE_RUNTIME_SHELL:?}"
: "${FIXTURE_SIGNAL_ENV:?}"

work=$PWD/supply-behavior
mkdir -p "$work"

failure() {
  printf 'FIXTURE FAILURE: %s\n' "$*" >&2
  exit 1
}

# 試験ごとに store、GC root、build 結果、HOME を分け、GC 試験が他の試験の実体を消さないようにする
new_case() {
  local name=$1
  case_root=$work/$name
  mkdir -p "$case_root"
  export HOME=$case_root/home
  mkdir -m 0700 "$HOME"
  export FIXTURE_STORE=$case_root/store
  export FIXTURE_GCROOTS=$case_root/gcroots
  export FIXTURE_BUILDS=$case_root/builds
  export FIXTURE_HOOK_DIR=$case_root/hooks
  export FIXTURE_NIX_LOG=$case_root/nix.log
  export FIXTURE_REV_FILE=$case_root/rev
  mkdir "$FIXTURE_STORE" "$FIXTURE_GCROOTS" "$FIXTURE_BUILDS" "$FIXTURE_HOOK_DIR"
  : >"$FIXTURE_NIX_LOG"
}

revision() {
  printf '%040x' "$1"
}

set_revision() {
  printf '%s' "$(revision "$1")" >"$FIXTURE_REV_FILE"
}

store_entry() {
  local package=$1 version=$2 mode=${3:-ok} hash path
  hash=$(printf '%s' "$package-$version" | sha256sum | cut -c1-32)
  path=$FIXTURE_STORE/$hash-$package-$version
  mkdir -p "$path/bin"
  printf '#!%s\n' "$FIXTURE_RUNTIME_SHELL" >"$path/bin/$package"
  if [[ $mode == broken ]]; then
    printf 'exit 1\n' >>"$path/bin/$package"
  else
    cat >>"$path/bin/$package" <<SCRIPT
if [ "\${1-}" = --version ]; then echo "$package/$version"; exit 0; fi
exit 9
SCRIPT
  fi
  chmod +x "$path/bin/$package"
  printf '%s' "$path"
}

register_build() {
  printf '%s\n' "$3" >"$FIXTURE_BUILDS/$1-$(revision "$2")"
}

profile_dir() {
  printf '%s' "$HOME/.local/share/dotfiles/agent-profiles/$1"
}

resolved() {
  readlink -f -- "$(profile_dir "$1")/profile"
}

generations() {
  local link names=()
  for link in "$(profile_dir "$1")"/profile-*-link; do
    [[ -L $link || -e $link ]] || continue
    link=${link##*/profile-}
    names+=("${link%-link}")
  done
  printf '%s' "${names[*]:-}"
}

generation_target() {
  readlink -- "$(profile_dir "$1")/profile-$2-link"
}

nix_lines() {
  local count
  count=$(grep -c -- "$1" "$FIXTURE_NIX_LOG" || true)
  printf '%s' "$count"
}

supply_run() {
  local expected=$1 command_path=$SUPPLY
  shift
  if [[ ${1:-} == --with ]]; then
    command_path=$2
    shift 2
  fi
  status=0
  "$command_path" "$@" >"$case_root/stdout" 2>"$case_root/stderr" || status=$?
  if ((status != expected)); then
    cat "$case_root/stdout" "$case_root/stderr" >&2
    failure "'$*' exited with $status, expected $expected"
  fi
}

assert_equal() {
  [[ $1 == "$2" ]] || failure "$3: expected '$2', got '$1'"
}

assert_missing() {
  [[ ! -e $1 && ! -L $1 ]] || failure "unexpected object: $1"
}

make_roots() {
  mkdir -p "$HOME/.local/share/dotfiles"
  mkdir -m 0700 "$HOME/.local/share/dotfiles/agent-profiles"
  mkdir -m 0700 "$HOME/.local/share/dotfiles/agent-profiles/$1"
}

# ---- manifest ----------------------------------------------------------------
new_case manifest
supply_run 0 manifest
jq -e 'map(.name) == ["alpha", "beta"] and (map(.automatic) == [true, false])' "$case_root/stdout" >/dev/null \
  || failure "manifest does not list the adopted clients with their automatic subset"

# ---- init: baseline only, no latest fetch, never rewinds ------------------------
new_case init
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
touch "$FIXTURE_REV_FILE.fail"
supply_run 0 init
assert_equal "$(resolved alpha)" "$alpha_1" "alpha baseline"
assert_equal "$(resolved beta)" "$beta_1" "beta baseline"
assert_equal "$(generations alpha)" "1" "alpha generations"
assert_equal "$(nix_lines '^nix ')" "0" "activation must not fetch or build"
jq -e '.generations["1"] | .revision == "baseline" and .event == "init" and .version == "alpha/1"' \
  "$(profile_dir alpha)/receipt.json" >/dev/null || failure "init receipt"
assert_equal "$(stat -c %a "$(profile_dir alpha)")" "700" "client root mode"

rm "$FIXTURE_REV_FILE.fail"
set_revision 1
alpha_2=$(store_entry alpha 2)
beta_2=$(store_entry beta 2)
register_build alpha 1 "$alpha_2"
register_build beta 1 "$beta_2"
supply_run 0 update
assert_equal "$(resolved alpha)" "$alpha_2" "alpha updated"
assert_equal "$(resolved beta)" "$beta_2" "beta updated"
assert_equal "$(generations alpha)" "1 2" "alpha keeps current and previous"
assert_equal "$(generation_target alpha 1)" "$alpha_1" "previous generation is the baseline"
assert_missing "$(profile_dir alpha)/candidate"
jq -e --arg revision "$(revision 1)" '.generations["2"] | .revision == $revision and .event == "update"' \
  "$(profile_dir alpha)/receipt.json" >/dev/null || failure "update receipt"
calls=$(wc -l <"$FIXTURE_NIX_LOG")
supply_run 0 init
assert_equal "$(resolved alpha)" "$alpha_2" "re-applying init must not rewind alpha"
assert_equal "$(resolved beta)" "$beta_2" "re-applying init must not rewind beta"
assert_equal "$(wc -l <"$FIXTURE_NIX_LOG")" "$calls" "init on an existing profile does nothing"
builds=$(nix_lines '^nix build')
supply_run 0 update
assert_equal "$(nix_lines '^nix build')" "$builds" "an unchanged revision is not rebuilt"

# ---- update of a profile that does not exist initializes the baseline first -----
new_case update-uninitialized
store_entry alpha 1 >/dev/null
alpha_2=$(store_entry alpha 2)
set_revision 1
register_build alpha 1 "$alpha_2"
supply_run 0 update alpha
assert_equal "$(generations alpha)" "1 2" "baseline then update"
assert_equal "$(resolved alpha)" "$alpha_2" "updated after the baseline"
assert_missing "$(profile_dir beta)"

# ---- automatic subset ----------------------------------------------------------
new_case automatic
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
set_revision 1
alpha_2=$(store_entry alpha 2)
beta_2=$(store_entry beta 2)
register_build alpha 1 "$alpha_2"
register_build beta 1 "$beta_2"
supply_run 0 update --automatic
assert_equal "$(resolved alpha)" "$alpha_2" "automatic client updated"
assert_equal "$(resolved beta)" "$beta_1" "non-automatic client untouched"
supply_run 64 update --automatic alpha
supply_run 64 update omega
supply_run 0 update beta
assert_equal "$(resolved beta)" "$beta_2" "explicit client updated"

# ---- independent failure, probe failure, unreachable source ---------------------
new_case failure
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
set_revision 1
alpha_2=$(store_entry alpha 2)
beta_2=$(store_entry beta 2)
register_build alpha 1 "$alpha_2"
register_build beta 1 "$beta_2"
touch "$FIXTURE_BUILDS/alpha-$(revision 1).fail"
supply_run 1 update
assert_equal "$(resolved alpha)" "$alpha_1" "failed client keeps its version"
assert_equal "$(generations alpha)" "1" "failed client publishes nothing"
assert_equal "$(resolved beta)" "$beta_2" "later client is still published"
assert_missing "$(profile_dir alpha)/candidate"
rm "$FIXTURE_BUILDS/alpha-$(revision 1).fail"
supply_run 0 update
assert_equal "$(resolved alpha)" "$alpha_2" "the failed client recovers on the next run"

new_case probe
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
broken=$(store_entry alpha 2 broken)
register_build alpha 1 "$broken"
supply_run 1 update alpha
assert_equal "$(resolved alpha)" "$alpha_1" "a candidate that fails its probe is not published"
assert_equal "$(generations alpha)" "1" "no generation for a failed candidate"
assert_missing "$(profile_dir alpha)/candidate"

new_case unreachable
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
touch "$FIXTURE_REV_FILE.fail"
supply_run 1 update
assert_equal "$(resolved alpha)" "$alpha_1" "unreachable source keeps alpha"
assert_equal "$(resolved beta)" "$beta_1" "unreachable source keeps beta"

# ---- retention, GC and live sessions -------------------------------------------
new_case gc
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
beta_1=$(resolved beta)
foreign=$(store_entry foreign 1)
ln -s "$foreign" "$FIXTURE_GCROOTS/foreign-root"
garbage=$(store_entry garbage 1)
# 候補の build 後に GC を挟んでも、候補 root が実体を保持する
cat >"$FIXTURE_HOOK_DIR/candidate-built" <<'HOOK'
"$FIXTURE_GC"
test -d "$(readlink -- "$client_root/candidate")"
HOOK
publish() {
  local number=$1 entry
  set_revision "$number"
  entry=$(store_entry alpha "$number")
  register_build alpha "$number" "$entry"
  supply_run 0 update alpha
  assert_equal "$(resolved alpha)" "$entry" "alpha version $number"
}
publish 2
assert_missing "$garbage"
publish 3
publish 4
alpha_3=$(readlink -- "$(profile_dir alpha)/profile-3-link")
alpha_4=$(resolved alpha)
assert_equal "$(generations alpha)" "3 4" "retention keeps only current and previous"
"$FIXTURE_GC"
for kept in "$alpha_3" "$alpha_4" "$foreign" "$beta_1"; do
  [[ -d $kept ]] || failure "GC removed a rooted object: $kept"
done
for gone in "$FIXTURE_STORE"/*-alpha-1 "$FIXTURE_STORE"/*-alpha-2; do
  [[ ! -e $gone ]] || failure "GC kept an unrooted old generation: $gone"
done
# 起動済み session の root は、世代が retention で外れた後も実体を保持する
ln -s "$alpha_3" "$FIXTURE_GCROOTS/session-root"
publish 5
assert_equal "$(generations alpha)" "4 5" "retention after the fifth publish"
"$FIXTURE_GC"
[[ -d $alpha_3 ]] || failure "GC removed a version held by a live session root"
[[ -d $foreign ]] || failure "GC removed a foreign rooted object"

# ---- rollback and rejected versions --------------------------------------------
new_case rollback
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
for number in 1 2; do
  set_revision "$number"
  entry=$(store_entry alpha "$((number + 1))")
  register_build alpha "$number" "$entry"
  supply_run 0 update alpha
done
alpha_2=$(generation_target alpha 2)
alpha_3=$(resolved alpha)
assert_equal "$(generations alpha)" "2 3" "before rollback"
beta_current=$(resolved beta)
supply_run 0 rollback alpha
assert_equal "$(resolved alpha)" "$alpha_2" "rolled back to the previous generation"
assert_equal "$(generations alpha)" "2" "the abandoned generation is removed"
assert_equal "$(resolved beta)" "$beta_current" "rollback does not move another client"
jq -e --arg path "$alpha_3" '.rejected | index($path) != null' "$(profile_dir alpha)/receipt.json" >/dev/null \
  || failure "rolled back version is not recorded"
calls=$(nix_lines '^nix ')
supply_run 1 rollback alpha
assert_equal "$(nix_lines '^nix ')" "$calls" "a refused rollback neither fetches nor builds"
set_revision 3
register_build alpha 3 "$alpha_3"
supply_run 0 update alpha
assert_equal "$(resolved alpha)" "$alpha_2" "the next update does not republish a rolled back version"
set_revision 4
alpha_4=$(store_entry alpha 4)
register_build alpha 4 "$alpha_4"
supply_run 0 update alpha
assert_equal "$(resolved alpha)" "$alpha_4" "a newer version is published after a rollback"
assert_equal "$(generations alpha)" "2 3" "previous generation after update following rollback"
assert_equal "$(generation_target alpha 2)" "$alpha_2" "the previous generation is the version rolled back to"

# 辞書順で最小の版が最後でないと上限の脱落が直近に当たらず順序の誤りは検出不可
new_case rollback-rejected-limit
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
mapfile -t order < <(
  for number in 2 3 4 5 6 7 8 9 10; do
    printf '%s %s\n' "$(printf '%s' "alpha-$number" | sha256sum | cut -c1-32)" "$number"
  done | LC_ALL=C sort -r | cut -d' ' -f2
)
rolled_back=()
for number in "${order[@]}"; do
  set_revision "$number"
  entry=$(store_entry alpha "$number")
  register_build alpha "$number" "$entry"
  supply_run 0 update alpha
  supply_run 0 rollback alpha
  rolled_back+=("$entry")
done
assert_equal "$(resolved alpha)" "$alpha_1" "the baseline after nine rollbacks"
supply_run 0 update alpha
assert_equal "$(resolved alpha)" "$alpha_1" "the version rolled back last is not republished by the next update"
receipt_file=$(profile_dir alpha)/receipt.json
for path in "${rolled_back[@]:1}"; do
  jq -e --arg path "$path" '.rejected | index($path) != null' "$receipt_file" >/dev/null \
    || failure "a recent rejection was dropped from the record: $path"
done
jq -e --arg path "${rolled_back[0]}" '.rejected | index($path) == null' "$receipt_file" >/dev/null \
  || failure "the oldest rejection outlived the limit"
jq -e '.rejected | length == 8 and (unique | length) == 8' "$receipt_file" >/dev/null \
  || failure "the rejected record is not eight distinct versions"

# ---- unpublished generation left by an interrupted publish ---------------------
new_case interrupted
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
orphan=$(store_entry alpha 9)
ln -s "$orphan" "$(profile_dir alpha)/profile-2-link"
set_revision 1
alpha_3=$(store_entry alpha 3)
register_build alpha 1 "$alpha_3"
supply_run 0 update alpha
assert_equal "$(generations alpha)" "1 2" "the unpublished generation is replaced"
assert_equal "$(generation_target alpha 1)" "$alpha_1" "an unprobed generation never becomes the previous version"
assert_equal "$(resolved alpha)" "$alpha_3" "published after dropping the unpublished generation"

# ---- foreign objects are refused and left untouched ----------------------------
# 拒否時の終了statusとalphaのprofile操作の未実行確認
# 引数 $1: 拒否対象を特定する失敗時の説明
# 引数 $2以降: 実行する供給commandとその引数
# 戻り値: status1とalphaへのnix-env呼出し無しの確認成功時の0
# 副作用: 当該caseのNix呼出記録とstdoutとstderrの記録の置換
# 失敗: 終了statusか操作の未実行を確認できない場合のfixture終了
expect_refusal() {
  local description=$1
  : >"$FIXTURE_NIX_LOG"
  supply_run 1 "${@:2}"
  [[ $(nix_lines '^nix-env.*agent-profiles/alpha/') == 0 ]] \
    || failure "$description: nix-env touched the refused profile"
}

new_case foreign-profile-file
store_entry alpha 1 >/dev/null
beta_1=$(store_entry beta 1)
make_roots alpha
printf 'keep\n' >"$(profile_dir alpha)/profile"
expect_refusal "regular profile" init
assert_equal "$(cat "$(profile_dir alpha)/profile")" "keep" "foreign profile file content"
assert_equal "$(resolved beta)" "$beta_1" "another client is still initialized"

new_case foreign-profile-link
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
ln -s /elsewhere "$(profile_dir alpha)/profile"
expect_refusal "profile outside the root" init
assert_equal "$(readlink "$(profile_dir alpha)/profile")" "/elsewhere" "foreign profile link target"

new_case foreign-generation-file
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
printf 'keep\n' >"$(profile_dir alpha)/profile-1-link"
expect_refusal "regular generation" init
assert_equal "$(cat "$(profile_dir alpha)/profile-1-link")" "keep" "foreign generation file content"

new_case foreign-generation-target
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
ln -s /tmp/outside "$(profile_dir alpha)/profile-1-link"
expect_refusal "generation outside the store" init
assert_equal "$(readlink "$(profile_dir alpha)/profile-1-link")" "/tmp/outside" "foreign generation target"

new_case foreign-generation-name
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
ln -s "$(store_entry alpha 7)" "$(profile_dir alpha)/profile-007-link"
expect_refusal "non-canonical generation name" init
[[ -L $(profile_dir alpha)/profile-007-link ]] || failure "non-canonical generation link was removed"

new_case foreign-receipt
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
ln -s /elsewhere "$(profile_dir alpha)/receipt.json"
expect_refusal "receipt link" init
assert_missing "$(profile_dir alpha)/profile"

new_case foreign-candidate
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
mkdir "$(profile_dir alpha)/candidate"
printf 'keep\n' >"$(profile_dir alpha)/candidate/data"
: >"$FIXTURE_NIX_LOG"
supply_run 1 update alpha
assert_equal "$(nix_lines '^nix build')" "0" "no build over a foreign candidate directory"
assert_equal "$(cat "$(profile_dir alpha)/candidate/data")" "keep" "foreign candidate directory content"

new_case foreign-symlinked-root
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
mkdir -p "$HOME/.local/share/dotfiles"
mkdir -m 0700 "$HOME/.local/share/dotfiles/agent-profiles" "$case_root/elsewhere"
ln -s "$case_root/elsewhere" "$(profile_dir alpha)"
expect_refusal "symlinked client root" init
[[ -z $(ls -A "$case_root/elsewhere") ]] || failure "the symlinked client root target was written"

new_case foreign-writable-root
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
make_roots alpha
chmod 0777 "$HOME/.local/share/dotfiles/agent-profiles"
expect_refusal "writable profile root" init
assert_missing "$(profile_dir alpha)/profile"

new_case foreign-unknown-file
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
printf 'keep\n' >"$(profile_dir alpha)/notes.txt"
for number in 1 2 3; do
  set_revision "$number"
  register_build alpha "$number" "$(store_entry alpha "$((number + 1))")"
  supply_run 0 update alpha
done
assert_equal "$(cat "$(profile_dir alpha)/notes.txt")" "keep" "unknown files survive updates and retention"

# ---- parent identity, ownership, home --------------------------------------------
new_case identity
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
cat >"$FIXTURE_HOOK_DIR/before-publish" <<'HOOK'
mv -- "$client_root" "$client_root.moved"
mkdir -m 0700 "$client_root"
HOOK
sets=$(nix_lines '^nix-env.*--set')
supply_run 1 update alpha
assert_equal "$(nix_lines '^nix-env.*--set')" "$sets" "nothing is published after the parent was replaced"
[[ -z $(ls -A "$(profile_dir alpha)") ]] || failure "the replacement directory was written"
assert_equal "$(readlink -f "$(profile_dir alpha).moved/profile")" "$alpha_1" "the original profile is untouched"

new_case ownership
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
supply_run 1 --with "$SUPPLY_OTHER_UID" update alpha
supply_run 1 --with "$SUPPLY_OTHER_UID" status alpha

new_case home-mismatch
supply_run 1 --with "$SUPPLY_HOME_MISMATCH" init
assert_missing "$HOME/.local"

# ---- concurrency and the legacy release writer -----------------------------------
hold_lock() {
  rm -f "$case_root/locked"
  (
    exec {lock_fd}<"$1"
    flock "$lock_fd"
    : >"$case_root/locked"
    exec sleep 30
  ) &
  holder=$!
  for _ in $(seq 1 100); do
    [[ -e $case_root/locked ]] && return 0
    sleep 0.1
  done
  failure "the lock holder did not start"
}

release_lock() {
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

new_case concurrency
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
alpha_2=$(store_entry alpha 2)
register_build alpha 1 "$alpha_2"
hold_lock "$(profile_dir alpha)"
supply_run 1 update alpha
supply_run 1 rollback alpha
release_lock
supply_run 0 update alpha
assert_equal "$(resolved alpha)" "$alpha_2" "update after the lock was released"

new_case legacy-writer
store_entry alpha 1 >/dev/null
beta_1=$(store_entry beta 1)
mkdir -p "$HOME/.local/share/dotfiles/agents"
mkdir -m 0700 "$HOME/.local/share/dotfiles/agents/alpha"
hold_lock "$HOME/.local/share/dotfiles/agents/alpha"
supply_run 1 init
assert_missing "$(profile_dir alpha)/profile"
assert_equal "$(resolved beta)" "$beta_1" "a client without a legacy writer is initialized"
release_lock
supply_run 0 init
assert_equal "$(generations alpha)" "1" "alpha initialized after the legacy writer released it"
[[ -d $HOME/.local/share/dotfiles/agents/alpha ]] || failure "the legacy release root was modified"

# ---- clients that are no longer adopted keep their profile -------------------------
new_case removed
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
omega_1=$(store_entry omega 1)
make_roots omega
ln -s "$omega_1" "$(profile_dir omega)/profile-1-link"
ln -s profile-1-link "$(profile_dir omega)/profile"
printf 'history\n' >"$(profile_dir omega)/receipt.json"
before=$(cd "$(profile_dir omega)" && find . -printf '%p %y %l\n' | sort)
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
register_build beta 1 "$(store_entry beta 2)"
supply_run 0 update
supply_run 64 update omega
supply_run 64 rollback omega
after=$(cd "$(profile_dir omega)" && find . -printf '%p %y %l\n' | sort)
assert_equal "$after" "$before" "a client outside the adopted set is never touched"

# ---- cancellation drains the running child and starts nothing new -------------------
new_case cancel
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
register_build beta 1 "$(store_entry beta 2)"
hang=$FIXTURE_BUILDS/alpha-$(revision 1)
touch "$hang.hang"
"$SUPPLY" update >"$case_root/stdout" 2>"$case_root/stderr" &
pid=$!
for _ in $(seq 1 100); do
  [[ -e $hang.started ]] && break
  sleep 0.1
done
[[ -e $hang.started ]] || failure "the build did not start"
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
assert_equal "$status" "143" "cancelled supply exit status"
[[ -e $hang.terminated ]] || failure "the running child was not drained before the supply returned"
if kill -0 "$(cat "$hang.started")" 2>/dev/null; then
  failure "the build child outlived the supply"
fi
assert_equal "$(nix_lines 'packages.*beta')" "0" "no client starts after cancellation"
assert_equal "$(resolved alpha)" "$alpha_1" "cancelled client keeps its version"
assert_equal "$(resolved beta)" "$beta_1" "unstarted client keeps its version"
assert_missing "$(profile_dir alpha)/candidate"

new_case cancel-before-critical-fork
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
touch "$case_root/cancel"
sets=$(nix_lines '^nix-env.*--set')
supply_run 143 --with timeout --kill-after=2s 5s env \
  SHELLOPTS=functrace BASH_ENV="$FIXTURE_SIGNAL_ENV" \
  FIXTURE_SIGNAL_FUNCTION=run_child FIXTURE_SIGNAL_SECOND_ARGUMENT=--profile \
  FIXTURE_SIGNAL_COMMAND='child_cancellable=0' \
  FIXTURE_SIGNAL_POINT="$case_root/cancel" "$SUPPLY" update alpha
[[ -f $case_root/cancel.fired ]] || failure "the pre-fork cancellation was not injected"
assert_equal "$(nix_lines '^nix-env.*--set')" "$sets" "no publish starts after cancellation"
assert_equal "$(resolved alpha)" "$alpha_1" "cancellation before fork keeps the published version"

new_case cancel-before-child-registration
alpha_1=$(store_entry alpha 1)
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
touch "$FIXTURE_BUILDS/alpha-$(revision 1).hang" "$case_root/cancel"
supply_run 143 --with timeout --kill-after=2s 5s env \
  SHELLOPTS=functrace BASH_ENV="$FIXTURE_SIGNAL_ENV" \
  FIXTURE_SIGNAL_FUNCTION=run_child FIXTURE_SIGNAL_SECOND_ARGUMENT=build \
  FIXTURE_SIGNAL_COMMAND='child_pid=$!' \
  FIXTURE_SIGNAL_POINT="$case_root/cancel" "$SUPPLY" update alpha
[[ -f $case_root/cancel.fired ]] || failure "the pre-registration cancellation was not injected"
child=$(cat "$case_root/cancel.child")
: "${child:?the signal injector did not capture the spawned child}"
if kill -0 "$child" 2>/dev/null; then
  failure "the build child outlived cancellation during registration"
fi
assert_equal "$(resolved alpha)" "$alpha_1" "cancellation during child registration keeps the published version"

new_case cancel-before-worker-fork
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
touch "$case_root/cancel"
supply_run 143 --with timeout --kill-after=2s 5s env \
  SHELLOPTS=functrace BASH_ENV="$FIXTURE_SIGNAL_ENV" \
  FIXTURE_SIGNAL_FUNCTION=run_worker FIXTURE_SIGNAL_SECOND_ARGUMENT=alpha \
  FIXTURE_SIGNAL_COMMAND="local reaped='' status" \
  FIXTURE_SIGNAL_POINT="$case_root/cancel" "$SUPPLY" init
[[ -f $case_root/cancel.fired ]] || failure "the pre-fork worker cancellation was not injected"
assert_missing "$HOME/.local"

# 取消の記録時に build が存在しないと子の存続を確認できないため build 開始の待機なしの注入は不可
new_case cancel-before-worker-registration
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
register_build beta 1 "$(store_entry beta 2)"
hang=$FIXTURE_BUILDS/alpha-$(revision 1)
touch "$hang.hang" "$case_root/cancel"
supply_run 143 --with timeout --kill-after=2s 5s env \
  SHELLOPTS=functrace BASH_ENV="$FIXTURE_SIGNAL_ENV" \
  FIXTURE_SIGNAL_FUNCTION=run_worker FIXTURE_SIGNAL_SECOND_ARGUMENT=alpha \
  FIXTURE_SIGNAL_COMMAND='worker_pid=$!' FIXTURE_SIGNAL_AWAIT="$hang.started" \
  FIXTURE_SIGNAL_POINT="$case_root/cancel" "$SUPPLY" update
[[ -f $case_root/cancel.fired ]] || failure "the pre-registration worker cancellation was not injected"
[[ -e $hang.terminated ]] || failure "the running build was not cancelled through its worker"
for forked in "$(cat "$case_root/cancel.child")" "$(cat "$hang.started")"; do
  : "${forked:?the injector or the build did not record its pid}"
  if kill -0 "$forked" 2>/dev/null; then
    failure "process $forked outlived the cancelled supply"
  fi
done
assert_equal "$(resolved alpha)" "$alpha_1" "cancellation during worker registration keeps the published version"
assert_equal "$(generations alpha)" "1" "the cancelled worker leaves no generation"
assert_missing "$(profile_dir alpha)/candidate"
assert_equal "$(nix_lines 'packages.*beta')" "0" "no client starts after the cancellation"
assert_equal "$(resolved beta)" "$beta_1" "the unstarted client keeps its version"

# entrypoint から worker への TERM の転送が非同期で競合を生むため試験側の kill は不可
cancel_worker='
stat=$(<"/proc/$PPID/stat")
rest=${stat##*) }
read -r _ entrypoint _ <<<"$rest"
kill -TERM "$entrypoint" "$PPID"
'

new_case cancel-before-publish
alpha_1=$(store_entry alpha 1)
beta_1=$(store_entry beta 1)
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
register_build beta 1 "$(store_entry beta 2)"
printf '%s\n' "$cancel_worker" >"$FIXTURE_HOOK_DIR/before-publish"
sets=$(nix_lines '^nix-env.*--set')
supply_run 143 update
assert_equal "$(nix_lines '^nix-env.*--set')" "$sets" "no publish starts after the cancellation"
assert_equal "$(resolved alpha)" "$alpha_1" "the cancelled update keeps the current version"
assert_equal "$(generations alpha)" "1" "the cancelled update leaves no generation"
assert_missing "$(profile_dir alpha)/candidate"
assert_equal "$(nix_lines 'packages.*beta')" "0" "no client starts after the cancellation"
assert_equal "$(resolved beta)" "$beta_1" "the unstarted client keeps its version"

new_case cancel-before-publish-init
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
printf '%s\n' "$cancel_worker" >"$FIXTURE_HOOK_DIR/before-publish"
supply_run 143 init
assert_equal "$(nix_lines '^nix-env.*--set')" "0" "no baseline publish starts after the cancellation"
assert_missing "$(profile_dir alpha)/profile"
assert_missing "$(profile_dir alpha)/receipt.json"
assert_missing "$(profile_dir beta)"

new_case cancel-before-rollback
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
for number in 1 2; do
  set_revision "$number"
  entry=$(store_entry alpha "$((number + 1))")
  register_build alpha "$number" "$entry"
  supply_run 0 update alpha
done
alpha_3=$(resolved alpha)
assert_equal "$(generations alpha)" "2 3" "before the cancelled rollback"
printf '%s\n' "$cancel_worker" >"$FIXTURE_HOOK_DIR/before-publish"
supply_run 143 rollback alpha
assert_equal "$(nix_lines '^nix-env.*--switch-generation')" "0" "no switch starts after the cancellation"
assert_equal "$(resolved alpha)" "$alpha_3" "the cancelled rollback keeps the current version"
assert_equal "$(generations alpha)" "2 3" "the cancelled rollback keeps both generations"
jq -e '(.rejected // []) | length == 0' "$(profile_dir alpha)/receipt.json" >/dev/null \
  || failure "a cancelled rollback recorded a rejected version"

new_case cancel-during-publish
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
alpha_2=$(store_entry alpha 2)
register_build alpha 1 "$alpha_2"
register_build beta 1 "$(store_entry beta 2)"
printf '%s\n' "$cancel_worker" >"$FIXTURE_HOOK_DIR/nix-env-set"
sets=$(nix_lines '^nix-env.*--set')
supply_run 143 update
assert_equal "$(nix_lines '^nix-env.*--set')" "$((sets + 1))" "the cancellation does not abandon the started publish"
assert_equal "$(resolved alpha)" "$alpha_2" "the started publish completes"
assert_missing "$(profile_dir alpha)/candidate"
assert_equal "$(nix_lines 'packages.*beta')" "0" "no client starts after the cancellation"

builds=$(nix_lines '^nix build')
supply_run 0 update alpha
assert_equal "$(nix_lines '^nix build')" "$builds" "the started publish is recorded, so its revision is not rebuilt"

new_case cancel-before-retention
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
set_revision 1
register_build alpha 1 "$(store_entry alpha 2)"
supply_run 0 update alpha
set_revision 2
alpha_3=$(store_entry alpha 3)
register_build alpha 2 "$alpha_3"
printf '%s\n' "$cancel_worker" >"$FIXTURE_HOOK_DIR/before-retention"
deletes=$(nix_lines '^nix-env.*--delete-generations')
supply_run 143 update alpha
assert_equal "$(nix_lines '^nix-env.*--delete-generations')" "$deletes" "no retention starts after the cancellation"
assert_equal "$(resolved alpha)" "$alpha_3" "the publish before the cancellation completes"
assert_equal "$(generations alpha)" "1 2 3" "the cancelled retention deleted nothing"
builds=$(nix_lines '^nix build')
supply_run 0 update alpha
assert_equal "$(nix_lines '^nix build')" "$builds" "the published revision is recorded, so it is not rebuilt"
set_revision 3
register_build alpha 3 "$(store_entry alpha 4)"
supply_run 0 update alpha
assert_equal "$(generations alpha)" "3 4" "the next publish completes the retention"

# ---- lossless version arguments -----------------------------------------------------
new_case lossless
gamma=$FIXTURE_STORE/$(printf '%s' gamma-1 | sha256sum | cut -c1-32)-gamma-1
mkdir -p "$gamma/bin"
printf '#!%s\n' "$FIXTURE_RUNTIME_SHELL" >"$gamma/bin/gamma"
cat >>"$gamma/bin/gamma" <<'SCRIPT'
[ "$#" -eq 5 ] && [ "$1" = $'trailing\n' ] && [ "$2" = $'\n' ] \
  && [ "$3" = $'embedded\nline' ] && [ "$4" = '  spaced  ' ] && [ "$5" = 'pipe|value' ] || exit 7
echo gamma/1
SCRIPT
chmod +x "$gamma/bin/gamma"
supply_run 0 --with "$SUPPLY_LOSSLESS" init
assert_equal "$(resolved gamma)" "$gamma" "baseline whose probe needs the exact version arguments"

# ---- status --------------------------------------------------------------------------
new_case status-fresh
supply_run 0 status --json
jq -e '.[0].state == "uninitialized" and .[0].generation == null' "$case_root/stdout" >/dev/null \
  || failure "status of an uninitialized client"
assert_missing "$HOME/.local"

new_case status
store_entry alpha 1 >/dev/null
store_entry beta 1 >/dev/null
supply_run 0 init
supply_run 0 status --json
jq -e '.[] | select(.client == "alpha") | .state == "ready" and .generation == 1 and .version == "alpha/1" and .revision == "baseline" and .previous == null' \
  "$case_root/stdout" >/dev/null || failure "status of an initialized client"

