install_manifest=$(cat <<'DOTFILES_INSTALL_MANIFEST'
@installManifest@
DOTFILES_INSTALL_MANIFEST
)

if [[ ${1:-} == "--print-manifest" ]]; then
  printf '%s\n' "$install_manifest"
  exit 0
fi

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  cat <<'USAGE'
usage: dotfiles-install-agents

Installs the agent client binaries declared in dotfiles.agents (upstream installer
script or GitHub release archive, depending on each client's install.kind) into
~/.local/bin. Run as the target user, not root.
USAGE
  exit 0
fi

fail() { echo "FATAL: $*" >&2; exit 1; }
log()  { printf '== %s\n' "$*"; }

atomic_publish_command=@atomicPublishCommand@
transaction_hook_command=@transactionHookCommand@

[[ ${EUID} -ne 0 ]] || fail "run as the target user, not root"
[[ ${HOME:-} == /* ]] || fail "HOME must be an absolute path"

current_uid=$(id -u)
archive_member_limit=4096
archive_logical_size_limit=2147483648
curl_connect_timeout_seconds=10
curl_max_time_seconds=120
curl_max_redirects=5
probe_timeout_seconds=10
probe_kill_grace_seconds=2
temp_symlink_attempt_limit=32
active_stage=
active_stage_public=
active_current_next=
active_current_next_identity=
active_visible_next=
active_visible_next_identity=
client_root=
client_root_identity=
releases_root_identity=
visible_parent_identity=
active_stage_identity=
active_stage_fd=
active_stage_view=
active_stage_name=
client_root_fd=
client_root_view=
releases_root_fd=
releases_root_view=
visible_parent_fd=
visible_parent_view=
transaction_active=0
transaction_rollback_ambiguous=0
transaction_release_state=none
transaction_current_state=none
transaction_visible_state=none
transaction_release_name=
transaction_release_identity=
transaction_release_record=
transaction_release_manifest=
transaction_release_scratch=
transaction_release_payload=
transaction_current_method=
transaction_current_old_identity=
transaction_current_new_identity=
transaction_visible_method=
transaction_visible_old_identity=
transaction_visible_new_identity=
transaction_visible_binary=

atomic_identity() {
  "$atomic_publish_command" identity "$1" "$2" "$3"
}

atomic_identity_fd() {
  "$atomic_publish_command" identity-fd "$1" "$2" "$3"
}

atomic_directory_identity() {
  "$atomic_publish_command" directory-identity "$1"
}

atomic_directory_identity_fd() {
  "$atomic_publish_command" directory-identity-fd "$1"
}

atomic_operation() {
  local status

  if "$atomic_publish_command" "$@"; then
    return 0
  else
    status=$?
  fi
  ((status == 6)) && transaction_rollback_ambiguous=1
  return "$status"
}

run_transaction_hook() {
  local event=$1 public_path=${2:-}

  "$transaction_hook_command" "$event" "$public_path" \
    || fail "transaction hook failed at $event"
}

cleanup_expected_temp() {
  local directory_fd=$1 directory_identity=$2 path=$3 identity=$4 label=$5

  [[ -n $path ]] || return 0
  if "$atomic_publish_command" unlink-if-fd "$directory_fd" "$directory_identity" \
    "${path##*/}" "$identity"; then
    return 0
  fi
  echo "FATAL: preserving unexpected $label temporary object: $path" >&2
  return 1
}

cleanup_install_temps() {
  local status=$? rollback_status=0 cleanup_status=0
  trap - EXIT
  set +e
  if ((transaction_active && !transaction_rollback_ambiguous)); then
    rollback_publish_transaction
    rollback_status=$?
    if ((rollback_status != 0)); then
      transaction_rollback_ambiguous=1
      status=1
    fi
  fi
  if ((transaction_rollback_ambiguous)); then
    echo "FATAL: publish rollback is ambiguous; preserving transaction state" >&2
    exit 1
  fi
  cleanup_expected_temp "$client_root_fd" "$client_root_identity" "$active_current_next" \
    "$active_current_next_identity" "current" || cleanup_status=1
  cleanup_expected_temp "$visible_parent_fd" "$visible_parent_identity" "$active_visible_next" \
    "$active_visible_next_identity" "visible" || cleanup_status=1
  if [[ -n $active_stage_fd ]]; then
    if ! "$atomic_publish_command" remove-tree-fd "$client_root_fd" "$client_root_identity" \
      "$active_stage_name" "$active_stage_fd" "$active_stage_identity"; then
      echo "FATAL: preserving ambiguous stage directory: $active_stage" >&2
      cleanup_status=1
    fi
  fi
  ((cleanup_status == 0)) || status=1
  exit "$status"
}
trap cleanup_install_temps EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found in PATH"
}

for command in awk bash chmod cmp curl env find flock gzip id install jq ln mkdir mktemp mv readlink rm sha256sum sort stat tar timeout uname wc; do
  require "$command"
done
[[ -f $atomic_publish_command && -x $atomic_publish_command ]] \
  || fail "atomic publish helper is unavailable: $atomic_publish_command"

@versionArgsDecoder@

