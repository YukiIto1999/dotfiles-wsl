#!/usr/bin/env bash
set -euo pipefail

: "${INSTALL_AGENTS:?}"
: "${INSTALL_AGENTS_MISSING_ARCH:?}"
: "${INSTALL_AGENTS_EMPTY_ASSET:?}"
: "${INSTALL_AGENTS_EMPTY_ENTRYPOINT:?}"
: "${INSTALL_AGENTS_SINGLE_BINARY:?}"
: "${ATOMIC_PUBLISH:?}"
: "${FIXTURE_SOURCES:?}"
: "${FIXTURE_RUNTIME_SHELL:?}"

fixture=$PWD/install-agents-behavior
asset_x86=codex-package-x86_64-unknown-linux-musl.tar.gz
asset_aarch64=codex-package-aarch64-unknown-linux-musl.tar.gz
asset_opencode=opencode-linux-x64.tar.gz
mkdir -p "$fixture"

expect_atomic_status() {
  local expected=$1
  shift

  set +e
  "$ATOMIC_PUBLISH" "$@" >"$fixture/atomic.stdout" 2>"$fixture/atomic.stderr"
  local status=$?
  set -e
  test "$status" -eq "$expected"
}

atomic_fixture=$fixture/atomic-helper
mkdir -m 0700 "$atomic_fixture"
atomic_directory_identity=$("$ATOMIC_PUBLISH" directory-identity "$atomic_fixture")
for unsafe_name in '' / . ..; do
  expect_atomic_status 2 identity "$atomic_fixture" "$atomic_directory_identity" "$unsafe_name"
done
printf -v atomic_too_long '%*s' 300 ''
atomic_too_long=${atomic_too_long// /x}
expect_atomic_status 5 identity "$atomic_fixture" "$atomic_directory_identity" "$atomic_too_long"
test "$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" missing)" = missing
ln -s first-target "$atomic_fixture/link"
first_link_identity=$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" link)
unlink "$atomic_fixture/link"
ln -s second-target "$atomic_fixture/link"
second_link_identity=$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" link)
test "$first_link_identity" != "$second_link_identity"
ln -s "$atomic_fixture" "$fixture/atomic-helper-link"
expect_atomic_status 3 directory-identity "$fixture/atomic-helper-link"
: >"$atomic_fixture/source"
: >"$atomic_fixture/destination"
atomic_source_identity=$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" source)
atomic_destination_identity=$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" destination)
expect_atomic_status 4 move-noreplace "$atomic_fixture" "$atomic_directory_identity" source \
  "$atomic_fixture" "$atomic_directory_identity" destination "$atomic_source_identity"
test "$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" source)" = "$atomic_source_identity"
test "$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" destination)" \
  = "$atomic_destination_identity"
expect_atomic_status 4 exchange "$atomic_fixture" "$atomic_directory_identity" source \
  "$atomic_fixture" "$atomic_directory_identity" destination missing "$atomic_destination_identity"
test "$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" source)" = "$atomic_source_identity"
test "$("$ATOMIC_PUBLISH" identity "$atomic_fixture" "$atomic_directory_identity" destination)" \
  = "$atomic_destination_identity"

digest_of() {
  local digest
  digest=$(sha256sum -- "$1")
  printf '%s\n' "${digest%% *}"
}

make_archive() {
  local label=$1 scenario=$2

  archive_path="$fixture/$label.tar.gz"
  python3 -B "$FIXTURE_SOURCES/make-archive.py" "$archive_path" "$scenario" \
    "$FIXTURE_RUNTIME_SHELL"
}

write_api() {
  local output=$1 asset=$2 archive=$3 mode=${4:-valid}
  local digest url repo

  digest=$(digest_of "$archive")
  repo=openai/codex
  if [[ $asset == opencode-* ]]; then
    repo=anomalyco/opencode
  fi
  url="https://github.com/$repo/releases/download/fixture-v1/$asset"

  case $mode in
    missing)
      printf '%s\n' '{"assets":[]}' >"$output"
      return
      ;;
    duplicate)
      cat >"$output" <<EOF
{"assets":[
  {"name":"$asset","browser_download_url":"$url","digest":"sha256:$digest"},
  {"name":"$asset","browser_download_url":"$url","digest":"sha256:$digest"}
]}
EOF
      return
      ;;
    missing-digest)
      printf '{"assets":[{"name":"%s","browser_download_url":"%s"}]}\n' \
        "$asset" "$url" >"$output"
      return
      ;;
    foreign-url) url="https://example.invalid/releases/$asset" ;;
    malformed-digest) digest=NOT-A-SHA256 ;;
    mismatched-digest) digest=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ;;
    valid) ;;
    *) echo "unknown API fixture mode: $mode" >&2; exit 64 ;;
  esac

  cat >"$output" <<EOF
{"assets":[{"name":"$asset","browser_download_url":"$url","digest":"sha256:$digest"}]}
EOF
}

