#!/usr/bin/env bash
set -euo pipefail

# BUILD: dotfiles-verification-build。store を持たず、nix は引数を記録して out-link だけを置く偽物に差し替える。
# 実 nix は全 installable の成功後にだけ link を原子的に置き換える。偽物はその契約を写し、build の呼び出し側が守る契約を確かめる
: "${BUILD:?}"

fail() {
  printf 'build-rooted: %s\n' "$*" >&2
  exit 1
}

export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES=$PWD
export NIX_STORE_DIR=$PWD/store FIXTURE_LOG=$PWD/nix.log
hold_a=$PWD/hold-a
hold_b=$PWD/hold-b
mkdir -p "$HOME" "$NIX_STORE_DIR" shims outside
export PATH=$PWD/shims:$PATH
trap 'rm -f -- "$hold_a" "$hold_b"' EXIT

printf '#!%s\n' "$BASH" >shims/nix
cat >>shims/nix <<'SH'
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_LOG"
case $1 in
config)
  [ "$*" = 'config show min-free' ] || exit 2
  [ -n "${FIXTURE_MIN_FREE-}" ] || { echo 'error: no min-free' >&2; exit 1; }
  printf '%s\n' "$FIXTURE_MIN_FREE"
  ;;
build)
  shift
  prefix=
  installables=()
  while [ "$#" -gt 0 ]; do
    case $1 in
    --out-link)
      prefix=$2
      shift 2
      ;;
    --no-link | --no-write-lock-file | -L) shift ;;
    *)
      installables+=("$1")
      shift
      ;;
    esac
  done
  if [ -n "${FIXTURE_HOLD-}" ]; then
    : >"$FIXTURE_HOLD.started"
    while [ -e "$FIXTURE_HOLD" ]; do sleep 0.05; done
  fi
  if [ -n "${FIXTURE_BUILD_FAILS-}" ]; then
    echo 'error: build failed' >&2
    exit "$FIXTURE_BUILD_FAILS"
  fi
  [ -n "$prefix" ] || exit 0
  for i in "${!installables[@]}"; do
    link=$prefix
    [ "$i" -eq 0 ] || link+=-$i
    mkdir -p "$NIX_STORE_DIR/$FIXTURE_GENERATION-$i"
    ln -s "$NIX_STORE_DIR/$FIXTURE_GENERATION-$i" "$link.tmp.$$"
    mv -T -- "$link.tmp.$$" "$link"
  done
  ;;
*) exit 2 ;;
esac
SH
chmod +x shims/nix

new_repo() {
  local repo=$PWD/$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m 'test: 保持の確認'
}

# 引数: 実行する directory と build の引数
# 出力: status、build.err、nix に渡った引数の記録 nix.log
run_build() {
  local directory=$1
  shift
  : >"$FIXTURE_LOG"
  status=0
  (cd "$directory" && exec bash "$BUILD" "$@") >build.out 2>build.err </dev/null || status=$?
}

expect_status() {
  [ "$status" -eq "$1" ] || fail "$2: status $status instead of $1: $(cat build.err)"
}

expect_calls() {
  local label=$1 expected actual
  shift
  expected=$(printf '%s\n' "$@")
  actual=$(<"$FIXTURE_LOG")
  [ "$actual" = "$expected" ] || fail "$label: nix was called with [$actual] instead of [$expected]"
}

expect_message() {
  grep -q -F -- "$1" build.err || fail "$2: stderr lacks [$1]: $(cat build.err)"
}

# 引数: link と、それが指すはずの generation。指す先が実在することも確かめる
expect_link() {
  local actual
  actual=$(readlink -- "$1") || fail "$1 is not a symlink"
  [ "$actual" = "$NIX_STORE_DIR/$2" ] || fail "$1 points to $actual instead of $2"
  [ -d "$actual" ] || fail "$1 does not resolve"
}