owned_real_directory() {
  local path=$1 label=$2 owner mode

  [[ -d $path && ! -L $path ]] || fail "$label must be a real directory: $path"
  owner=$(stat -c %u -- "$path") || fail "cannot read owner for $label: $path"
  [[ $owner == "$current_uid" ]] || fail "$label has a foreign owner: $path"
  mode=$(stat -c %a -- "$path") || fail "cannot read mode for $label: $path"
  [[ $mode =~ ^[0-7]{3,4}$ ]] || fail "invalid mode for $label: $path"
  (( (8#$mode & 0022) == 0 )) || fail "$label is group/other writable: $path"
}

ensure_owned_directory() {
  local path=$1 mode=$2 label=$3

  if [[ -e $path || -L $path ]]; then
    owned_real_directory "$path" "$label"
    return
  fi
  if ! mkdir -m "$mode" -- "$path" 2>/dev/null; then
    [[ -e $path || -L $path ]] || fail "cannot create $label: $path"
  fi
  owned_real_directory "$path" "$label"
}

prepare_visible_parent() {
  owned_real_directory "$HOME" "HOME"
  ensure_owned_directory "$HOME/.local" 0755 "managed directory"
  ensure_owned_directory "$HOME/.local/bin" 0755 "visible binary parent"
}

prepare_client_root() {
  local name=$1

  [[ $name =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe client name: $name"
  prepare_visible_parent
  ensure_owned_directory "$HOME/.local/share" 0755 "managed directory"
  ensure_owned_directory "$HOME/.local/share/dotfiles" 0755 "managed directory"
  ensure_owned_directory "$HOME/.local/share/dotfiles/agents" 0755 "managed directory"
  client_root="$HOME/.local/share/dotfiles/agents/$name"
  releases_root="$client_root/releases"
  ensure_owned_directory "$client_root" 0700 "client root"
  ensure_owned_directory "$releases_root" 0700 "release directory"
}

arch_key() {
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "x86_64" ;;
    aarch64|arm64) printf '%s\n' "aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

curl_https() {
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout "$curl_connect_timeout_seconds" \
    --max-time "$curl_max_time_seconds" \
    --max-redirs "$curl_max_redirects" \
    "$@"
}

check_version() {
  local binary=$1 version_args_json=$2

  run_version_check "$binary" "$version_args_json" \
    || fail "$binary installed but version check failed"
}

install_installer_script() {
  local record=$1 bash_command binary installed_binary url version_args_json

  binary=$(jq -e -r '.binary | select(type == "string" and length > 0)' <<<"$record") \
    || fail "installer-script binary is missing"
  url=$(jq -e -r '.install.scriptUrl | select(type == "string" and startswith("https://"))' <<<"$record") \
    || fail "installer-script URL must use HTTPS"
  version_args_json=$(jq -e -c '.versionArgs | select(type == "array" and length > 0)' <<<"$record") \
    || fail "installer-script version arguments are missing"

  prepare_visible_parent
  bash_command=$(command -v bash)

  log "$binary"
  curl_https "$url" | env PATH="$HOME/.local/bin:$PATH" "$bash_command"

  installed_binary="$HOME/.local/bin/$binary"
  [[ -x $installed_binary ]] \
    || fail "$binary not found after upstream installer; ensure ~/.local/bin is in PATH"
  check_version "$installed_binary" "$version_args_json"
}

resolve_github_release() {
  local record=$1 arch api api_json asset_record

  arch=$(arch_key)
  resolved_release=$(jq -e -c --arg arch "$arch" \
    '.install.releaseByArch[$arch] | select(type == "object")' <<<"$record") \
    || fail "release record missing for architecture: $arch"
  resolved_asset=$(jq -e -r '.asset | select(type == "string" and length > 0)' \
    <<<"$resolved_release") || fail "release asset is empty for architecture: $arch"
  resolved_entrypoint=$(jq -e -r '.entrypoint | select(type == "string" and length > 0)' \
    <<<"$resolved_release") || fail "release entrypoint is empty for architecture: $arch"
  canonical_member_name "$resolved_entrypoint" >/dev/null \
    || fail "release entrypoint is unsafe for architecture: $arch"

  api="https://api.github.com/repos/${resolved_repo}/releases/latest"
  api_json="$active_stage/release.json"
  curl_https --output "$api_json" "$api"
  asset_record=$(jq -e -c --arg asset "$resolved_asset" '
    [.assets[]? | select(.name == $asset)]
    | if length == 1 then .[0] else error("asset match count must be one") end
  ' "$api_json") || fail "release asset must match exactly once: $resolved_asset"
  resolved_url=$(jq -e -r \
    '.browser_download_url | select(type == "string" and length > 0)' <<<"$asset_record") \
    || fail "release asset URL is missing: $resolved_asset"
  [[ $resolved_url == "https://github.com/${resolved_repo}/releases/download/"* ]] \
    || fail "release asset URL is outside the expected GitHub repository: $resolved_url"
  resolved_api_digest=$(jq -r '.digest // ""' <<<"$asset_record")
}

canonical_member_name() {
  local name=$1 canonical segment
  local -a segments

  [[ -n $name && $name != /* && $name != *\\* ]] || return 1
  canonical=${name%/}
  [[ -n $canonical ]] || return 1
  [[ $canonical =~ ^[A-Za-z0-9._+@%=-]+(/[A-Za-z0-9._+@%=-]+)*$ ]] || return 1
  IFS=/ read -r -a segments <<<"$canonical"
  for segment in "${segments[@]}"; do
    [[ -n $segment && $segment != . && $segment != .. ]] || return 1
  done
  printf '%s\n' "$canonical"
}

validate_archive() {
  local archive=$1 scratch=$2
  local names=$scratch/archive-names verbose=$scratch/archive-verbose metadata=$scratch/archive-metadata
  local count verbose_count name canonical existing row type size listed_name total_size=0
  declare -A seen=()
  declare -A member_types=()

  gzip -t -- "$archive" || fail "archive is not a valid gzip stream: $resolved_asset"
  LC_ALL=C tar --list --gzip --file "$archive" --quoting-style=literal >"$names" \
    || fail "archive member listing failed: $resolved_asset"
  LC_ALL=C tar --list --verbose --gzip --file "$archive" --numeric-owner \
    --quoting-style=literal >"$verbose" \
    || fail "archive verbose listing failed: $resolved_asset"

  count=$(wc -l <"$names")
  verbose_count=$(wc -l <"$verbose")
  [[ $count =~ ^[0-9]+$ && $verbose_count =~ ^[0-9]+$ && $count == "$verbose_count" ]] \
    || fail "archive member listing is ambiguous: $resolved_asset"
  ((count > 0 && count <= archive_member_limit)) \
    || fail "archive member count is outside limits: $count"

  awk -v max_size="$archive_logical_size_limit" '
    NF != 6 { exit 65 }
    {
      type = substr($1, 1, 1)
      if (type != "-" && type != "d") exit 66
      if ($3 !~ /^[0-9]+$/ || $3 + 0 > max_size) exit 67
      print type "\t" $3 "\t" $6
    }
  ' "$verbose" >"$metadata" || fail "archive contains an unsupported member type or name"

  exec 8<"$metadata"
  while IFS= read -r name; do
    IFS= read -r row <&8 || fail "archive listings disagree"
    IFS=$'\t' read -r type size listed_name <<<"$row"
    [[ $listed_name == "$name" ]] || fail "archive listings disagree for member: $name"
    canonical=$(canonical_member_name "$name") \
      || fail "archive contains an unsafe member name"
    [[ ! -v 'seen[$canonical]' ]] || fail "archive contains a duplicate member: $canonical"
    for existing in "${!member_types[@]}"; do
      if [[ $canonical == "$existing/"* && ${member_types[$existing]} != d ]]; then
        fail "archive member has a regular-file parent: $canonical"
      fi
      if [[ $existing == "$canonical/"* && $type != d ]]; then
        fail "archive regular file conflicts with an existing child: $canonical"
      fi
    done
    seen[$canonical]=1
    member_types[$canonical]=$type
    if [[ $type == - ]]; then
      ((size <= archive_logical_size_limit - total_size)) \
        || fail "archive logical size exceeds 2 GiB"
      total_size=$((total_size + size))
    fi
  done <"$names"
  if IFS= read -r row <&8; then
    fail "archive verbose listing has extra members"
  fi
  exec 8<&-
}

validate_tree_safety() {
  local root=$1 scratch=$2 path relative owner mode link_count
  local safety_paths=$scratch/safety-paths

  find -P "$root" -print0 >"$safety_paths" || fail "cannot enumerate published tree: $root"
  while IFS= read -r -d '' path; do
    [[ ! -L $path ]] || fail "published tree contains a symlink: $path"
    owner=$(stat -c %u -- "$path") || fail "cannot read tree owner: $path"
    [[ $owner == "$current_uid" ]] || fail "published tree contains a foreign owner: $path"
    mode=$(stat -c %a -- "$path") || fail "cannot read tree mode: $path"
    [[ $mode =~ ^[0-7]{3,4}$ ]] || fail "published tree has an invalid mode: $path"
    (( (8#$mode & 06022) == 0 )) \
      || fail "published tree contains set-id or group/other writable content: $path"
    if [[ -f $path ]]; then
      link_count=$(stat -c %h -- "$path") || fail "cannot read link count: $path"
      [[ $link_count == 1 ]] || fail "published tree contains a hard-linked file: $path"
    elif [[ ! -d $path ]]; then
      fail "published tree contains a special file: $path"
    fi
    if [[ $path != "$root" ]]; then
      relative=${path#"$root"/}
      canonical_member_name "$relative" >/dev/null \
        || fail "published tree contains an unsafe path: $relative"
    fi
  done <"$safety_paths"
}

validate_required_paths() {
  local record=$1 root=$2 scratch=$3
  local required_file=$scratch/required-paths.jsonl row relative kind executable path mode owner

  jq -e '.install.requiredPaths | type == "object"' <<<"$record" >/dev/null \
    || fail "requiredPaths is malformed"
  jq -c '.install.requiredPaths | to_entries[]' <<<"$record" >"$required_file" \
    || fail "requiredPaths cannot be enumerated"
  while IFS= read -r row; do
    relative=$(jq -e -r '.key | select(type == "string" and length > 0)' <<<"$row") \
      || fail "required path is empty"
    canonical_member_name "$relative" >/dev/null || fail "required path is unsafe: $relative"
    kind=$(jq -e -r '.value.kind | select(. == "file" or . == "directory")' <<<"$row") \
      || fail "required path kind is invalid: $relative"
    executable=$(jq -e -r \
      '.value.executable | if type == "boolean" then tostring else empty end' <<<"$row") \
      || fail "required path execute mode is invalid: $relative"
    path="$root/$relative"
    [[ ! -L $path ]] || fail "required path must not be a symlink: $relative"
    owner=$(stat -c %u -- "$path" 2>/dev/null) || fail "required path is missing: $relative"
    [[ $owner == "$current_uid" ]] || fail "required path has a foreign owner: $relative"
    case $kind in
      file) [[ -f $path ]] || fail "required path is not a regular file: $relative" ;;
      directory) [[ -d $path ]] || fail "required path is not a directory: $relative" ;;
    esac
    if [[ $kind == file ]]; then
      mode=$(stat -c %a -- "$path") || fail "cannot read required path mode: $relative"
      if [[ $executable == true ]]; then
        (( (8#$mode & 0100) != 0 )) || fail "required path is not executable: $relative"
      else
        (( (8#$mode & 0111) == 0 )) || fail "required path must be non-executable: $relative"
      fi
    fi
  done <"$required_file"
}

tree_manifest() {
  local root=$1 output=$2 scratch=$3
  local paths=$scratch/tree-paths path relative mode size digest type

  find -P "$root" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z >"$paths" \
    || fail "cannot enumerate tree manifest: $root"
  : >"$output"
  while IFS= read -r -d '' relative; do
    path="$root/$relative"
    mode=$(stat -c %a -- "$path") || fail "cannot read tree mode: $relative"
    if [[ -f $path && ! -L $path ]]; then
      type=f
      size=$(stat -c %s -- "$path") || fail "cannot read tree size: $relative"
      digest=$(sha256sum -- "$path") || fail "cannot hash tree file: $relative"
      digest=${digest%% *}
    elif [[ -d $path && ! -L $path ]]; then
      type=d
      size=0
      digest=-
    else
      fail "cannot manifest special tree member: $relative"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$mode" "$size" "$digest" "$relative" >>"$output"
  done <"$paths"
}

validate_payload() {
  local record=$1 payload=$2 scratch=$3 manifest=$4

  validate_tree_safety "$payload" "$scratch"
  validate_required_paths "$record" "$payload" "$scratch"
  tree_manifest "$payload" "$manifest" "$scratch"
}

probe_payload_entrypoint() {
  local record=$1 payload=$2 scratch=$3 entrypoint=$4 before_manifest=$5 after_manifest=$6
  local version_args_json status timeout_command
  local -a version_args

  version_args_json=$(jq -e -c '.versionArgs | select(type == "array" and length > 0)' <<<"$record") \
    || fail "version arguments are missing"
  mapfile -d '' -t version_args < <(decode_version_args "$version_args_json")
  timeout_command=$(command -v timeout)

  mkdir -m 0700 -- "$scratch/home" "$scratch/codex-home" "$scratch/cache" \
    "$scratch/config" "$scratch/data" "$scratch/state" "$scratch/tmp" "$scratch/work"
  set +e
  env -i \
    LC_ALL=C \
    TERM=dumb \
@probeEnvironment@    "$timeout_command" --kill-after="${probe_kill_grace_seconds}s" \
    "${probe_timeout_seconds}s" "$atomic_publish_command" probe-exec \
    "$active_stage_fd" "$active_stage_identity" probe/work "payload/$entrypoint" \
    "$active_stage_public/payload/$entrypoint" "$client_root_fd" "$releases_root_fd" \
    "$visible_parent_fd" -- "${version_args[@]}" \
    </dev/null >"$scratch/version.stdout" 2>"$scratch/version.stderr"
  status=$?
  set -e
  if ((status != 0)); then
    while IFS= read -r probe_error; do
      printf '%s\n' "$probe_error" >&2
    done <"$scratch/version.stderr"
    fail "staged entrypoint version check failed with status $status"
  fi

  validate_payload "$record" "$payload" "$scratch" "$after_manifest"
  cmp -- "$before_manifest" "$after_manifest" \
    || fail "staged package tree changed during version probe"
}

inspect_publish_destinations() {
  local record=$1 name=$2 binary=$3 entrypoint=$4 scratch=$5
  local current=$client_root_view/current visible=$visible_parent_view/$binary
  local current_manifest=$scratch/current-release.manifest target release entry owner links
  local current_identity_before current_identity_after visible_identity_before visible_identity_after

  current_identity_before=$(atomic_identity_fd "$client_root_fd" "$client_root_identity" current) \
    || fail "cannot capture current identity for $name"

  current_state=missing
  current_target=
  if [[ -L $current ]]; then
    owner=$(stat -c %u -- "$current") || fail "cannot read current symlink owner for $name"
    [[ $owner == "$current_uid" ]] || fail "current symlink has a foreign owner for $name"
    target=$(readlink -- "$current") || fail "cannot read current symlink for $name"
    [[ $target =~ ^releases/sha256-[0-9a-f]{64}$ ]] \
      || fail "current symlink has an external or invalid target for $name: $target"
    release="$client_root_view/$target"
    owned_real_directory "$release" "current release"
    validate_payload "$record" "$release" "$scratch" "$current_manifest"
    entry="$release/$entrypoint"
    [[ -f $entry && ! -L $entry ]] || fail "current entrypoint is missing for $name"
    owner=$(stat -c %u -- "$entry") || fail "cannot read current entrypoint owner for $name"
    [[ $owner == "$current_uid" && -x $entry ]] \
      || fail "current entrypoint is not owned and executable for $name"
    current_state=stable
    current_target=$target
  elif [[ -e $current ]]; then
    fail "current must be absent or a managed relative symlink for $name"
  fi

  current_identity_after=$(atomic_identity_fd "$client_root_fd" "$client_root_identity" current) \
    || fail "cannot recapture current identity for $name"
  [[ $current_identity_after == "$current_identity_before" ]] \
    || fail "current changed while validating publish destination for $name"
  current_identity=$current_identity_before

  stable_visible_target="../share/dotfiles/agents/$name/current/$entrypoint"
  visible_identity_before=$(atomic_identity_fd "$visible_parent_fd" "$visible_parent_identity" \
    "$binary") \
    || fail "cannot capture visible identity for $name"
  visible_state=missing
  if [[ -L $visible ]]; then
    owner=$(stat -c %u -- "$visible") || fail "cannot read visible symlink owner for $name"
    [[ $owner == "$current_uid" ]] || fail "visible symlink has a foreign owner for $name"
    target=$(readlink -- "$visible") || fail "cannot read visible symlink for $name"
    [[ $target == "$stable_visible_target" ]] \
      || fail "visible binary has an unexpected symlink target for $name: $target"
    [[ $current_state == stable ]] || fail "visible binary is a dangling managed symlink for $name"
    visible_state=stable
  elif [[ -e $visible ]]; then
    [[ -f $visible ]] || fail "visible binary has an unexpected existing shape for $name"
    owner=$(stat -c %u -- "$visible") || fail "cannot read legacy binary owner for $name"
    links=$(stat -c %h -- "$visible") || fail "cannot read legacy binary link count for $name"
    [[ $owner == "$current_uid" && $links == 1 && -x $visible ]] \
      || fail "legacy visible binary is not an owned executable regular file for $name"
    visible_state=legacy
  fi
  visible_identity_after=$(atomic_identity_fd "$visible_parent_fd" "$visible_parent_identity" \
    "$binary") \
    || fail "cannot recapture visible identity for $name"
  [[ $visible_identity_after == "$visible_identity_before" ]] \
    || fail "visible changed while validating publish destination for $name"
  visible_identity=$visible_identity_before
}

verify_public_directory_bindings() {
  local name=$1 actual

  actual=$(atomic_directory_identity "$client_root") \
    || fail "cannot resolve public client root during publish for $name"
  [[ $actual == "$client_root_identity" ]] \
    || fail "public client root changed during publish for $name"
  actual=$(atomic_directory_identity "$releases_root") \
    || fail "cannot resolve public release directory during publish for $name"
  [[ $actual == "$releases_root_identity" ]] \
    || fail "public release directory changed during publish for $name"
  actual=$(atomic_directory_identity "$HOME/.local/bin") \
    || fail "cannot resolve public visible parent during publish for $name"
  [[ $actual == "$visible_parent_identity" ]] \
    || fail "public visible parent changed during publish for $name"
}

create_temp_symlink() {
  local directory_fd=$1 directory_identity=$2 directory_view=$3 prefix=$4 target=$5
  local output_variable=$6 identity_variable=$7
  local candidate identity identity_after owner actual_target attempt status

  for ((attempt = 1; attempt <= temp_symlink_attempt_limit; attempt++)); do
    candidate="$directory_view/.${prefix}.next.$$.$RANDOM.$attempt"
    if identity=$("$atomic_publish_command" symlink-noreplace-fd "$directory_fd" \
      "$directory_identity" "${candidate##*/}" "$target"); then
      printf -v "$output_variable" '%s' "$candidate"
      printf -v "$identity_variable" '%s' "$identity"
      [[ -L $candidate ]] || fail "temporary publish object is not a symlink: $candidate"
      owner=$(stat -c %u -- "$candidate") \
        || fail "cannot read temporary symlink owner: $candidate"
      [[ $owner == "$current_uid" ]] \
        || fail "temporary symlink has a foreign owner: $candidate"
      actual_target=$(readlink -- "$candidate") \
        || fail "cannot read temporary symlink target: $candidate"
      [[ $actual_target == "$target" ]] \
        || fail "temporary symlink target changed: $candidate"
      identity_after=$(atomic_identity_fd "$directory_fd" "$directory_identity" \
        "${candidate##*/}") || fail "cannot recapture temporary symlink identity in $directory_view"
      [[ $identity_after == "$identity" ]] \
        || fail "temporary symlink changed during validation: $candidate"
      return
    else
      status=$?
      ((status == 4)) && continue
      fail "cannot create temporary symlink in $directory_view (status $status)"
    fi
  done
  fail "cannot allocate temporary symlink in $directory_view"
}

rollback_visible_transaction() {
  local backup_name=${active_visible_next##*/}

  case $transaction_visible_state in
    none) return 0 ;;
    switched)
      case $transaction_visible_method in
        exchange)
          atomic_operation exchange-fd "$visible_parent_fd" "$visible_parent_identity" \
            "$backup_name" "$visible_parent_fd" "$visible_parent_identity" \
            "$transaction_visible_binary" \
            "$transaction_visible_old_identity" \
            "$transaction_visible_new_identity" || return
          active_visible_next_identity=$transaction_visible_new_identity
          ;;
        move)
          atomic_operation move-noreplace-fd "$visible_parent_fd" "$visible_parent_identity" \
            "$transaction_visible_binary" "$visible_parent_fd" "$visible_parent_identity" \
            "$backup_name" "$transaction_visible_new_identity" || return
          active_visible_next_identity=$transaction_visible_new_identity
          ;;
        *) return 1 ;;
      esac
      transaction_visible_state=none
      ;;
    *) return 1 ;;
  esac
}

rollback_current_transaction() {
  local backup_name=${active_current_next##*/}

  case $transaction_current_state in
    none) return 0 ;;
    switched)
      case $transaction_current_method in
        exchange)
          atomic_operation exchange-fd "$client_root_fd" "$client_root_identity" "$backup_name" \
            "$client_root_fd" "$client_root_identity" current \
            "$transaction_current_old_identity" "$transaction_current_new_identity" || return
          active_current_next_identity=$transaction_current_new_identity
          ;;
        move)
          atomic_operation move-noreplace-fd "$client_root_fd" "$client_root_identity" current \
            "$client_root_fd" "$client_root_identity" "$backup_name" \
            "$transaction_current_new_identity" || return
          active_current_next_identity=$transaction_current_new_identity
          ;;
        *) return 1 ;;
      esac
      transaction_current_state=none
      ;;
    *) return 1 ;;
  esac
}