prepare_home() {
  mkdir -p "$1/.local/bin"
}

configure_run() {
  local home=$1 archive=$2 api=$3 arch=${4:-x86_64}

  export HOME=$home
  export FIXTURE_ARCHIVE=$archive
  export FIXTURE_API_JSON=$api
  export FIXTURE_ARCH=$arch
  export FIXTURE_CURL_LOG=$home/curl.log
  export FIXTURE_TAR_LOG=$home/tar.log
  : >"$FIXTURE_CURL_LOG"
  : >"$FIXTURE_TAR_LOG"
}

configure_transaction_hook() {
  local event=$1 action=$2 label=$3

  export FIXTURE_TRANSACTION_HOOK_EVENT=$event
  export FIXTURE_TRANSACTION_HOOK_ACTION=$action
  export FIXTURE_TRANSACTION_HOOK_MARKER=$fixture/$label.hook-marker
  export FIXTURE_TRANSACTION_HOOK_SAVED=$fixture/$label.hook-saved
  export FIXTURE_TRANSACTION_HOOK_TARGET=/tmp/$label-external
  export FIXTURE_TRANSACTION_HOOK_IDENTITY=$fixture/$label.hook-identity
}

clear_transaction_hook() {
  unset FIXTURE_TRANSACTION_HOOK_EVENT FIXTURE_TRANSACTION_HOOK_ACTION
  unset FIXTURE_TRANSACTION_HOOK_MARKER FIXTURE_TRANSACTION_HOOK_SAVED
  unset FIXTURE_TRANSACTION_HOOK_TARGET FIXTURE_TRANSACTION_HOOK_IDENTITY
  unset FIXTURE_TRANSACTION_HOOK_ROOT
}

configure_atomic_hook() {
  local event=$1 action=$2 source=$3 label=$4

  export FIXTURE_ATOMIC_HOOK_EVENT=$event
  export FIXTURE_ATOMIC_HOOK_ACTION=$action
  export FIXTURE_ATOMIC_HOOK_SOURCE=$source
  export FIXTURE_ATOMIC_HOOK_MARKER=$fixture/$label.atomic-marker
  export FIXTURE_ATOMIC_HOOK_SAVED=$fixture/$label.atomic-saved
}

clear_atomic_hook() {
  unset FIXTURE_ATOMIC_HOOK_EVENT FIXTURE_ATOMIC_HOOK_ACTION FIXTURE_ATOMIC_HOOK_SOURCE
  unset FIXTURE_ATOMIC_HOOK_MARKER FIXTURE_ATOMIC_HOOK_SAVED FIXTURE_ATOMIC_HOOK_TARGET
  unset FIXTURE_ATOMIC_HOOK_ROOT FIXTURE_ATOMIC_HOOK_FAKE_EXECUTABLE
}

lstat_identity() {
  stat -c '%d:%i:%f:%u:%a' -- "$1"
}

assert_no_temps() {
  local home=$1 client=$2 binary=$3
  local root=$home/.local/share/dotfiles/agents/$client

  if [[ -d $root ]]; then
    test -z "$(find "$root" -maxdepth 1 \
      \( -name '.stage.*' -o -name '.current.next.*' -o -name '.atomic-quarantine.*' \) \
      -print -quit)"
  fi
  if [[ -d $home/.local/bin ]]; then
    test -z "$(find "$home/.local/bin" -maxdepth 1 \
      \( -name ".$binary.next.*" -o -name '.atomic-quarantine.*' \) -print -quit)"
  fi
}

state_snapshot() {
  local home=$1 client=$2 binary=$3 entrypoint=$4 output=$5
  local root=${6:-$home/.local/share/dotfiles/agents/$client}
  local current=$root/current
  local visible=$home/.local/bin/$binary path relative target entry digest

  {
    for path in "$current" "$visible"; do
      if [[ -L $path ]]; then
        printf 'path\tsymlink\t%s\t%s\n' "$(stat -c %i -- "$path")" "$(readlink -- "$path")"
      elif [[ -e $path ]]; then
        printf 'path\t%s\t%s\t%s\n' "$(stat -c %F -- "$path")" \
          "$(stat -c %i -- "$path")" "$(stat -c %a -- "$path")"
      else
        printf 'path\tmissing\n'
      fi
    done
    if [[ -L $current ]]; then
      target=$(readlink -- "$current")
      entry=$root/$target/$entrypoint
      if [[ -f $entry && ! -L $entry ]]; then
        digest=$(digest_of "$entry")
        printf 'resolved\t%s\n' "$digest"
      else
        printf 'resolved\tmissing\n'
      fi
    else
      printf 'resolved\tmissing\n'
    fi
    if [[ -d $root/releases ]]; then
      while IFS= read -r -d '' relative; do
        path=$root/releases/$relative
        if [[ -f $path && ! -L $path ]]; then
          printf 'release\tf\t%s\t%s\t%s\t%s\n' "$relative" "$(stat -c %i -- "$path")" \
            "$(stat -c %a -- "$path")" "$(digest_of "$path")"
        elif [[ -d $path && ! -L $path ]]; then
          printf 'release\td\t%s\t%s\t%s\n' "$relative" "$(stat -c %i -- "$path")" \
            "$(stat -c %a -- "$path")"
        else
          printf 'release\tspecial\t%s\n' "$relative"
        fi
      done < <(find -P "$root/releases" -mindepth 1 -printf '%P\0' | sort -z)
    fi
  } >"$output"
}

