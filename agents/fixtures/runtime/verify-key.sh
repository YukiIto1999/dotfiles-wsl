#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=verify-common.sh
source "$VERIFY_COMMON"

# 検証の証跡の鍵は作業木の中身だけで決まる。検証した中身は stage、commit、amend の後も検証済みで、
# 中身、mode、削除、新しい未追跡 file、検査の後に追跡された file、submodule の中の変更は別の木になる。
# 採れない木(読めない file、commit の無い入れ子の repository)は、検証済みとも免除済みとも扱わず、理由を添えて閉じる。

key_git() {
  git -c user.name=fixture -c user.email=fixture@example.invalid -c protocol.file.allow=always "$@"
}

# 宣言した入口を repository の根で通す。引数 $1: repository
key_t1() {
  (cd "$1" && PATH="$fixture/entry-bin:$PATH" "$VERIFY" -- devenv shell -- verify)
}

# 引数 $1: repository、$2: 場面の名前
expect_changed_tree() {
  if "$GATE" check --repo "$1" >/dev/null 2>&1; then
    echo "gate accepted a tree whose content differs from the verified one: $2" >&2
    exit 1
  fi
}

count_files() {
  find "$home/.cache/dotfiles-wsl/verification" -type f -name "$1" | wc -l
}

# 鍵を採れない木を、検証済みとも免除済みとも扱わず、理由を添えて閉じること
# 引数 $1: repository、$2: 理由に含まれる path、$3: 場面の名前
expect_key_refused() {
  local output status=0 waived
  output=$("$GATE" check --repo "$1" 2>&1) || status=$?
  if [ "$status" -ne 1 ] || [[ $output != *'木の鍵を採れない'* ]] || [[ $output != *"$2"* ]]; then
    echo "check did not close on a tree whose key cannot be taken, with the reason ($3): $status $output" >&2
    exit 1
  fi
  waived=$(count_files '*.waived')
  status=0
  "$GATE" waive --repo "$1" --reason fixture >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ] || [ "$(count_files '*.waived')" != "$waived" ]; then
    echo "waive accepted a tree whose key cannot be taken ($3)" >&2
    exit 1
  fi
}

# TMPDIR が木の中なら、一時 file が鍵へ混ざるため鍵を採らず、木へ何も置かない
# 引数 $1: repository
expect_refused_when_tmpdir_is_in_tree() {
  local scratch=$1/scratch output status=0
  mkdir "$scratch"
  output=$(TMPDIR=$scratch "$GATE" check --repo "$1" 2>&1) || status=$?
  if [ "$status" -ne 1 ] || [[ $output != *TMPDIR* ]] || [ -n "$(find "$scratch" -mindepth 1)" ]; then
    echo "check did not close on a TMPDIR inside the tree, or left something there: $status $output" >&2
    exit 1
  fi
  rmdir "$scratch"
}

# 引数 $1: stderr を控えた file、$2: 期待する回数、$3: 場面の名前
expect_hint_count() {
  local count
  count=$(grep -cF '未追跡の file がある' "$1" || true)
  if [ "$count" != "$2" ]; then
    echo "T1 printed the untracked-file hint $count times instead of $2: $3" >&2
    exit 1
  fi
}

# 引数 $1: 場面の名前、$2: 状態、$3: 呼び出しの名前、$4: repository
key_observe() {
  printf '{"session_id":"fixture-key-%s","hook_event_name":"%s","tool_use_id":"%s","cwd":"%s","tool_name":"bash","tool_input":{"command":"x"}}' \
    "$1" "$2" "$3" "$4" | "$GATE" hook observe
}

# 控えた repository が未検証なら 2 で返る。控えていなければ 0 で返る
key_stop() {
  printf '{"session_id":"fixture-key-%s","cwd":"%s"}' "$1" "$2" | "$GATE" hook stop >/dev/null 2>&1
}

# 引数 $1: 場面の名前。作った repository の根を出す。入口は未検証のまま
key_observed_repository() {
  local repository=$fixture/key-observe-$1
  t1_repository "$repository" 60
  printf 'held\n' >"$repository/held"
  key_git -C "$repository" add held
  key_git -C "$repository" commit -qm 'test: 追跡する file の追加'
  printf '%s\n' "$repository"
}

