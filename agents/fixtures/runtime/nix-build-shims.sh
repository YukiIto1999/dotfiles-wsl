#!/usr/bin/env bash
set -euo pipefail

capture() {
  local name=$1
  shift
  ARG_CAPTURE="$PWD/$name" "$@"
}

assert_argv() {
  local file=$1
  shift
  local -a actual
  mapfile -d '' -t actual < "$file"
  test "${#actual[@]}" -eq "$#"
  local index=0
  for expected in "$@"; do
    test "${actual[$index]}" = "$expected"
    index=$((index + 1))
  done
}

capture nix-default "$SHIM_DIR/bin/nix" build .#fixture
assert_argv nix-default build --no-link .#fixture

capture nix-out-link "$SHIM_DIR/bin/nix" build --out-link custom .#fixture
assert_argv nix-out-link build --out-link custom .#fixture

capture nix-no-link "$SHIM_DIR/bin/nix" build --no-link .#fixture
assert_argv nix-no-link build --no-link .#fixture

capture nix-other "$SHIM_DIR/bin/nix" flake check
assert_argv nix-other flake check

capture nix-global-option "$SHIM_DIR/bin/nix" --option warn-dirty false build .#fixture
assert_argv nix-global-option --option warn-dirty false build --no-link .#fixture

capture nix-global-feature "$SHIM_DIR/bin/nix" --extra-experimental-features flakes build .#fixture
assert_argv nix-global-feature --extra-experimental-features flakes build --no-link .#fixture

capture nix-global-out-link "$SHIM_DIR/bin/nix" \
  --option warn-dirty false build --out-link custom .#fixture
assert_argv nix-global-out-link --option warn-dirty false build --out-link custom .#fixture

capture nix-eval-build-value "$SHIM_DIR/bin/nix" eval --argstr name build .#fixture
assert_argv nix-eval-build-value eval --argstr name build .#fixture

capture nix-build-default "$SHIM_DIR/bin/nix-build" expression.nix
assert_argv nix-build-default --no-out-link expression.nix

capture nix-build-out-link "$SHIM_DIR/bin/nix-build" --out-link custom expression.nix
assert_argv nix-build-out-link --out-link custom expression.nix

capture nix-build-no-link "$SHIM_DIR/bin/nix-build" --no-out-link expression.nix
assert_argv nix-build-no-link --no-out-link expression.nix