seed_stable_home() {
  local home=$1 release=sha256-0000000000000000000000000000000000000000000000000000000000000000
  local root=$home/.local/share/dotfiles/agents/codex

  prepare_home "$home"
  mkdir -p "$root/releases/$release"
  cp -a "$seed_payload/." "$root/releases/$release/"
  ln -s "releases/$release" "$root/current"
  ln -s '../share/dotfiles/agents/codex/current/bin/codex' "$home/.local/bin/codex"
}

expect_failure() {
  local label=$1 installer=$2 home=$3 archive=$4 api=$5 arch=${6:-x86_64}
  local client=${7:-codex} binary=${8:-codex} entrypoint=${9:-bin/codex}
  local before=$fixture/$label.before after=$fixture/$label.after

  configure_run "$home" "$archive" "$api" "$arch"
  state_snapshot "$home" "$client" "$binary" "$entrypoint" "$before"
  if "$installer" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
    echo "$label unexpectedly succeeded" >&2
    exit 1
  fi
  state_snapshot "$home" "$client" "$binary" "$entrypoint" "$after"
  diff --unified "$before" "$after"
  assert_no_temps "$home" "$client" "$binary"
}

assert_codex_publish() {
  local home=$1 archive=$2 digest
  digest=$(digest_of "$archive")

  test "$(readlink "$home/.local/share/dotfiles/agents/codex/current")" \
    = "releases/sha256-$digest"
  test "$(readlink "$home/.local/bin/codex")" \
    = '../share/dotfiles/agents/codex/current/bin/codex'
  test -x "$home/.local/share/dotfiles/agents/codex/current/bin/codex"
  test -x "$home/.local/share/dotfiles/agents/codex/current/bin/codex-code-mode-host"
  test ! -x "$home/.local/share/dotfiles/agents/codex/current/codex-package.json"
  test -x "$home/.local/share/dotfiles/agents/codex/current/codex-path/rg"
  test -x "$home/.local/share/dotfiles/agents/codex/current/codex-resources/bwrap"
  test -f "$home/.local/share/dotfiles/agents/codex/current/extra/allowed.txt"
  assert_no_temps "$home" codex codex
}

export FIXTURE_INHERITED_SECRET=must-not-reach-probe

make_archive seed valid
seed_archive=$archive_path
seed_payload=$fixture/seed-payload
mkdir -p "$seed_payload"
tar -xzf "$seed_archive" -C "$seed_payload"

# Both supported architecture records select the exact package asset and traverse package-tree validation.
for arch_case in x86_64 aarch64; do
  make_archive "success-$arch_case" valid
  archive=$archive_path
  if [[ $arch_case == x86_64 ]]; then
    asset=$asset_x86
  else
    asset=$asset_aarch64
  fi
  home=$fixture/success-$arch_case-home
  api=$fixture/success-$arch_case-api.json
  prepare_home "$home"
  write_api "$api" "$asset" "$archive"
  configure_run "$home" "$archive" "$api" "$arch_case"
  caller_project=$fixture/success-$arch_case-caller-project
  mkdir "$caller_project"
  (
    cd "$caller_project"
    "$INSTALL_AGENTS"
  )
  test ! -e "$caller_project/probe-relative-write"
  assert_codex_publish "$home" "$archive"
  grep -Fx "https://github.com/openai/codex/releases/download/fixture-v1/$asset" \
    "$FIXTURE_CURL_LOG"
done

# Archive metadata and canonical names must fail before extraction.
preextract_scenarios=(
  absolute parent embedded-parent empty-segment current-segment backslash control
  duplicate-file duplicate-directory
  file-directory-collision symlink-internal symlink-external hardlink-internal
  hardlink-external fifo many-members
)
for scenario in "${preextract_scenarios[@]}"; do
  label="archive-$scenario"
  make_archive "$label" "$scenario"
  archive=$archive_path
  home=$fixture/$label-home
  api=$fixture/$label-api.json
  seed_stable_home "$home"
  write_api "$api" "$asset_x86" "$archive"
  expect_failure "$label" "$INSTALL_AGENTS" "$home" "$archive" "$api"
  test ! -s "$FIXTURE_TAR_LOG"
done