mkdir -p "$fixture/entry-bin" "$fixture/key-count-bin"
cat >"$fixture/entry-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
cat >"$fixture/key-count-bin/devenv" <<'SCRIPT'
#!/usr/bin/env bash
count=0
test ! -e "$KEY_ENTRY_RUNS" || count=$(cat "$KEY_ENTRY_RUNS")
printf '%s\n' "$((count + 1))" >"$KEY_ENTRY_RUNS"
SCRIPT
chmod +x "$fixture/entry-bin/devenv" "$fixture/key-count-bin/devenv"
sed -i "1c#!$BASH" "$fixture/entry-bin/devenv" "$fixture/key-count-bin/devenv"

# 新しい file は検証の前に追跡する。検証した中身は、stage、commit、amend、件名の書換え、同じ中身の別の worktree でも検証済みである。
check_receipt_follows_content() {
  local repository=$fixture/key-content linked=$fixture/key-linked stderr=$fixture/key-content-stderr
  local state older planted_open planted_done

  t1_repository "$repository" 60
  printf 'a\n' >"$repository/a"
  printf 'b\n' >"$repository/b"
  printf 'ignored.log\n' >"$repository/.gitignore"
  key_git -C "$repository" add a b .gitignore
  key_git -C "$repository" commit -qm 'test: 追跡する file の追加'

  printf 'a changed\n' >"$repository/a"
  printf 'n\n' >"$repository/new"
  key_git -C "$repository" add -N new
  key_t1 "$repository" 2>"$stderr"
  expect_open_gate "$repository" 'tree the run verified'
  expect_hint_count "$stderr" 0 'tree without untracked files'
  key_git -C "$repository" add a new
  expect_open_gate "$repository" 'after staging the verified content'
  key_git -C "$repository" commit -qm 'test: 検証した中身の commit'
  expect_open_gate "$repository" 'after committing the verified content'
  key_git -C "$repository" commit -q --amend -m 'test: 件名の書換え'
  expect_open_gate "$repository" 'after amending the verified commit'
  key_git -C "$repository" worktree add -q --detach "$linked" HEAD
  expect_open_gate "$linked" 'identical tree in a linked worktree'
  key_git -C "$repository" worktree remove --force "$linked"

  # 中身、mode、削除、新しい未追跡 file は別の木になり、元へ戻せば検証した木へ戻る
  printf 'edited\n' >>"$repository/a"
  expect_changed_tree "$repository" 'content change'
  key_git -C "$repository" checkout -q -- a
  expect_open_gate "$repository" 'content change reverted'
  chmod +x "$repository/b"
  expect_changed_tree "$repository" 'mode change'
  chmod -x "$repository/b"
  expect_open_gate "$repository" 'mode change reverted'
  rm "$repository/b"
  expect_changed_tree "$repository" 'deletion'
  key_git -C "$repository" checkout -q -- b
  expect_open_gate "$repository" 'deletion reverted'
  printf 'u\n' >"$repository/untracked"
  expect_changed_tree "$repository" 'new untracked file'
  rm "$repository/untracked"
  expect_open_gate "$repository" 'new untracked file removed'

  # ignore された file は木に入らない
  printf 'noise\n' >"$repository/ignored.log"
  expect_open_gate "$repository" 'ignored file created'
  printf 'more\n' >>"$repository/ignored.log"
  expect_open_gate "$repository" 'ignored file changed'
  key_t1 "$repository" 2>"$stderr"
  expect_hint_count "$stderr" 0 'tree with an ignored file only'
  rm "$repository/ignored.log"

  # 検証の時に未追跡だった file が、後で追跡された木は別の木になる。走行は追跡を促す一行を出す
  printf 'late\n' >"$repository/late"
  key_t1 "$repository" 2>"$stderr"
  expect_open_gate "$repository" 'tree with an untracked file'
  expect_hint_count "$stderr" 1 'tree with an untracked file'
  key_git -C "$repository" add late
  expect_changed_tree "$repository" 'file untracked at verification and staged afterwards'
  key_git -C "$repository" reset -q -- late
  expect_open_gate "$repository" 'file unstaged again'
  # 宣言した入口でない呼び出しは、証跡を作らないため促さない
  (cd "$repository" && COUNT=$fixture/key-focused-count "$VERIFY" -- "$fixture/check" focused) 2>"$stderr"
  expect_hint_count "$stderr" 0 'command that is not the declared entry'
  rm "$repository/late"

  # 旧い版の鍵の名の控えは一致しないまま残り、producer が消えた書込み途中のものは、次の走行が鍵の名に依らず回収する
  key_t1 "$repository"
  state=$home/.cache/dotfiles-wsl/verification/$(printf '%s' "$(realpath -e -- "$repository/.git")" | sha256sum | cut -d ' ' -f 1)
  older=$(printf 'older key\n' | sha256sum | cut -d ' ' -f 1)
  planted_open=$state/$older.0000000000000001.99999999.verified
  planted_done=$state/$older.0000000000000002.99999999.verified
  printf 'version=4\nsource=%s\ncommand=x\nat=x\nboot_id=%s\nproducer_start_time=1\n' \
    "$older" "$(cat /proc/sys/kernel/random/boot_id)" >"$planted_open"
  printf 'version=4\nsource=%s\ncommand=x\nat=x\nboot_id=%s\nproducer_start_time=1\ncompleted=true\n' \
    "$older" "$(cat /proc/sys/kernel/random/boot_id)" >"$planted_done"
  key_t1 "$repository"
  if [ -e "$planted_open" ] || [ ! -e "$planted_done" ]; then
    echo 'T1 did not reap the unfinished receipt of a dead producer, or reaped a completed receipt of another key' >&2
    exit 1
  fi
  expect_open_gate "$repository" 'tree verified again'
}

