#!/usr/bin/env bash
# Runs the GC against a build-dir that Cargo itself wrote. The build that the last
# fresh build used stays fresh after the GC, and the units that only an older
# feature set used are reclaimed and compiled again.
set -euo pipefail

root=$PWD/gc-cargo-fixture
workspace=$root/workspace
export HOME=$root/home
export CARGO_HOME=$root/cargo-home
build_root=$HOME/.cache/dotfiles-wsl/cargo-build
export CARGO_BUILD_BUILD_DIR="$build_root/{workspace-path-hash}"
export CARGO_TERM_COLOR=never
unset CARGO_TARGET_DIR RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER CARGO_INCREMENTAL
mkdir -p "$HOME/.cache/dotfiles-wsl/sessions" "$build_root" "$workspace/app/src" "$workspace/dep/src"

cat > "$workspace/Cargo.toml" <<'TOML'
[workspace]
members = ["app", "dep"]
resolver = "2"
TOML
cat > "$workspace/dep/Cargo.toml" <<'TOML'
[package]
name = "dep"
version = "0.1.0"
edition = "2021"
build = "build.rs"

[features]
a = []
b = []
TOML
cat > "$workspace/dep/build.rs" <<'RUST'
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::write(format!("{out}/generated.rs"), "pub const GENERATED: u32 = 7;\n").unwrap();
}
RUST
cat > "$workspace/dep/src/lib.rs" <<'RUST'
include!(concat!(env!("OUT_DIR"), "/generated.rs"));

#[cfg(feature = "a")]
pub fn flavor() -> &'static str {
    "a"
}

#[cfg(not(feature = "a"))]
pub fn flavor() -> &'static str {
    "b"
}
RUST
cat > "$workspace/app/Cargo.toml" <<'TOML'
[package]
name = "app"
version = "0.1.0"
edition = "2021"

[features]
a = ["dep/a"]
b = ["dep/b"]

[dependencies]
dep = { path = "../dep" }
TOML
cat > "$workspace/app/src/main.rs" <<'RUST'
fn main() {
    println!("{} {}", dep::flavor(), dep::GENERATED);
}
RUST

compiled() {
  (cd "$workspace" && cargo build --offline -p app "$@" 2>&1) | grep -c ' Compiling ' || true
}

cargo --version
# Sources older than every output keep the build fresh after the whole tree is aged.
find "$workspace" -exec touch -h -d '50 days ago' {} +
test "$(compiled --features a)" -eq 2
entry=$(find "$build_root" -mindepth 2 -maxdepth 2 -type d)
mapfile -t feature_a_units < <(find "$entry/debug/.fingerprint" -mindepth 1 -maxdepth 1 -printf '%f\n')
test "$(compiled --features b)" -eq 2
find "$entry" "$workspace/target" -exec touch -h -d '40 days ago' {} +
# The fresh build compiles nothing, so only the atime of the hash files it reads moves.
test "$(compiled --features b)" -eq 0
locks_before=$(find "$entry" -name '.cargo*lock' -printf '%i %P\n' | sort)
test -n "$locks_before"

DOTFILES_AGENT_GC_HIGH_BYTES=1000000000000 DOTFILES_AGENT_GC_LOW_BYTES=500000000000 "$GC"

for unit in "${feature_a_units[@]}"; do
  test ! -e "$entry/debug/.fingerprint/$unit"
  if [ -n "$(find "$entry/debug/deps" "$entry/debug/build" -mindepth 1 -maxdepth 1 \
    -name "*-${unit##*-}*" -print -quit)" ]; then
    echo "GC kept an output of a reclaimed unit: $unit" >&2
    exit 1
  fi
done
test "$(find "$entry" -name '.cargo*lock' -printf '%i %P\n' | sort)" = "$locks_before"
test "$(compiled --features b)" -eq 0
test "$(compiled --features a)" -eq 2
test "$(compiled --features b)" -eq 0