# Every required path and each required kind/mode boundary is exercised after extraction.
required_paths=(
  bin/codex codex-package.json bin/codex-code-mode-host codex-path/rg codex-resources/bwrap
)
for required in "${required_paths[@]}"; do
  label="missing-${required//\//-}"
  make_archive "$label" "missing:$required"
  archive=$archive_path
  home=$fixture/$label-home
  api=$fixture/$label-api.json
  seed_stable_home "$home"
  write_api "$api" "$asset_x86" "$archive"
  expect_failure "$label" "$INSTALL_AGENTS" "$home" "$archive" "$api"
done
for scenario in wrong-kind nonexec-required exec-manifest wrapper probe-nonzero probe-timeout probe-mutate; do
  label="payload-$scenario"
  make_archive "$label" "$scenario"
  archive=$archive_path
  home=$fixture/$label-home
  api=$fixture/$label-api.json
  seed_stable_home "$home"
  write_api "$api" "$asset_x86" "$archive"
  expect_failure "$label" "$INSTALL_AGENTS" "$home" "$archive" "$api"
done

# API resolution is exact, repository-bound, and digest-authenticated.
make_archive api-valid valid
api_archive=$archive_path
for mode in missing duplicate foreign-url missing-digest malformed-digest mismatched-digest; do
  label="api-$mode"
  home=$fixture/$label-home
  api=$fixture/$label.json
  seed_stable_home "$home"
  write_api "$api" "$asset_x86" "$api_archive" "$mode"
  expect_failure "$label" "$INSTALL_AGENTS" "$home" "$api_archive" "$api"
  test ! -s "$FIXTURE_TAR_LOG"
done

# Typed contract omissions still fail before the first API request at runtime.
write_api "$fixture/fail-fast-api.json" "$asset_x86" "$api_archive"
for invalid_case in missing-arch empty-asset empty-entrypoint; do
  case $invalid_case in
    missing-arch) invalid_installer=$INSTALL_AGENTS_MISSING_ARCH ;;
    empty-asset) invalid_installer=$INSTALL_AGENTS_EMPTY_ASSET ;;
    empty-entrypoint) invalid_installer=$INSTALL_AGENTS_EMPTY_ENTRYPOINT ;;
  esac
  home=$fixture/fail-fast-$invalid_case-home
  seed_stable_home "$home"
  expect_failure "fail-fast-$invalid_case" "$invalid_installer" "$home" "$api_archive" \
    "$fixture/fail-fast-api.json"
  test ! -s "$FIXTURE_CURL_LOG"
done

# Invalid pre-existing public shapes fail without mutating current, visible, or old releases.
make_archive destination-valid valid
destination_archive=$archive_path
write_api "$fixture/destination-api.json" "$asset_x86" "$destination_archive"
for shape in current-regular current-external current-dangling current-component-symlink \
  visible-directory visible-symlink; do
  home=$fixture/$shape-home
  seed_stable_home "$home"
  case $shape in
    current-regular)
      unlink "$home/.local/share/dotfiles/agents/codex/current"
      cp "$seed_payload/bin/codex" "$home/.local/share/dotfiles/agents/codex/current"
      ;;
    current-external)
      unlink "$home/.local/share/dotfiles/agents/codex/current"
      ln -s /tmp/outside "$home/.local/share/dotfiles/agents/codex/current"
      ;;
    current-dangling)
      unlink "$home/.local/share/dotfiles/agents/codex/current"
      ln -s releases/sha256-1111111111111111111111111111111111111111111111111111111111111111 \
        "$home/.local/share/dotfiles/agents/codex/current"
      ;;
    current-component-symlink)
      current_root=$home/.local/share/dotfiles/agents/codex
      current_release=$(readlink -- "$current_root/current")
      mv "$current_root/$current_release/bin" "$current_root/$current_release/bin-real"
      ln -s bin-real "$current_root/$current_release/bin"
      ;;
    visible-directory)
      unlink "$home/.local/bin/codex"
      mkdir "$home/.local/bin/codex"
      ;;
    visible-symlink)
      unlink "$home/.local/bin/codex"
      ln -s /tmp/outside "$home/.local/bin/codex"
      ;;
  esac
  expect_failure "shape-$shape" "$INSTALL_AGENTS" "$home" "$destination_archive" \
    "$fixture/destination-api.json"
done

# A pre-existing release ID is reusable only when its complete deterministic tree matches.
destination_digest=$(digest_of "$destination_archive")
for release_shape in mismatched-directory regular symlink fifo; do
  home=$fixture/release-$release_shape-home
  seed_stable_home "$home"
  release_path=$home/.local/share/dotfiles/agents/codex/releases/sha256-$destination_digest
  case $release_shape in
    mismatched-directory)
      mkdir "$release_path"
      cp -a "$seed_payload/." "$release_path/"
      printf '%s\n' different >>"$release_path/codex-package.json"
      ;;
    regular) printf '%s\n' unexpected >"$release_path" ;;
    symlink)
      ln -s sha256-0000000000000000000000000000000000000000000000000000000000000000 \
        "$release_path"
      ;;
    fifo) mkfifo "$release_path" ;;
  esac
  expect_failure "release-$release_shape" "$INSTALL_AGENTS" "$home" "$destination_archive" \
    "$fixture/destination-api.json"