# git add -A は submodule の HEAD しか記録しない。中の変更も別の木になる。
check_receipt_follows_submodule() {
  local source=$fixture/key-submodule-source super=$fixture/key-submodule-super

  key_git init -q "$source"
  printf 's\n' >"$source/s"
  key_git -C "$source" add s
  key_git -C "$source" commit -qm 'test: 部品の追加'
  t1_repository "$super" 60
  key_git -C "$super" submodule add -q "$source" sub
  key_git -C "$super" commit -qm 'test: 部品の追加'
  key_t1 "$super"
  expect_open_gate "$super" 'tree with a submodule the run verified'

  printf 'u\n' >"$super/sub/untracked"
  expect_changed_tree "$super" 'untracked file inside the submodule'
  rm "$super/sub/untracked"
  expect_open_gate "$super" 'untracked file inside the submodule removed'
  printf 'dirty\n' >>"$super/sub/s"
  expect_changed_tree "$super" 'modified file inside the submodule'
  key_git -C "$super/sub" checkout -q -- s
  expect_open_gate "$super" 'modified file inside the submodule reverted'
  printf 's2\n' >"$super/sub/s"
  key_git -C "$super/sub" commit -qam 'test: 部品の変更'
  expect_changed_tree "$super" 'moved submodule HEAD'
}

# 採れない木では、検査の入口は通しても証跡を作らない。
check_tree_that_cannot_be_read() {
  local repository=$fixture/key-refusal fresh=$fixture/key-fresh output receipts runs=$fixture/key-entry-runs
  local stderr=$fixture/key-refusal-stderr

  t1_repository "$repository" 60
  key_t1 "$repository"
  expect_open_gate "$repository" 'clean tree the run verified'

  printf 'secret\n' >"$repository/unreadable"
  chmod 000 "$repository/unreadable"
  if [ -r "$repository/unreadable" ]; then
    echo 'unreadable file case skipped: this user reads a mode 000 file' >&2
  else
    expect_key_refused "$repository" unreadable 'unreadable untracked file'
    receipts=$(stall_receipt_count)
    rm -f "$runs"
    (cd "$repository" && PATH="$fixture/key-count-bin:$PATH" KEY_ENTRY_RUNS=$runs \
      "$VERIFY" -- devenv shell -- verify) 2>"$stderr"
    if [ "$(cat "$runs")" != 1 ] || [ "$(stall_receipt_count)" != "$receipts" ] \
      || ! grep -qF '証跡を作らない' "$stderr"; then
      echo 'T1 on an unreadable file did not run the entry exactly once without a receipt' >&2
      exit 1
    fi
    expect_key_refused "$repository" unreadable 'unreadable file after a T1 run'
  fi
  chmod 600 "$repository/unreadable"
  rm "$repository/unreadable"
  expect_open_gate "$repository" 'unreadable file removed'

  key_git init -q "$repository/nested"
  expect_key_refused "$repository" nested 'nested repository without a commit'
  rm -rf "$repository/nested"
  expect_open_gate "$repository" 'nested repository removed'

  expect_refused_when_tmpdir_is_in_tree "$repository"
  expect_open_gate "$repository" 'scratch directory removed'

  # index が未作成の repository でも鍵は採れ、何も書かない
  git init -q "$fresh"
  printf 'scripts.verify.exec = "true";\n' >"$fresh/devenv.nix"
  declare_budget "$fresh" 60
  output=$("$GATE" check --repo "$fresh" 2>&1) || true
  if [[ $output == *'木の鍵を採れない'* ]]; then
    echo "a repository without an index file was refused: $output" >&2
    exit 1
  fi
  "$GATE" waive --repo "$fresh" --reason fixture >/dev/null
  "$GATE" check --repo "$fresh" >/dev/null 2>&1
  if [ -e "$fresh/.git/index" ]; then
    echo 'the key wrote an index into a repository that had none' >&2
    exit 1
  fi
}

