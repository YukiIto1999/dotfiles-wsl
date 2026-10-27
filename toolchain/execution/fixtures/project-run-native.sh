#!/usr/bin/env bash
set -euo pipefail

native=$(realpath .)/project-run-native
project=$native/project
dependency=$native/dependency
extra=$native/extra
client=$native/client
mkdir -p "$project" "$dependency" "$extra" "$native"/{home,etc,store,state,log}
: > "$project/.envrc"
printf 'locked-input-value' > "$dependency/value"
printf 'unlocked-input-value' > "$extra/value"

cat > "$client" <<SCRIPT
#!$BASH
printf '%s\n' "\${PROJECT_RUN_SHELL-unset}" "\${PROJECT_RUN_LOCKED-unset}" > "$native/client.result"
SCRIPT
chmod +x "$client"

jq -n --arg path "$project/.envrc" \
  '{config: {}, state: {loadedRC: null, foundRC: {allowed: 0, path: $path}}}' \
  > "$native/direnv.json"

# global registry の取得が network を要するため既定の flake-registry は不可
nix_config=$'experimental-features = nix-command flakes\nsandbox = false\nbuild-users-group =\nsubstituters =\nflake-registry ='

# build sandbox の中は namespace を作れないため root 指定の store は不可
entry() {
  (
    cd "$project"
    exec env HOME="$native/home" NIX_REMOTE=local NIX_STORE_DIR="$native/store" \
      NIX_STATE_DIR="$native/state" NIX_LOG_DIR="$native/log" NIX_CONF_DIR="$native/etc" \
      NIX_CONFIG="$nix_config" FAKE_DIRENV_JSON="$native/direnv.json" "$@"
  )
}

write_flake() {
  local extra_inputs=$1
  cat > "$project/flake.nix" <<NIX
{
  inputs.dependency = {
    url = "path:$dependency";
    flake = false;
  };
  $extra_inputs
  outputs = { dependency, ... }:
    let
      devShell = name: derivation {
        inherit name;
        system = "$SYSTEM";
        builder = "$BASH";
        outputs = [ "out" ];
        PROJECT_RUN_SHELL = name;
        PROJECT_RUN_LOCKED = builtins.readFile (dependency + "/value");
      };
    in
    {
      devShells."$SYSTEM" = {
        default = devShell "default";
        named = devShell "named";
      };
    };
}
NIX
}

expect_lock_unchanged() {
  [[ $(sha256sum < "$project/flake.lock") == "$lock_digest" ]] || {
    echo "$1: flake.lock changed" >&2
    exit 1
  }
}

expect_shell() {
  local shell=$1 seen
  shift
  rm -f "$native/client.result"
  entry "$PROJECT_RUN" "$@" -- "$client"
  mapfile -t seen < "$native/client.result"
  [[ ${#seen[@]} -eq 2 && ${seen[0]} == "$shell" && ${seen[1]} == locked-input-value ]] || {
    echo "devShell $shell: the client saw ${seen[*]}" >&2
    exit 1
  }
  expect_lock_unchanged "devShell $shell"
}

expect_refused() {
  local description=$1 status=0
  shift
  rm -f "$native/client.result"
  entry "$PROJECT_RUN" "$@" -- "$client" > /dev/null 2> "$native/refusal.stderr" || status=$?
  [[ $status -ne 0 ]] || {
    echo "$description: the entry succeeded" >&2
    cat "$native/refusal.stderr" >&2
    exit 1
  }
  [[ ! -e "$native/client.result" ]] || {
    echo "$description: the client started" >&2
    cat "$native/refusal.stderr" >&2
    exit 1
  }
  expect_lock_unchanged "$description"
}

write_flake ''
entry nix flake lock "$project"
lock_digest=$(sha256sum < "$project/flake.lock")

expect_shell default
expect_shell named --attr named
expect_refused 'missing devShell' --attr missing

# 拒否の理由を lock の古さだけに絞るため shell の定義も変える入力の追加は不可
write_flake "inputs.extra = { url = \"path:$extra\"; flake = false; };"
expect_refused 'a lock that needs an update'
write_flake ''
expect_shell default