rollback_release_transaction() {
  local rollback_manifest

  [[ $transaction_release_state == published ]] || return 0
  rollback_manifest=$transaction_release_scratch/rollback-release.manifest
  if ! (
    trap - EXIT
    validate_payload "$transaction_release_record" \
      "$releases_root_view/$transaction_release_name" "$transaction_release_scratch" \
      "$rollback_manifest"
    cmp -- "$transaction_release_manifest" "$rollback_manifest"
  ); then
    echo "FATAL: published release changed during rollback; preserving transaction state" >&2
    return 1
  fi
  atomic_operation move-noreplace-fd "$releases_root_fd" "$releases_root_identity" \
    "$transaction_release_name" "$active_stage_fd" "$active_stage_identity" \
    "${transaction_release_payload##*/}" \
    "$transaction_release_identity" || return
  transaction_release_state=none
}

rollback_publish_transaction() {
  rollback_visible_transaction || return
  rollback_current_transaction || return
  rollback_release_transaction || return
  transaction_active=0
}

discard_transaction_backup() {
  local directory_fd=$1 directory_identity=$2 path=$3 identity=$4 label=$5

  [[ -n $path ]] || return 0
  if "$atomic_publish_command" unlink-if-fd "$directory_fd" "$directory_identity" \
    "${path##*/}" "$identity"; then
    return 0
  fi
  echo "FATAL: preserving changed $label transaction backup: $path" >&2
  return 1
}