# stage と commit だけの呼び出しは中身を変えないため、stop を止めない。中身の変更と、鍵を採れない木は止める。
check_observe_follows_content() {
  local repository name

  name=commit-only
  repository=$(key_observed_repository "$name")
  printf 'held again\n' >>"$repository/held"
  key_git -C "$repository" add held
  key_observe "$name" PreToolUse call "$repository"
  key_git -C "$repository" commit -qm 'test: 呼び出しの中の commit'
  key_observe "$name" PostToolUse call "$repository"
  key_stop "$name" "$repository" || { echo 'a call that only committed staged content armed the session' >&2; exit 1; }

  name=stage-only
  repository=$(key_observed_repository "$name")
  printf 'held again\n' >>"$repository/held"
  key_observe "$name" PreToolUse call "$repository"
  key_git -C "$repository" add held
  key_observe "$name" PostToolUse call "$repository"
  key_stop "$name" "$repository" || { echo 'a call that only staged tracked content armed the session' >&2; exit 1; }

  name=content
  repository=$(key_observed_repository "$name")
  key_observe "$name" PreToolUse call "$repository"
  printf 'held again\n' >>"$repository/held"
  key_observe "$name" PostToolUse call "$repository"
  if key_stop "$name" "$repository"; then
    echo 'a call that changed content did not arm the session' >&2
    exit 1
  fi

  name=pre-failure
  repository=$(key_observed_repository "$name")
  key_git init -q "$repository/nested"
  key_observe "$name" PreToolUse call "$repository"
  if key_stop "$name" "$repository"; then
    echo 'a call whose tree key could not be taken before it ran did not arm the session' >&2
    exit 1
  fi

  name=tmpdir-in-tree
  repository=$(key_observed_repository "$name")
  mkdir "$repository/scratch"
  TMPDIR=$repository/scratch key_observe "$name" PreToolUse call "$repository"
  if key_stop "$name" "$repository" || [ -n "$(find "$repository/scratch" -mindepth 1)" ]; then
    echo 'a call under a TMPDIR inside the tree did not arm the session, or left something in the tree' >&2
    exit 1
  fi
}

# Nix の入口は未追跡 file があると入口の解決が拒否する。追跡を促す一行を重ねて出さない
check_nix_entry_refusal_is_not_repeated() {
  local repository=$fixture/key-nix status=0 stderr=$fixture/key-nix-stderr

  git init -q "$repository"
  printf '{ outputs = { self }: { apps.x86_64-linux.verify = { type = "app"; program = "/bin/false"; }; }; }\n' \
    >"$repository/flake.nix"
  printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":60}}\n' >"$repository/tiergate.json"
  key_git -C "$repository" add flake.nix tiergate.json
  key_git -C "$repository" commit -qm 'test: Nix の入口の追加'
  printf 'u\n' >"$repository/untracked"
  (cd "$repository" && "$VERIFY" -- nix run --no-write-lock-file .#verify) 2>"$stderr" || status=$?
  if [ "$status" -ne 1 ] || ! grep -qF '先に追跡してから検証する' "$stderr"; then
    echo "T1 on the Nix entry with an untracked file did not refuse at the entry resolution: $status" >&2
    exit 1
  fi
  expect_hint_count "$stderr" 0 'Nix entry that refuses untracked files'
}

check_receipt_follows_content
check_receipt_follows_submodule
check_tree_that_cannot_be_read
check_observe_follows_content
check_nix_entry_refusal_is_not_repeated