done

# A failure after publishing a release or switching current restores the exact pre-state.
for event in after-release-publish after-current-switch; do
  label=transaction-$event
  home=$fixture/$label-home
  seed_stable_home "$home"
  configure_transaction_hook "$event" fail "$label"
  expect_failure "$label" "$INSTALL_AGENTS" "$home" "$destination_archive" \
    "$fixture/destination-api.json"
  test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
  clear_transaction_hook
done

# Rollback and cleanup stay on the locked client tree after its public path is replaced.
label=transaction-client-root-after-release
home=$fixture/$label-home
seed_stable_home "$home"
client_root=$home/.local/share/dotfiles/agents/codex
client_root_identity_before=$(lstat_identity "$client_root")
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
state_snapshot "$home" codex codex bin/codex "$fixture/$label.before"
configure_transaction_hook after-release-publish replace-client-root-fail "$label"
export FIXTURE_TRANSACTION_HOOK_ROOT=$client_root
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
test -f "$client_root/external-marker"
test "$(<"$client_root/external-marker")" = external
test ! -e "$client_root/current"
test -z "$(find "$client_root/releases" -mindepth 1 -print -quit)"
test "$(lstat_identity "$FIXTURE_TRANSACTION_HOOK_SAVED")" = "$client_root_identity_before"
state_snapshot "$home" codex codex bin/codex "$fixture/$label.after" \
  "$FIXTURE_TRANSACTION_HOOK_SAVED"
diff --unified "$fixture/$label.before" "$fixture/$label.after"
test -z "$(find "$FIXTURE_TRANSACTION_HOOK_SAVED" -maxdepth 1 \
  \( -name '.stage.*' -o -name '.current.next.*' -o -name '.atomic-quarantine.*' \) \
  -print -quit)"
clear_transaction_hook

label=transaction-after-visible-switch
home=$fixture/$label-home
prepare_home "$home"
install -m 0755 "$seed_payload/bin/codex" "$home/.local/bin/codex"
configure_transaction_hook after-visible-switch fail "$label"
expect_failure "$label" "$INSTALL_AGENTS" "$home" "$destination_archive" \
  "$fixture/destination-api.json"
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
clear_transaction_hook

# If a just-published release is mutated, rollback refuses deletion and preserves evidence.
label=transaction-mutated-release
home=$fixture/$label-home
seed_stable_home "$home"
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
configure_transaction_hook after-release-publish mutate-fail "$label"
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
mutated_release=$home/.local/share/dotfiles/agents/codex/releases/sha256-$destination_digest
grep -Fxq changed-during-rollback "$mutated_release/codex-package.json"
grep -Fq 'published release changed during rollback; preserving transaction state' \
  "$fixture/$label.stderr"
test -n "$(find "$home/.local/share/dotfiles/agents/codex" -maxdepth 1 \
  -name '.stage.*' -type d -print -quit)"
clear_transaction_hook

# A current replacement after precheck is preserved instead of being clobbered.
label=transaction-current-race
home=$fixture/$label-home
seed_stable_home "$home"
state_snapshot "$home" codex codex bin/codex "$fixture/$label.before"
visible_inode_before=$(stat -c %i -- "$home/.local/bin/codex")
visible_target_before=$(readlink -- "$home/.local/bin/codex")
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
configure_transaction_hook before-current-switch replace "$label"
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
test "$(lstat_identity "$home/.local/share/dotfiles/agents/codex/current")" \
  = "$(<"$FIXTURE_TRANSACTION_HOOK_IDENTITY")"
test "$(readlink -- "$home/.local/share/dotfiles/agents/codex/current")" \
  = "$FIXTURE_TRANSACTION_HOOK_TARGET"
state_snapshot "$home" codex codex bin/codex "$fixture/$label.after"
diff --unified \
  <(grep '^release' "$fixture/$label.before") \
  <(grep '^release' "$fixture/$label.after")
test "$(stat -c %i -- "$home/.local/bin/codex")" = "$visible_inode_before"
test "$(readlink -- "$home/.local/bin/codex")" = "$visible_target_before"
assert_no_temps "$home" codex codex
clear_transaction_hook

# A visible replacement after precheck is preserved while current and release roll back.
label=transaction-visible-race
home=$fixture/$label-home
prepare_home "$home"
install -m 0755 "$seed_payload/bin/codex" "$home/.local/bin/codex"
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
configure_transaction_hook before-visible-switch replace "$label"
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
test "$(lstat_identity "$home/.local/bin/codex")" \
  = "$(<"$FIXTURE_TRANSACTION_HOOK_IDENTITY")"