commit_publish_transaction() {
  local cleanup_status=0

  # The switched state is committed before old objects are destroyed.  A failed cleanup is
  # reported and retains its exact identity so the EXIT trap can retry without guessing.
  transaction_active=0
  if [[ $transaction_visible_method == exchange ]]; then
    if discard_transaction_backup "$visible_parent_fd" "$visible_parent_identity" \
      "$active_visible_next" "$transaction_visible_old_identity" visible; then
      active_visible_next=
      active_visible_next_identity=
    else
      cleanup_status=1
    fi
  else
    active_visible_next=
    active_visible_next_identity=
  fi
  if [[ $transaction_current_method == exchange ]]; then
    if discard_transaction_backup "$client_root_fd" "$client_root_identity" \
      "$active_current_next" "$transaction_current_old_identity" current; then
      active_current_next=
      active_current_next_identity=
    else
      cleanup_status=1
    fi
  else
    active_current_next=
    active_current_next_identity=
  fi
  transaction_release_state=none
  transaction_current_state=none
  transaction_visible_state=none
  return "$cleanup_status"
}

publish_validated_payload() {
  local record=$1 name=$2 binary=$3 entrypoint=$4 payload=$5 scratch=$6 manifest=$7 digest=$8
  local payload_name=${payload##*/} scratch_name=${scratch##*/} manifest_name=${manifest##*/}
  local release_name="sha256-$digest" release_path
  local existing_manifest current=$client_root/current published_manifest
  local visible=$HOME/.local/bin/$binary target="releases/$release_name" payload_identity
  local release_identity_before release_identity_after

  # All transaction reads and writes use the directories pinned before remote input was read.
  # Public paths below are passed only to deterministic fixture hooks and diagnostics.
  payload="$active_stage_view/$payload_name"
  scratch="$active_stage_view/$scratch_name"
  manifest="$scratch/$manifest_name"
  release_path="$releases_root_view/$release_name"
  existing_manifest=$scratch/existing-release.manifest
  published_manifest=$scratch/published-release.manifest

  inspect_publish_destinations "$record" "$name" "$binary" "$entrypoint" "$scratch"
  transaction_active=1
  transaction_rollback_ambiguous=0
  transaction_release_state=none
  transaction_current_state=none
  transaction_visible_state=none
  transaction_current_method=none
  transaction_visible_method=none
  transaction_visible_binary=$binary

  if [[ -e $release_path || -L $release_path ]]; then
    owned_real_directory "$release_path" "existing release"
    validate_payload "$record" "$release_path" "$scratch" "$existing_manifest"
    cmp -- "$manifest" "$existing_manifest" \
      || fail "existing release differs from the validated archive: $release_name"
  else
    payload_identity=$(atomic_identity_fd "$active_stage_fd" "$active_stage_identity" \
      "$payload_name") \
      || fail "cannot capture staged payload identity: $release_name"
    transaction_release_name=$release_name
    transaction_release_identity=$payload_identity
    transaction_release_record=$record
    transaction_release_manifest=$manifest
    transaction_release_scratch=$scratch
    transaction_release_payload=$payload
    atomic_operation move-noreplace-fd "$active_stage_fd" "$active_stage_identity" \
      "$payload_name" "$releases_root_fd" "$releases_root_identity" "$release_name" \
      "$payload_identity" \
      || fail "cannot publish release: $release_name"
    transaction_release_state=published
    verify_public_directory_bindings "$name"
    run_transaction_hook after-release-publish "$releases_root/$release_name"
  fi

  release_identity_before=$(atomic_identity_fd "$releases_root_fd" "$releases_root_identity" \
    "$release_name") \
    || fail "cannot capture published release identity: $release_name"
  owned_real_directory "$release_path" "published release"
  validate_payload "$record" "$release_path" "$scratch" "$published_manifest"
  cmp -- "$manifest" "$published_manifest" \
    || fail "published release differs from the validated archive: $release_name"
  release_identity_after=$(atomic_identity_fd "$releases_root_fd" "$releases_root_identity" \
    "$release_name") \
    || fail "cannot recapture published release identity: $release_name"
  [[ $release_identity_after == "$release_identity_before" ]] \
    || fail "published release changed identity during validation: $release_name"
  if [[ $transaction_release_state == published ]]; then
    [[ $release_identity_after == "$transaction_release_identity" ]] \
      || fail "published release identity differs from staged payload: $release_name"
  fi
  inspect_publish_destinations "$record" "$name" "$binary" "$entrypoint" "$scratch"

  if [[ $current_state != stable || $current_target != "$target" ]]; then
    create_temp_symlink "$client_root_fd" "$client_root_identity" "$client_root_view" current \
      "$target" active_current_next active_current_next_identity
    transaction_current_old_identity=$current_identity
    transaction_current_new_identity=$active_current_next_identity
    run_transaction_hook before-current-switch "$current"
    case $current_state in
      missing)
        atomic_operation move-noreplace-fd "$client_root_fd" "$client_root_identity" \
          "${active_current_next##*/}" "$client_root_fd" "$client_root_identity" current \
          "$transaction_current_new_identity" \
          || fail "current destination changed before publish for $name"
        transaction_current_method=move
        ;;
      stable)
        atomic_operation exchange-fd "$client_root_fd" "$client_root_identity" \
          "${active_current_next##*/}" "$client_root_fd" "$client_root_identity" current \
          "$transaction_current_new_identity" \
          "$transaction_current_old_identity" \
          || fail "current destination changed before publish for $name"
        active_current_next_identity=$transaction_current_old_identity
        transaction_current_method=exchange
        ;;
      *) fail "current has an unexpected transaction state for $name" ;;
    esac
    transaction_current_state=switched
    verify_public_directory_bindings "$name"
    run_transaction_hook after-current-switch "$current"
  fi

  if [[ $visible_state != stable ]]; then
    create_temp_symlink "$visible_parent_fd" "$visible_parent_identity" "$visible_parent_view" \
      "$binary" "$stable_visible_target" active_visible_next active_visible_next_identity
    transaction_visible_old_identity=$visible_identity
    transaction_visible_new_identity=$active_visible_next_identity
    run_transaction_hook before-visible-switch "$visible"
    case $visible_state in
      missing)
        atomic_operation move-noreplace-fd "$visible_parent_fd" "$visible_parent_identity" \
          "${active_visible_next##*/}" "$visible_parent_fd" "$visible_parent_identity" \
          "$binary" "$transaction_visible_new_identity" \
          || fail "visible destination changed before publish for $name"
        transaction_visible_method=move
        ;;
      legacy)
        atomic_operation exchange-fd "$visible_parent_fd" "$visible_parent_identity" \
          "${active_visible_next##*/}" "$visible_parent_fd" "$visible_parent_identity" \
          "$binary" "$transaction_visible_new_identity" \
          "$transaction_visible_old_identity" \
          || fail "visible destination changed before publish for $name"
        active_visible_next_identity=$transaction_visible_old_identity
        transaction_visible_method=exchange
        ;;
      *) fail "visible has an unexpected transaction state for $name" ;;
    esac
    transaction_visible_state=switched
    verify_public_directory_bindings "$name"
    run_transaction_hook after-visible-switch "$visible"
  fi

  verify_public_directory_bindings "$name"
  commit_publish_transaction || fail "cannot clean committed publish transaction for $name"
}

