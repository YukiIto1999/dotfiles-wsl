#!/usr/bin/env bash
set -euo pipefail

export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

new_repo() {
  local repo=$PWD/$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s' "$repo"
}

expect() {
  local repo=$1 name=$2 expected=$3 actual
  actual=$("$ENTRY" --repo "$repo" "$name")
  if [ "$actual" != "$expected" ]; then
    printf '%s %s: expected [%s], got [%s]\n' "$repo" "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

# 各段の名前を、宣言の置き場ごとの綴りで答える
devenv=$(new_repo devenv)
printf 'scripts.verify-push.exec = "true";\nscripts.verify-full.exec = "true";\n' >"$devenv/devenv.nix"
expect "$devenv" verify-push 'devenv shell -- verify-push'
expect "$devenv" verify-full 'devenv shell -- verify-full'
# 後ろに続く段の名前を、T1 の宣言と読まない
expect "$devenv" verify ''
printf 'scripts.verify.exec = "true";\n' >>"$devenv/devenv.nix"
expect "$devenv" verify 'devenv shell -- verify'

just=$(new_repo just)
printf 'verify-push:\n    true\n' >"$just/justfile"
expect "$just" verify-push 'just verify-push'
expect "$just" verify ''

pnpm=$(new_repo pnpm)
printf '{"scripts":{"verify":"true","verify:push":"true","verify:full":"true"}}\n' >"$pnpm/package.json"
: >"$pnpm/pnpm-lock.yaml"
expect "$pnpm" verify 'pnpm verify'
expect "$pnpm" verify-push 'pnpm verify:push'
expect "$pnpm" verify-full 'pnpm verify:full'

npm=$(new_repo npm)
printf '{"scripts":{"verify:push":"true"}}\n' >"$npm/package.json"
expect "$npm" verify-push 'npm run verify:push'
expect "$npm" verify ''

make=$(new_repo make)
printf 'verify-full:\n\ttrue\n' >"$make/Makefile"
expect "$make" verify-full 'make verify-full'
expect "$make" verify-push ''

# 一つの repository に複数の置き場があれば devenv を先に採る
printf 'scripts.verify-full.exec = "true";\n' >"$make/devenv.nix"
expect "$make" verify-full 'devenv shell -- verify-full'

# 下の directory から問うても repository の根の宣言を答える
mkdir -p "$make/nested"
expect "$make/nested" verify-full 'devenv shell -- verify-full'

# git の木の外では何も答えない
mkdir outside
printf 'verify-full:\n\ttrue\n' >outside/Makefile
expect "$PWD/outside" verify-full ''

# 段に無い名前は拒む
if "$ENTRY" --repo "$make" verify-nightly >/dev/null 2>&1; then
  echo 'resolver accepted an unknown entry name' >&2
  exit 1
fi
