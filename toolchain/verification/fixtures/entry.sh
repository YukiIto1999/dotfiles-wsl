#!/usr/bin/env bash
set -euo pipefail

export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

new_repo() {
  local repo=$PWD/$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m 'test: 検証入口の確認'
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

expect_unevaluated() {
  local repo=$1 name=$2 expected=$3 actual
  actual=$(timeout 60 "$ENTRY" --repo "$repo" "$name")
  if [ "$actual" != "$expected" ]; then
    printf '%s %s: expected [%s], got [%s]\n' "$repo" "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

expect_usage() {
  local status=0
  "$ENTRY" "$@" >usage.stdout 2>usage.stderr || status=$?
  if [ "$status" -ne 64 ] || [ -s usage.stdout ] || [ ! -s usage.stderr ]; then
    printf 'resolver did not refuse the call (status %s): %s\n' "$status" "$*" >&2
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

native=$(new_repo 'native apps')
cat >"$native/flake.nix" <<'NIX'
{
  outputs = { self }: {
    apps.x86_64-linux.verify-push = { type = "app"; program = "/bin/false"; };
    apps.x86_64-linux.verify-full = { type = "app"; program = "/bin/false"; };
  };
}
NIX
printf 'verify:\n\tfalse\n' >"$native/Makefile"
printf '{"version":1,"frontend":"nix","entries":["verify-push","verify-full"],"verify-push":{"seconds":900}}\n' \
  >"$native/verification-budget.json"
git -C "$native" add flake.nix Makefile verification-budget.json
git -C "$native" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m 'test: 検証入口の確認'
expect "$native" verify-push 'nix run --no-write-lock-file .#verify-push'
expect "$native" verify-full 'nix run --no-write-lock-file .#verify-full'
expect "$native" verify ''
mkdir "$native/nested"
expect "$native/nested" verify-push 'nix run --no-write-lock-file .#verify-push'
printf 'not verified\n' >"$native/untracked"
if "$ENTRY" --repo "$native" verify-push >untracked.stdout 2>untracked.stderr; then
  printf 'resolver accepted untracked source excluded from the Nix flake\n' >&2
  exit 1
fi
test ! -s untracked.stdout
git -C "$native" add -N untracked
expect "$native" verify-push 'nix run --no-write-lock-file .#verify-push'

absent=$(new_repo absent)
printf '{ outputs = { self }: {}; }\n' >"$absent/flake.nix"
printf 'verify:\n\tfalse\n' >"$absent/Makefile"
git -C "$absent" add flake.nix Makefile
expect "$absent" verify 'make verify'

broken=$(new_repo broken)
printf '{ outputs =\n' >"$broken/flake.nix"
printf 'verify:\n\tfalse\n' >"$broken/Makefile"
git -C "$broken" add flake.nix Makefile
expect_unevaluated "$broken" verify 'make verify'

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

expect_usage --repo "$make"
expect_usage --repo "$make" --budget --candidates verify
expect_usage --repo "$make" verify verify-push

stalled=$(new_repo stalled)
cat >"$stalled/flake.nix" <<'NIX'
{
  outputs = { self }: {
    apps =
      let fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2);
      in if fib 60 > 0 then { } else { };
  };
}
NIX
printf 'verify:\n\ttrue\n' >"$stalled/Makefile"
git -C "$stalled" add flake.nix Makefile
git -C "$stalled" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m 'test: 評価が止まる宣言'
expect_unevaluated "$stalled" verify 'make verify'
expect_unevaluated "$stalled" verify-push ''
expect_unevaluated "$native" verify ''
expect_unevaluated "$PWD/outside" verify-full ''

actual=$("$ENTRY" --repo "$stalled" --candidates verify)
test "$actual" = $'make verify\nnix run --no-write-lock-file .#verify'
actual=$("$ENTRY" --repo "$stalled" --candidates verify-push)
test "$actual" = 'nix run --no-write-lock-file .#verify-push'

printf '{"version":1,"frontend":"nix","entries":["verify"],"verify":{"seconds":2}}\n' >"$stalled/verification-budget.json"
git -C "$stalled" add verification-budget.json
expect_unevaluated "$stalled" verify 'nix run --no-write-lock-file .#verify'
expect_unevaluated "$stalled" verify-push ''

expect_entry_refused() {
  if "$ENTRY" --repo "$1" "$2" >entry.stdout 2>entry.stderr; then
    printf 'resolver accepted invalid metadata: %s\n' "$3" >&2
    exit 1
  fi
  test ! -s entry.stdout
  test -s entry.stderr
}

git -C "$native" rm -q verification-budget.json
expect_entry_refused "$native" verify-push 'removed tracked native declaration'
git -C "$native" restore --staged --worktree -- verification-budget.json
printf 'not json\n' >"$native/verification-budget.json"
expect_entry_refused "$native" verify-push 'malformed native declaration'
git -C "$native" restore --worktree -- verification-budget.json
expect "$native" verify-push 'nix run --no-write-lock-file .#verify-push'

expect_budget() {
  local repo=$1 name=$2 expected=$3 actual
  actual=$("$ENTRY" --repo "$repo" --budget "$name")
  if [ "$actual" != "$expected" ]; then
    printf '%s %s budget: expected [%s], got [%s]\n' "$repo" "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

expect_budget_refused() {
  local repo=$1 name=$2 label=$3
  if "$ENTRY" --repo "$repo" --budget "$name" >budget.stdout 2>budget.stderr; then
    printf '%s: resolver accepted the budget declaration\n' "$label" >&2
    exit 1
  fi
  if [ -s budget.stdout ] || [ ! -s budget.stderr ]; then
    printf '%s: refusal must leave stdout empty and explain on stderr\n' "$label" >&2
    exit 1
  fi
}

budgeted=$(new_repo budgeted)
printf '{"version":1,"verify":{"seconds":120},"verify-push":{"seconds":900}}\n' >"$budgeted/verification-budget.json"
expect_budget "$budgeted" verify 120
expect_budget "$budgeted" verify-push 900
expect_budget_refused "$budgeted" verify-full 'stage without a declaration'
mkdir "$budgeted/nested"
expect_budget "$budgeted/nested" verify 120

larger=$(new_repo larger)
printf '{"version":1,"verify":{"seconds":600}}\n' >"$larger/verification-budget.json"
expect_budget "$larger" verify 600
expect_budget "$budgeted" verify 120

printf 'scripts.verify.exec = "true";\n' >"$larger/devenv.nix"
printf 'not json\n' >"$larger/verification-budget.json"
expect_entry_refused "$larger" verify 'malformed project declaration'
expect_budget_refused "$larger" verify 'malformed declaration'

invalid=$(new_repo invalid)
expect_budget_refused "$invalid" verify 'missing declaration file'
while read -r label content <&3; do
  printf '%s\n' "$content" >"$invalid/verification-budget.json"
  expect_budget_refused "$invalid" verify "$label"
done 3<<'DECLARATIONS'
zero {"version":1,"verify":{"seconds":0}}
negative {"version":1,"verify":{"seconds":-1}}
fractional {"version":1,"verify":{"seconds":1.5}}
string {"version":1,"verify":{"seconds":"120"}}
oversized {"version":1,"verify":{"seconds":2147483648}}
version {"version":2,"verify":{"seconds":120}}
stage-missing {"version":1}
seconds-missing {"version":1,"verify":{}}
other-stage {"version":1,"verify-push":{"seconds":120}}
array []
DECLARATIONS
printf '{"version":1,"verify":{"seconds":2147483647}}\n' >"$invalid/verification-budget.json"
expect_budget "$invalid" verify 2147483647

expect_budget_refused "$PWD/outside" verify 'declaration outside a git tree'
if "$ENTRY" --repo "$budgeted" --budget verify-nightly >/dev/null 2>&1; then
  echo 'resolver accepted an unknown budget stage' >&2
  exit 1
fi