prepare_and_validate_archive() {
  local record=$1 payload=$2 scratch=$3

  validate_archive "$active_stage/archive.tar.gz" "$scratch"
  mkdir -m 0700 -- "$payload"
  # GNU tar は --keep-old-files と --no-overwrite-dir を併用できない。fresh payload と
  # 事前の canonical path/duplicate 検査で file の上書きを閉じ、directory metadata を守る。
  (
    umask 077
    tar --extract --gzip --file "$active_stage/archive.tar.gz" --directory "$payload" \
      --no-same-owner --no-same-permissions --no-overwrite-dir
  ) || fail "archive extraction failed: $resolved_asset"
  validate_tree_safety "$payload" "$scratch"
  validate_required_paths "$record" "$payload" "$scratch"
}

publish_single_binary() {
  local record=$1 name=$2 binary=$3 payload=$active_stage/payload scratch=$active_stage/probe
  local before_manifest=$scratch/tree-before.manifest after_manifest=$scratch/tree-after.manifest

  mkdir -m 0700 -- "$scratch"
  prepare_and_validate_archive "$record" "$payload" "$scratch"
  [[ -f $payload/$resolved_entrypoint && ! -L $payload/$resolved_entrypoint ]] \
    || fail "binary not found in archive: $resolved_entrypoint"
  [[ -x $payload/$resolved_entrypoint ]] \
    || fail "binary is not executable in archive: $resolved_entrypoint"
  validate_payload "$record" "$payload" "$scratch" "$before_manifest"
  probe_payload_entrypoint "$record" "$payload" "$scratch" "$resolved_entrypoint" \
    "$before_manifest" "$after_manifest"
  publish_validated_payload "$record" "$name" "$binary" "$resolved_entrypoint" \
    "$payload" "$scratch" "$after_manifest" "$resolved_digest"
}

