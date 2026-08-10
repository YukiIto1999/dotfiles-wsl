set -euo pipefail

die() {
  printf 'dotfiles-migrate-codex-config: %s\n' "$1" >&2
  exit 70
}

if [ "$#" -ne 2 ]; then
  die 'usage: dotfiles-migrate-codex-config TARGET HOME_DIR'
fi

target=$1
home_dir=$2
target_dir=${target%/*}
current_uid=$(@idCommand@ -u) || die 'cannot determine the current user'

validated_identity=
validate_directory() {
  local path=$1 expected_identity=${2-} owner
  test ! -L "$path" || die "target directory is a symlink: $path"
  test -d "$path" || die "target directory is not a directory: $path"
  validated_identity=$(@statCommand@ -c '%u:%d:%i' -- "$path") \
    || die "cannot inspect target directory: $path"
  owner=${validated_identity%%:*}
  test "$owner" = "$current_uid" || die "target directory has another owner: $path"
  test ! -L "$path" && test -d "$path" \
    || die "target directory changed while being inspected: $path"
  if [ -n "$expected_identity" ]; then
    test "$validated_identity" = "$expected_identity" \
      || die "target directory identity changed: $path"
  fi
}

validate_target() {
  local path=$1 expected_identity=${2-} owner
  test ! -L "$path" || die "target is a symlink: $path"
  test -f "$path" || die "target is not a regular file: $path"
  validated_identity=$(@statCommand@ -c '%u:%d:%i' -- "$path") \
    || die "cannot inspect target: $path"
  owner=${validated_identity%%:*}
  test "$owner" = "$current_uid" || die "target has another owner: $path"
  test ! -L "$path" && test -f "$path" \
    || die "target changed while being inspected: $path"
  if [ -n "$expected_identity" ]; then
    test "$validated_identity" = "$expected_identity" \
      || die "target identity changed: $path"
  fi
}

validate_directory "$target_dir"
target_dir_identity=$validated_identity
test ! -L "$target" || die "target is a symlink: $target"
if [ ! -e "$target" ]; then
  exit 0
fi
validate_target "$target"
target_identity=$validated_identity

json_tmp=
toml_tmp=

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$json_tmp" ]; then
    @rmCommand@ -f -- "$json_tmp" || true
  fi
  if [ -n "$toml_tmp" ]; then
    @rmCommand@ -f -- "$toml_tmp" || true
  fi
  exit "$status"
}
trap cleanup EXIT

json_tmp=$(@mktempCommand@ "$target_dir/.codex-migration-json.XXXXXXXX") \
  || die "cannot create migration input: $target_dir"
toml_tmp=$(@mktempCommand@ "$target_dir/.codex-migration-toml.XXXXXXXX") \
  || die "cannot create migration output: $target_dir"

@remarshalCommand@ -if toml -of json "$target" > "$json_tmp" \
  || die "target is not valid TOML: $target"

if ! @jqCommand@ --exit-status \
  'has("sandbox_mode") or has("sandbox_workspace_write")' "$json_tmp" >/dev/null; then
  exit 0
fi

@jqCommand@ --arg homeDir "$home_dir" '
  del(.sandbox_mode, .sandbox_workspace_write)
  | .default_permissions = "dev"
  | .permissions = (.permissions // {})
  | .permissions.dev = (.permissions.dev // {})
  | .permissions.dev.description = "workspace general profile"
  | .permissions.dev.extends = ":workspace"
  | (.permissions.dev.filesystem // {}) as $filesystem
  | .permissions.dev.filesystem = ($filesystem + {
      ":workspace_roots": (($filesystem[":workspace_roots"] // {}) + {
        ".": "write",
        ".git": "write"
      }),
      ($homeDir + "/workspace"): "write",
      ($homeDir + "/projects"): "write"
    })
  | .permissions.dev.network = ((.permissions.dev.network // {}) + {enabled: true})
' "$json_tmp" | @remarshalCommand@ -if json -of toml > "$toml_tmp" \
  || die "cannot render migrated config: $target"

@remarshalCommand@ -if toml -of json "$toml_tmp" \
  | @jqCommand@ --exit-status '
      .default_permissions == "dev" and
      (has("sandbox_mode") | not) and
      (has("sandbox_workspace_write") | not)
  ' >/dev/null \
  || die "migrated config failed validation: $target"

@chmodCommand@ 600 "$toml_tmp" || die "cannot secure migrated config: $target"
validate_directory "$target_dir" "$target_dir_identity"
validate_target "$target" "$target_identity"
@mvCommand@ -T "$toml_tmp" "$target" || die "cannot publish migrated config: $target"
toml_tmp=
@rmCommand@ -f -- "$json_tmp"
json_tmp=
trap - EXIT