expect_entries() {
  local actual
  actual=$(find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
  [ "${actual% }" = "$2" ] || fail "$1 holds [${actual% }] instead of [$2]"
}

wait_for_file() {
  local attempts=0
  until [ -e "$1" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -le 300 ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

run_build "$PWD/outside"
expect_status 64 'no installable'
test ! -s "$FIXTURE_LOG" || fail 'a call without an installable reached nix'

# 新しい source の成功は、空きがあれば checkout の git-dir に unit と closure の root を置く
new_repo checkout
git_dir=$(git -C checkout rev-parse --absolute-git-dir)
roots=$git_dir/dotfiles-verification-roots
FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g1 run_build "$PWD/checkout" unit closure
expect_status 0 'fresh source'
expect_calls 'fresh source' 'config show min-free' \
  "build --no-write-lock-file -L --out-link $roots/outputs unit closure"
expect_link "$roots/outputs" g1-0
expect_link "$roots/outputs-1" g1-1
expect_entries "$roots" 'outputs outputs-1'
test -z "$(git -C checkout status --porcelain --untracked-files=all)" || fail 'the working tree of the checkout changed'

# unit だけを作る段は unit の root だけを置き換える。closure の root は消さず、増やさない
FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g2 run_build "$PWD/checkout" unit
expect_status 0 'unit only'
expect_calls 'unit only' 'config show min-free' \
  "build --no-write-lock-file -L --out-link $roots/outputs unit"
expect_link "$roots/outputs" g2-0
expect_link "$roots/outputs-1" g1-1
expect_entries "$roots" 'outputs outputs-1'

# 失敗した repeat は、前に成功した root を消さず、終了 status を変えない
FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g3 FIXTURE_BUILD_FAILS=3 run_build "$PWD/checkout" unit closure
expect_status 3 'failed repeat'
expect_link "$roots/outputs" g2-0
expect_link "$roots/outputs-1" g1-1
expect_entries "$roots" 'outputs outputs-1'

# 空きが min-free を下回る間は、成功しても root を置き換えず、増やさず、前の root は残す
FIXTURE_MIN_FREE=999999999999999999 FIXTURE_GENERATION=g4 run_build "$PWD/checkout" unit closure
expect_status 0 'below min-free'
expect_calls 'below min-free' 'config show min-free' \
  'build --no-write-lock-file -L --no-link unit closure'
expect_message 'below nix min-free' 'below min-free'
expect_link "$roots/outputs" g2-0
expect_link "$roots/outputs-1" g1-1
new_repo cold
cold_git=$(git -C cold rev-parse --absolute-git-dir)
FIXTURE_MIN_FREE=999999999999999999 FIXTURE_GENERATION=g4 run_build "$PWD/cold" unit closure
expect_status 0 'cold checkout below min-free'
test ! -e "$cold_git/dotfiles-verification-roots" || fail 'a checkout below min-free received a root directory'

# 空きを判断できない時は、保持を増やさずに build だけを行う
run_build "$PWD/cold" unit
expect_status 0 'min-free missing'
expect_calls 'min-free missing' 'config show min-free' 'build --no-write-lock-file -L --no-link unit'
expect_message 'min-free is not readable' 'min-free missing'
FIXTURE_MIN_FREE=unlimited run_build "$PWD/cold" unit
expect_status 0 'min-free malformed'
expect_message 'min-free is not readable' 'min-free malformed'
NIX_STORE_DIR=$PWD/absent FIXTURE_MIN_FREE=0 run_build "$PWD/cold" unit
expect_status 0 'store missing'
expect_message 'is not readable' 'store missing'
test ! -e "$cold_git/dotfiles-verification-roots" || fail 'an unreadable free space still created a root directory'

# git の木の外では、root を置く場所が無いので nix にも空きを問わずに build する
FIXTURE_MIN_FREE=0 run_build "$PWD/outside" unit
expect_status 0 'outside git'
expect_calls 'outside git' 'build --no-write-lock-file -L --no-link unit'
expect_message 'no readable git checkout at' 'outside git'

# 下の directory から呼んでも checkout の root を置き換え、下の directory には何も置かない
mkdir checkout/nested
FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g5 run_build "$PWD/checkout/nested" unit
expect_status 0 'nested directory'
expect_link "$roots/outputs" g5-0
expect_link "$roots/outputs-1" g1-1
test ! -e checkout/nested/dotfiles-verification-roots || fail 'a root directory was created below the checkout root'

# worktree は自分の git-dir に root を持ち、他の checkout の root を置き換えない。worktree を消せば root も消える
git -C checkout worktree add -q "$PWD/linked" -b linked
linked_git=$(git -C linked rev-parse --absolute-git-dir)
FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g6 run_build "$PWD/linked" unit closure
expect_status 0 'worktree'
expect_link "$linked_git/dotfiles-verification-roots/outputs" g6-0
expect_link "$linked_git/dotfiles-verification-roots/outputs-1" g6-1
expect_link "$roots/outputs" g5-0
expect_link "$roots/outputs-1" g1-1
git -C checkout worktree remove --force "$PWD/linked"
test ! -e "$linked_git" || fail 'a removed worktree kept its roots'

# 重なった走行の間も前の root は有効で、後から終わった走行の root だけが残り、link は増えない
: >"$hold_a"
: >"$hold_b"
(cd checkout && FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=ga FIXTURE_HOLD=$hold_a exec bash "$BUILD" unit closure) >a.out 2>a.err </dev/null &
pid_a=$!
(cd checkout && FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=gb FIXTURE_HOLD=$hold_b exec bash "$BUILD" unit closure) >b.out 2>b.err </dev/null &
pid_b=$!
wait_for_file "$hold_a.started"
wait_for_file "$hold_b.started"
expect_link "$roots/outputs" g5-0
expect_link "$roots/outputs-1" g1-1
rm -f -- "$hold_b"
wait "$pid_b"
expect_link "$roots/outputs" gb-0
expect_link "$roots/outputs-1" gb-1
rm -f -- "$hold_a"
wait "$pid_a"
expect_link "$roots/outputs" ga-0
expect_link "$roots/outputs-1" ga-1
expect_entries "$roots" 'outputs outputs-1'

# 検査の copy が所有 checkout を名指すと、root は所有 checkout の root を置き換え、copy の git-dir には何も置かない
git clone -q --local --no-checkout -- "$PWD/checkout" "$PWD/copy"
copy_git=$(git -C copy rev-parse --absolute-git-dir)
DOTFILES_VERIFICATION_OWNER=$PWD/checkout FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g7 run_build "$PWD/copy" unit
expect_status 0 'copy naming its owner'
expect_calls 'copy naming its owner' 'config show min-free' \
  "build --no-write-lock-file -L --out-link $roots/outputs unit"
expect_link "$roots/outputs" g7-0
expect_link "$roots/outputs-1" ga-1
test ! -e "$copy_git/dotfiles-verification-roots" || fail 'a copy that named its owner received roots of its own'

# copy の失敗した repeat も、空きが足りない走行も、所有 checkout の前の root を消さない
DOTFILES_VERIFICATION_OWNER=$PWD/checkout FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g8 FIXTURE_BUILD_FAILS=1 run_build "$PWD/copy" unit
expect_status 1 'copy failed repeat'
expect_link "$roots/outputs" g7-0
DOTFILES_VERIFICATION_OWNER=$PWD/checkout FIXTURE_MIN_FREE=999999999999999999 FIXTURE_GENERATION=g8 run_build "$PWD/copy" unit
expect_status 0 'copy below min-free'
expect_calls 'copy below min-free' 'config show min-free' 'build --no-write-lock-file -L --no-link unit'
expect_link "$roots/outputs" g7-0

# 所有 checkout を読めない時は、copy の git-dir へ退かずに保持しない
DOTFILES_VERIFICATION_OWNER=$PWD/outside FIXTURE_MIN_FREE=0 FIXTURE_GENERATION=g9 run_build "$PWD/copy" unit
expect_status 0 'unreadable owner'
expect_calls 'unreadable owner' 'build --no-write-lock-file -L --no-link unit'
expect_message "no readable git checkout at $PWD/outside" 'unreadable owner'
test ! -e "$copy_git/dotfiles-verification-roots" || fail 'an unreadable owner made the copy receive roots of its own'
expect_link "$roots/outputs" g7-0

# copy の削除は所有 checkout の root を消さない
rm -rf -- copy
expect_link "$roots/outputs" g7-0
expect_link "$roots/outputs-1" ga-1
expect_entries "$roots" 'outputs outputs-1'