publish_package_tree() {
  local record=$1 name=$2 binary=$3 payload=$active_stage/payload scratch=$active_stage/probe
  local before_manifest=$scratch/tree-before.manifest after_manifest=$scratch/tree-after.manifest

  mkdir -m 0700 -- "$scratch"
  prepare_and_validate_archive "$record" "$payload" "$scratch"
  validate_payload "$record" "$payload" "$scratch" "$before_manifest"
  probe_payload_entrypoint "$record" "$payload" "$scratch" "$resolved_entrypoint" \
    "$before_manifest" "$after_manifest"
  publish_validated_payload "$record" "$name" "$binary" "$resolved_entrypoint" \
    "$payload" "$scratch" "$after_manifest" "$resolved_digest"
}

install_github_release() {
  local record=$1 name binary layout client_root_path_identity
  local releases_root_path_identity visible_parent_path_identity active_stage_path_identity

  name=$(jq -e -r '.name | select(type == "string" and length > 0)' <<<"$record") \
    || fail "GitHub release client name is missing"
  binary=$(jq -e -r '.binary | select(type == "string" and length > 0)' <<<"$record") \
    || fail "GitHub release binary is missing for $name"
  [[ $binary =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe binary name for $name: $binary"
  layout=$(jq -e -r '.install.layout | select(. == "single-binary" or . == "package-tree")' \
    <<<"$record") || fail "unsupported GitHub release layout for $name"
  resolved_repo=$(jq -e -r '.install.repo | select(type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))' \
    <<<"$record") || fail "invalid GitHub repository for $name"
  jq -e '.versionArgs | type == "array" and length > 0' <<<"$record" >/dev/null \
    || fail "version arguments are missing for $name"

  prepare_client_root "$name"
  exec {client_root_fd}<"$client_root" || fail "cannot open client root for locking: $name"
  flock -x "$client_root_fd" || fail "cannot lock client root: $name"
  client_root_identity=$(atomic_directory_identity_fd "$client_root_fd") \
    || fail "cannot capture locked client root identity: $name"
  client_root_path_identity=$(atomic_directory_identity "$client_root") \
    || fail "cannot safely resolve locked client root: $name"
  [[ $client_root_path_identity == "$client_root_identity" ]] \
    || fail "client root path changed before update: $name"
  client_root_view=/proc/self/fd/$client_root_fd

  exec {releases_root_fd}<"$client_root_view/releases" \
    || fail "cannot open release directory for $name"
  releases_root_identity=$(atomic_directory_identity_fd "$releases_root_fd") \
    || fail "cannot capture pinned release directory identity: $name"
  releases_root_path_identity=$(atomic_directory_identity "$releases_root") \
    || fail "cannot safely resolve release directory: $name"
  [[ $releases_root_path_identity == "$releases_root_identity" ]] \
    || fail "release directory path changed before update: $name"
  releases_root_view=/proc/self/fd/$releases_root_fd

  exec {visible_parent_fd}<"$HOME/.local/bin" \
    || fail "cannot open visible parent for $name"
  visible_parent_identity=$(atomic_directory_identity_fd "$visible_parent_fd") \
    || fail "cannot capture pinned visible parent identity: $name"
  visible_parent_path_identity=$(atomic_directory_identity "$HOME/.local/bin") \
    || fail "cannot safely resolve visible parent: $name"
  [[ $visible_parent_path_identity == "$visible_parent_identity" ]] \
    || fail "visible parent path changed before update: $name"
  visible_parent_view=/proc/self/fd/$visible_parent_fd

  active_stage=$(mktemp -d -p "$client_root_view" '.stage.XXXXXXXXXX') \
    || fail "cannot create same-filesystem stage for $name"
  active_stage_name=${active_stage##*/}
  active_stage_public=$client_root/$active_stage_name
  chmod 0700 "$active_stage"
  exec {active_stage_fd}<"$active_stage" || fail "cannot open stage directory for $name"
  active_stage_identity=$(atomic_directory_identity_fd "$active_stage_fd") \
    || fail "cannot capture pinned stage identity: $name"
  active_stage_path_identity=$(atomic_directory_identity "$active_stage_public") \
    || fail "cannot safely resolve stage directory: $name"
  [[ $active_stage_path_identity == "$active_stage_identity" ]] \
    || fail "stage directory path changed before update: $name"
  active_stage_view=/proc/self/fd/$active_stage_fd
  active_stage=$active_stage_view

  resolve_github_release "$record"
  log "$name"
  curl_https --output "$active_stage/archive.tar.gz" "$resolved_url"
  resolved_digest=$(sha256sum -- "$active_stage/archive.tar.gz") \
    || fail "cannot hash downloaded archive: $resolved_asset"
  resolved_digest=${resolved_digest%% *}
  [[ $resolved_digest =~ ^[0-9a-f]{64}$ ]] || fail "downloaded archive digest is invalid"
  [[ $resolved_api_digest =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "release asset digest is malformed or missing: $resolved_asset"
  [[ $resolved_api_digest == "sha256:$resolved_digest" ]] \
    || fail "release asset digest does not match downloaded archive: $resolved_asset"

  case $layout in
    single-binary) publish_single_binary "$record" "$name" "$binary" ;;
    package-tree) publish_package_tree "$record" "$name" "$binary" ;;
  esac

  "$atomic_publish_command" remove-tree-fd "$client_root_fd" "$client_root_identity" \
    "$active_stage_name" "$active_stage_fd" "$active_stage_identity" \
    || fail "cannot remove completed stage for $name"
  exec {active_stage_fd}>&-
  active_stage=
  active_stage_public=
  active_stage_fd=
  active_stage_view=
  active_stage_name=
  active_stage_identity=
  exec {releases_root_fd}>&-
  releases_root_fd=
  releases_root_view=
  releases_root_identity=
  exec {visible_parent_fd}>&-
  visible_parent_fd=
  visible_parent_view=
  visible_parent_identity=
  exec {client_root_fd}>&-
  client_root_fd=
  client_root_view=
  client_root_identity=
}

while IFS= read -r record; do
  kind=$(jq -e -r '.install.kind | select(type == "string" and length > 0)' <<<"$record") \
    || fail "install kind is missing"
  name=$(jq -e -r '.name | select(type == "string" and length > 0)' <<<"$record") \
    || fail "client name is missing"

  case $kind in
    installer-script) install_installer_script "$record" ;;
    github-release) install_github_release "$record" ;;
    *) fail "unknown install kind for $name: $kind" ;;
  esac
done < <(jq -e -c '.[]' <<<"$install_manifest")