test "$(readlink -- "$home/.local/bin/codex")" = "$FIXTURE_TRANSACTION_HOOK_TARGET"
test ! -e "$home/.local/share/dotfiles/agents/codex/current"
test -z "$(find "$home/.local/share/dotfiles/agents/codex/releases" -mindepth 1 -print -quit)"
assert_no_temps "$home" codex codex
clear_transaction_hook

# Adding a hardlink after legacy validation changes its CAS identity and aborts migration.
label=transaction-visible-nlink-race
home=$fixture/$label-home
prepare_home "$home"
install -m 0755 "$seed_payload/bin/codex" "$home/.local/bin/codex"
legacy_inode=$(stat -c %i -- "$home/.local/bin/codex")
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
configure_transaction_hook before-visible-switch hardlink "$label"
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_TRANSACTION_HOOK_MARKER"
test "$(stat -c %i -- "$home/.local/bin/codex")" = "$legacy_inode"
test "$(stat -c %h -- "$home/.local/bin/codex")" -eq 2
test "$(stat -c %i -- "$FIXTURE_TRANSACTION_HOOK_SAVED")" = "$legacy_inode"
test ! -e "$home/.local/share/dotfiles/agents/codex/current"
test -z "$(find "$home/.local/share/dotfiles/agents/codex/releases" -mindepth 1 -print -quit)"
assert_no_temps "$home" codex codex
clear_transaction_hook

# Replacing client_root after the helper opens the locked directory never publishes into the new tree.
label=transaction-client-root-race
home=$fixture/$label-home
prepare_home "$home"
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
client_root=$home/.local/share/dotfiles/agents/codex
configure_atomic_hook after-open-directories replace-directory "$client_root" "$label"
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
test -d "$client_root"
test ! -e "$client_root/current"
test ! -L "$client_root/current"
test ! -e "$home/.local/bin/codex"
test ! -L "$home/.local/bin/codex"
test -d "$FIXTURE_ATOMIC_HOOK_SAVED"
test ! -e "$FIXTURE_ATOMIC_HOOK_SAVED/current"
test ! -L "$FIXTURE_ATOMIC_HOOK_SAVED/current"
clear_atomic_hook

# Probe execution uses the validated staged object even if the public root is replaced afterward.
label=probe-client-root-race
home=$fixture/$label-home
prepare_home "$home"
configure_run "$home" "$destination_archive" "$fixture/destination-api.json"
client_root=$home/.local/share/dotfiles/agents/codex
fake_probe_marker=$fixture/$label.fake-executed
fake_probe=$fixture/$label.fake-entrypoint
cat >"$fake_probe" <<EOF
#!$FIXTURE_RUNTIME_SHELL
: >'$fake_probe_marker'
printf '%s\n' 'fake probe executed'
EOF
chmod 0755 "$fake_probe"
configure_atomic_hook before-probe-exec replace-probe-stage "" "$label"
export FIXTURE_ATOMIC_HOOK_ROOT=$client_root
export FIXTURE_ATOMIC_HOOK_FAKE_EXECUTABLE=$fake_probe
if "$INSTALL_AGENTS" >"$fixture/$label.stdout" 2>"$fixture/$label.stderr"; then
  echo "$label unexpectedly succeeded" >&2
  exit 1
fi
test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
if [[ -e $fake_probe_marker ]]; then
  echo 'probe race executed the unvalidated replacement entrypoint' >&2
  exit 1
fi
grep -Fq 'public client root changed during publish for codex' "$fixture/$label.stderr"
test ! -e "$home/.local/bin/codex"
test ! -L "$home/.local/bin/codex"
test -d "$FIXTURE_ATOMIC_HOOK_SAVED"
test ! -e "$FIXTURE_ATOMIC_HOOK_SAVED/current"
test -z "$(find "$FIXTURE_ATOMIC_HOOK_SAVED/releases" -mindepth 1 -print -quit)"
test -z "$(find "$FIXTURE_ATOMIC_HOOK_SAVED" -maxdepth 1 \
  \( -name '.stage.*' -o -name '.current.next.*' -o -name '.atomic-quarantine.*' \) \
  -print -quit)"
mapfile -t fake_stages < <(find "$client_root" -mindepth 1 -maxdepth 1 -type d \
  -name '.stage.*' -print)
test "${#fake_stages[@]}" -eq 1
cmp -- "$fake_probe" "${fake_stages[0]}/payload/bin/codex"
test -z "$(find "$client_root/releases" -mindepth 1 -print -quit)"
test -z "$(find "$client_root" -maxdepth 1 \
  \( -name '.current.next.*' -o -name '.atomic-quarantine.*' \) -print -quit)"
clear_atomic_hook

