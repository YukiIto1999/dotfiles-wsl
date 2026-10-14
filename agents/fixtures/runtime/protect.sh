#!/usr/bin/env bash
# GC root の取得が返す store object、root の名前と指す先、失敗時に何も残さないこと、roots directory の所有と mode を、
# 実際に作られた link から読む。nix-store は sandbox にないため、root を symlink で作って呼び出しを記録する fake に替える。
set -euo pipefail

fixture=$PWD/protect-fixture
roots=$fixture/roots
mkdir -p "$fixture"
cd "$fixture"
export NIX_STORE_LOG=$fixture/nix-store.log
: > "$NIX_STORE_LOG"

fail() {
  echo "$*" >&2
  exit 1
}

link_names() {
  ls -A "$1"
}

# A store directory and a file inside another object resolve to their objects; the roots are named after the objects.
mapfile -t printed < <("$PROTECT" "$roots" "$DEPENDENCY_A" "$DEPENDENCY_B/bin/jq")
test "${#printed[@]}" -eq 2
test "${printed[0]}" = "$DEPENDENCY_A"
test "${printed[1]}" = "$DEPENDENCY_B"
test "$(stat -c %a "$roots")" = 700
test "$(readlink "$roots/${DEPENDENCY_A##*/}")" = "$DEPENDENCY_A"
test "$(readlink "$roots/${DEPENDENCY_B##*/}")" = "$DEPENDENCY_B"
test "$(link_names "$roots" | wc -l)" -eq 2
test "$(grep -c -- '--option substitute false' "$NIX_STORE_LOG")" -eq 2
test "$(grep -c -- '--indirect' "$NIX_STORE_LOG")" -eq 2

# A symlink chain, the way a client profile publishes its executable, resolves to the store file it reached.
mkdir -p "$fixture/chain"
ln -sfn "$FAKE_AGENT" "$fixture/chain/inner"
ln -sfn "$fixture/chain/inner" "$fixture/chain/outer"
mapfile -t printed < <("$PROTECT" --resolved "$roots" "$fixture/chain/outer")
test "${printed[0]}" = "$FAKE_AGENT"
mapfile -t printed < <("$PROTECT" "$roots" "$fixture/chain/outer")
test "${printed[0]}" = "$FAKE_AGENT"
test "$(readlink "$roots/${FAKE_AGENT##*/}")" = "$FAKE_AGENT"
# The path inside the object is what --resolved returns, so the caller can start exactly what was protected.
expected_resolved=$(realpath "$DEPENDENCY_B/bin/jq")
mapfile -t printed < <("$PROTECT" --resolved "$roots" "$DEPENDENCY_B/bin/jq")
test "${printed[0]}" = "$expected_resolved"

# A root that already names the object is kept without asking Nix again.
calls=$(wc -l < "$NIX_STORE_LOG")
"$PROTECT" "$roots" "$DEPENDENCY_A" > /dev/null
test "$(wc -l < "$NIX_STORE_LOG")" -eq "$calls"

# One object that cannot be protected fails the whole call and removes the roots this call took.
status=0
FAKE_NIX_STORE_FAIL=${DEPENDENCY_B##*/} "$PROTECT" "$fixture/fresh" "$DEPENDENCY_A" "$DEPENDENCY_B" \
  > "$fixture/out" 2> "$fixture/err" || status=$?
test "$status" -eq 70
test ! -s "$fixture/out"
grep -Fq 'cannot protect' "$fixture/err"
test -z "$(link_names "$fixture/fresh")"
status=0
FAKE_NIX_STORE_FAIL=${FAKE_AGENT##*/} "$PROTECT" "$fixture/fresh-agent" "$DEPENDENCY_A" "$fixture/chain/outer" 2>/dev/null || status=$?
test "$status" -eq 70
test -z "$(link_names "$fixture/fresh-agent")"

# Anything outside the Nix store, unreadable, or not absolute is refused.
printf 'plain\n' > "$fixture/plain-file"
for refused in "$fixture/plain-file" "$fixture/absent" /etc/hostname; do
  status=0
  "$PROTECT" "$fixture/refused-roots" "$refused" 2>/dev/null || status=$?
  test "$status" -eq 70 || fail "protected $refused"
  test -z "$(link_names "$fixture/refused-roots")"
done
status=0
"$PROTECT" relative-roots "$DEPENDENCY_A" 2>/dev/null || status=$?
test "$status" -eq 70
test ! -e relative-roots

# The roots directory is the caller's own directory: a symlink is refused and its target is left alone, and a loose mode is tightened.
mkdir -p "$fixture/elsewhere"
ln -s "$fixture/elsewhere" "$fixture/linked-roots"
status=0
"$PROTECT" "$fixture/linked-roots" "$DEPENDENCY_A" 2>/dev/null || status=$?
test "$status" -eq 70
test -z "$(link_names "$fixture/elsewhere")"
mkdir -m 0755 "$fixture/loose-roots"
"$PROTECT" "$fixture/loose-roots" "$DEPENDENCY_A" > /dev/null
test "$(stat -c %a "$fixture/loose-roots")" = 700
test "$(readlink "$fixture/loose-roots/${DEPENDENCY_A##*/}")" = "$DEPENDENCY_A"

# Missing operands are a usage error and take no root.
for usage in "" "--resolved" "$fixture/usage-roots"; do
  status=0
  if [ -n "$usage" ]; then
    "$PROTECT" "$usage" 2>/dev/null || status=$?
  else
    "$PROTECT" 2>/dev/null || status=$?
  fi
  test "$status" -eq 2
done
test ! -e "$fixture/usage-roots"
