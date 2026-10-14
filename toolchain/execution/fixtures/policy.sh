#!/usr/bin/env bash
# 実行された command が受け取る環境と argv から、cache の既定、明示値の優先、project の Cargo 設定の優先、
# 出力先の checkout 別分割、no-result-link の PATH、directory を作らないことを読む。
set -euo pipefail

fixture=$PWD/policy-fixture
shared=$fixture/cache/shared
build=$fixture/cache/cargo-build
out=$fixture/out
project=$fixture/project
mkdir -p "$out" "$project/sub dir/deeper"

cat > "$fixture/probe.sh" <<'SCRIPT'
printf '%s\0' "$@" > "$OUT/argv"
for name in CARGO_HOME XDG_CACHE_HOME CARGO_BUILD_BUILD_DIR CARGO_TARGET_DIR; do
  if [ "${!name+x}" = x ]; then
    printf 'set:%s\n' "${!name}"
  else
    printf 'unset\n'
  fi > "$OUT/$name"
done
printf '%s\n' "${PATH%%:*}" > "$OUT/path-first"
command -v nix > "$OUT/nix"
command -v nix-build > "$OUT/nix-build"
pwd -P > "$OUT/cwd"
exit "${PROBE_STATUS:-0}"
SCRIPT

probe_args=('' 'space arg' $'line\narg' 'ユニコード' -- --shared-cache elsewhere)

run() {
  env -u CARGO_HOME -u XDG_CACHE_HOME -u CARGO_BUILD_BUILD_DIR -u CARGO_TARGET_DIR \
    OUT="$out" "$@" "$POLICY" --shared-cache "$shared" --build-root "$build" -- \
    "$BASH" "$fixture/probe.sh" "${probe_args[@]}"
}

value_of() {
  cat "$out/$1"
}

assert_value() {
  test "$(value_of "$1")" = "set:$2" || {
    echo "$1 is '$(value_of "$1")', expected '$2'" >&2
    exit 1
  }
}

assert_unset() {
  test "$(value_of "$1")" = unset || {
    echo "$1 is '$(value_of "$1")', expected it to be unset" >&2
    exit 1
  }
}

workspace_build_dir="$build/{workspace-path-hash}"

# Nothing is specified: shared caches, and a checkout-separated build-dir under the build root.
run
assert_value CARGO_HOME "$shared/cargo-home"
assert_value XDG_CACHE_HOME "$shared/xdg-cache"
assert_value CARGO_BUILD_BUILD_DIR "$workspace_build_dir"
assert_unset CARGO_TARGET_DIR
test "$(value_of path-first)" = "$SHIM_DIR/bin"
test "$(value_of nix)" = "$SHIM_DIR/bin/nix"
test "$(value_of nix-build)" = "$SHIM_DIR/bin/nix-build"

# argv after -- is not read as policy options, and nothing is re-split or dropped.
mapfile -d '' -t argv < "$out/argv"
test "${#argv[@]}" -eq 7
test -z "${argv[0]}"
test "${argv[1]}" = 'space arg'
test "${argv[2]}" = $'line\narg'
test "${argv[3]}" = 'ユニコード'
test "${argv[4]}" = --
test "${argv[5]}" = --shared-cache
test "${argv[6]}" = elsewhere

# The exit status and the working directory are the command's own.
status=0
(
  cd "$project/sub dir"
  run PROBE_STATUS=17
) || status=$?
test "$status" -eq 17
test "$(value_of cwd)" = "$(realpath "$project/sub dir")"

# Explicit values belong to the caller, including empty strings.
run CARGO_HOME=/explicit-cargo XDG_CACHE_HOME=/explicit-xdg
assert_value CARGO_HOME /explicit-cargo
assert_value XDG_CACHE_HOME /explicit-xdg
run CARGO_HOME= XDG_CACHE_HOME=
assert_value CARGO_HOME ''
assert_value XDG_CACHE_HOME ''
run CARGO_BUILD_BUILD_DIR=/explicit
assert_value CARGO_BUILD_BUILD_DIR /explicit
assert_unset CARGO_TARGET_DIR
run CARGO_BUILD_BUILD_DIR=
assert_value CARGO_BUILD_BUILD_DIR ''
run CARGO_TARGET_DIR=/explicit
assert_value CARGO_TARGET_DIR /explicit
assert_unset CARGO_BUILD_BUILD_DIR
run CARGO_TARGET_DIR=
assert_value CARGO_TARGET_DIR ''
assert_unset CARGO_BUILD_BUILD_DIR

# The project's own Cargo output setting wins, in the working directory and in an ancestor.
mkdir -p "$project/.cargo"
for key in target-dir build-dir; do
  printf '[build]\n%s = "project-output"\n' "$key" > "$project/.cargo/config.toml"
  (cd "$project" && run)
  assert_unset CARGO_BUILD_BUILD_DIR
  assert_unset CARGO_TARGET_DIR
  (cd "$project/sub dir/deeper" && run)
  assert_unset CARGO_BUILD_BUILD_DIR
  assert_unset CARGO_TARGET_DIR
done
rm "$project/.cargo/config.toml"
printf '[build]\ntarget-dir = "legacy-output"\n' > "$project/.cargo/config"
(cd "$project" && run)
assert_unset CARGO_BUILD_BUILD_DIR
rm "$project/.cargo/config"

# A Cargo config with no output setting leaves the policy in force.
printf '[net]\noffline = true\n' > "$project/.cargo/config.toml"
(cd "$project" && run)
assert_value CARGO_BUILD_BUILD_DIR "$workspace_build_dir"

# A config Cargo may read but the policy cannot judge is not overridden: malformed, symlinked, not a file.
printf '[build\n' > "$project/.cargo/config.toml"
(cd "$project" && run)
assert_unset CARGO_BUILD_BUILD_DIR
rm "$project/.cargo/config.toml"
printf '[build]\ntarget-dir = "elsewhere"\n' > "$fixture/real-config.toml"
ln -s "$fixture/real-config.toml" "$project/.cargo/config.toml"
(cd "$project" && run)
assert_unset CARGO_BUILD_BUILD_DIR
rm "$project/.cargo/config.toml"
mkdir "$project/.cargo/config.toml"
(cd "$project" && run)
assert_unset CARGO_BUILD_BUILD_DIR
rmdir "$project/.cargo/config.toml"

# The policy chooses locations only. It creates and reclaims nothing.
test ! -e "$fixture/cache"

# Usage errors run nothing.
rm -f "$out/argv"
status=0
"$POLICY" --shared-cache "$shared" "$BASH" "$fixture/probe.sh" 2>/dev/null || status=$?
test "$status" -eq 2
status=0
"$POLICY" --bogus -- "$BASH" "$fixture/probe.sh" 2>/dev/null || status=$?
test "$status" -eq 2
status=0
"$POLICY" --build-root 2>/dev/null || status=$?
test "$status" -eq 2
status=0
"$POLICY" -- 2>/dev/null || status=$?
test "$status" -eq 2
test ! -e "$out/argv"