# HOME and every managed component below it must be owned real directories.
component_home=$fixture/component-symlink-home
prepare_home "$component_home"
mkdir "$fixture/component-symlink-target"
ln -s "$fixture/component-symlink-target" "$component_home/.local/share"
expect_failure component-symlink "$INSTALL_AGENTS" "$component_home" "$destination_archive" \
  "$fixture/destination-api.json"
test ! -s "$FIXTURE_CURL_LOG"

export HOME=relative-home
export FIXTURE_ARCHIVE=$destination_archive
export FIXTURE_API_JSON=$fixture/destination-api.json
export FIXTURE_ARCH=x86_64
export FIXTURE_CURL_LOG=$fixture/relative-home-curl.log
export FIXTURE_TAR_LOG=$fixture/relative-home-tar.log
: >"$FIXTURE_CURL_LOG"
: >"$FIXTURE_TAR_LOG"
if "$INSTALL_AGENTS" >"$fixture/relative-home.stdout" 2>"$fixture/relative-home.stderr"; then
  echo "relative HOME unexpectedly succeeded" >&2
  exit 1
fi
test ! -s "$FIXTURE_CURL_LOG"

# An owned executable legacy codex is migrated on the initial publish.
legacy_home=$fixture/legacy-home
prepare_home "$legacy_home"
install -m 0755 "$seed_payload/bin/codex" "$legacy_home/.local/bin/codex"
configure_run "$legacy_home" "$destination_archive" "$fixture/destination-api.json"
"$INSTALL_AGENTS"
assert_codex_publish "$legacy_home" "$destination_archive"

# A commit-cleanup CAS conflict is a failed install and preserves both unknown identities.
cleanup_conflict_home=$fixture/cleanup-conflict-home
prepare_home "$cleanup_conflict_home"
install -m 0755 "$seed_payload/bin/codex" "$cleanup_conflict_home/.local/bin/codex"
configure_run "$cleanup_conflict_home" "$destination_archive" \
  "$fixture/destination-api.json"
configure_atomic_hook before-quarantine-move replace-object \
  "$cleanup_conflict_home/.local/bin" cleanup-conflict
export FIXTURE_ATOMIC_HOOK_TARGET=/tmp/cleanup-conflict-external
if "$INSTALL_AGENTS" >"$fixture/cleanup-conflict.stdout" \
  2>"$fixture/cleanup-conflict.stderr"; then
  echo 'commit cleanup conflict unexpectedly succeeded' >&2
  exit 1
fi
test -e "$FIXTURE_ATOMIC_HOOK_MARKER"
test -f "$FIXTURE_ATOMIC_HOOK_SAVED"
test ! -L "$FIXTURE_ATOMIC_HOOK_SAVED"
mapfile -t cleanup_conflict_temps < <(
  find "$cleanup_conflict_home/.local/bin" -maxdepth 1 -name '.codex.next.*' -print
)
test "${#cleanup_conflict_temps[@]}" -eq 1
test "$(readlink -- "${cleanup_conflict_temps[0]}")" = "$FIXTURE_ATOMIC_HOOK_TARGET"
test "$(readlink -- "$cleanup_conflict_home/.local/bin/codex")" \
  = '../share/dotfiles/agents/codex/current/bin/codex'
grep -Fq 'cannot clean committed publish transaction for codex' \
  "$fixture/cleanup-conflict.stderr"
clear_atomic_hook

# Legacy cleanup quarantines within the visible source filesystem.
unshare --user --map-current-user --keep-caps --mount \
  "$FIXTURE_RUNTIME_SHELL" "$FIXTURE_SOURCES/cross-device.sh" \
  "$fixture/cross-device-home" "$destination_archive" \
  "$fixture/destination-api.json" "$seed_payload/bin/codex"

# If current was published before a visible legacy rename, rerunning completes the migration.
recovery_home=$fixture/legacy-recovery-home
seed_stable_home "$recovery_home"
unlink "$recovery_home/.local/bin/codex"
cp "$seed_payload/bin/codex" "$recovery_home/.local/bin/codex"
chmod 0755 "$recovery_home/.local/bin/codex"
configure_run "$recovery_home" "$destination_archive" "$fixture/destination-api.json"
"$INSTALL_AGENTS"
assert_codex_publish "$recovery_home" "$destination_archive"

# Updating an old current leaves the stable visible symlink inode and target unchanged.
update_home=$fixture/update-home
seed_stable_home "$update_home"
visible_inode_before=$(stat -c %i -- "$update_home/.local/bin/codex")
visible_target_before=$(readlink -- "$update_home/.local/bin/codex")
configure_run "$update_home" "$destination_archive" "$fixture/destination-api.json"
"$INSTALL_AGENTS"
assert_codex_publish "$update_home" "$destination_archive"
test "$(stat -c %i -- "$update_home/.local/bin/codex")" = "$visible_inode_before"
test "$(readlink -- "$update_home/.local/bin/codex")" = "$visible_target_before"

# Reinstalling the same archive preserves release/current/visible inode, target, and content digest.
idempotent_home=$fixture/idempotent-home
prepare_home "$idempotent_home"
configure_run "$idempotent_home" "$destination_archive" "$fixture/destination-api.json"
"$INSTALL_AGENTS"
state_snapshot "$idempotent_home" codex codex bin/codex "$fixture/idempotent-before"
configure_run "$idempotent_home" "$destination_archive" "$fixture/destination-api.json"
"$INSTALL_AGENTS"
state_snapshot "$idempotent_home" codex codex bin/codex "$fixture/idempotent-after"
diff --unified "$fixture/idempotent-before" "$fixture/idempotent-after"
assert_no_temps "$idempotent_home" codex codex

# Extraction modes are deterministic even when the invoking user's umask changes.
umask_home=$fixture/umask-home
prepare_home "$umask_home"
configure_run "$umask_home" "$destination_archive" "$fixture/destination-api.json"
(umask 077; "$INSTALL_AGENTS")
state_snapshot "$umask_home" codex codex bin/codex "$fixture/umask-before"
configure_run "$umask_home" "$destination_archive" "$fixture/destination-api.json"
(umask 022; "$INSTALL_AGENTS")
state_snapshot "$umask_home" codex codex bin/codex "$fixture/umask-after"
diff --unified "$fixture/umask-before" "$fixture/umask-after"
assert_no_temps "$umask_home" codex codex

# Two updaters serialize on the client-root descriptor lock and leave no temporary names.
concurrent_home=$fixture/concurrent-home
prepare_home "$concurrent_home"
configure_run "$concurrent_home" "$destination_archive" "$fixture/destination-api.json"
export FIXTURE_CURL_DELAY=0.1
"$INSTALL_AGENTS" >"$fixture/concurrent-1.stdout" 2>"$fixture/concurrent-1.stderr" &
pid_one=$!
"$INSTALL_AGENTS" >"$fixture/concurrent-2.stdout" 2>"$fixture/concurrent-2.stderr" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
unset FIXTURE_CURL_DELAY
assert_codex_publish "$concurrent_home" "$destination_archive"
mapfile -t concurrent_urls <"$FIXTURE_CURL_LOG"
test "${#concurrent_urls[@]}" -eq 4
test "${concurrent_urls[0]}" = 'https://api.github.com/repos/openai/codex/releases/latest'
test "${concurrent_urls[1]}" = "https://github.com/openai/codex/releases/download/fixture-v1/$asset_x86"
test "${concurrent_urls[2]}" = 'https://api.github.com/repos/openai/codex/releases/latest'
test "${concurrent_urls[3]}" = "https://github.com/openai/codex/releases/download/fixture-v1/$asset_x86"
mapfile -d '' -t concurrent_releases < <(
  find -P "$concurrent_home/.local/share/dotfiles/agents/codex/releases" \
    -mindepth 1 -maxdepth 1 -print0
)
test "${#concurrent_releases[@]}" -eq 1
test -d "${concurrent_releases[0]}"
test ! -L "${concurrent_releases[0]}"
test "${concurrent_releases[0]##*/}" = "sha256-$(digest_of "$destination_archive")"

# The other supported GitHub layout continues through the single-binary publisher.
make_archive opencode single-binary
opencode_archive=$archive_path
mapfile -t opencode_members < <(tar -tzf "$opencode_archive")
test "${#opencode_members[@]}" -eq 1
test "${opencode_members[0]}" = opencode
for mode in missing-digest malformed-digest mismatched-digest; do
  label=opencode-api-$mode
  home=$fixture/$label-home
  api=$fixture/$label.json
  prepare_home "$home"
  write_api "$api" "$asset_opencode" "$opencode_archive" "$mode"
  expect_failure "$label" "$INSTALL_AGENTS_SINGLE_BINARY" "$home" "$opencode_archive" \
    "$api" x86_64 opencode opencode opencode
done
opencode_home=$fixture/opencode-home
opencode_api=$fixture/opencode-api.json
prepare_home "$opencode_home"
write_api "$opencode_api" "$asset_opencode" "$opencode_archive"
configure_run "$opencode_home" "$opencode_archive" "$opencode_api"
"$INSTALL_AGENTS_SINGLE_BINARY"
opencode_digest=$(digest_of "$opencode_archive")
test "$(readlink "$opencode_home/.local/share/dotfiles/agents/opencode/current")" \
  = "releases/sha256-$opencode_digest"
test "$(readlink "$opencode_home/.local/bin/opencode")" \
  = '../share/dotfiles/agents/opencode/current/opencode'
"$opencode_home/.local/bin/opencode" --version | grep -Fx 'codex fixture 1.0.0'
assert_no_temps "$opencode_home" opencode opencode
