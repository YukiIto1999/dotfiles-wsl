set -euo pipefail

usage() {
  printf 'usage: dotfiles-agent-verification-cache [--receipt TOKEN] -- COMMAND [ARG...]\n' >&2
  exit 64
}

receipt_token=
if [ "${1-}" = --receipt ]; then
  [ "$#" -ge 2 ] || usage
  receipt_token=$2
  shift 2
fi
[ "${1-}" = -- ] || usage
shift
[ "$#" -gt 0 ] || usage

if ! repo_top=$(git rev-parse --show-toplevel 2>/dev/null) \
  || ! common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || ! repo_top=$(realpath -e -- "$repo_top") \
  || ! common_dir=$(realpath -e -- "$common_dir"); then
  exec "$@"
fi

project_id=$(printf '%s' "$common_dir" | sha256sum | cut -d ' ' -f 1)
verification_root="$HOME/@cacheRootRelative@/verification"
project_state="$verification_root/$project_id"
mkdir -p "$HOME/.cache"

ensure_state_directory() {
  local path=$1
  if mkdir -m 700 "$path" 2>/dev/null; then
    return
  fi
  test ! -L "$path" || return 1
  test -d "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 700 "$path" || return 1
  test "$(stat -c %a "$path")" = 700
}

prepare_success_file() {
  local path=$1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  test ! -L "$path" || return 1
  test -f "$path" || return 1
  test "$(stat -c %u "$path")" = "$(id -u)" || return 1
  chmod 600 "$path" || return 1
  test "$(stat -c %a "$path")" = 600
}

if ! ensure_state_directory "$HOME/@cacheRootRelative@" \
  || ! ensure_state_directory "$verification_root" \
  || ! ensure_state_directory "$project_state"; then
  exec "$@"
fi

scratch_prefix=$verification_root/.fingerprint
[ -z "$receipt_token" ] || scratch_prefix=$scratch_prefix.$receipt_token
scratch=$(mktemp -d "$scratch_prefix.XXXXXXXX")
# shellcheck disable=SC2329 # EXIT trap invokes this function indirectly.
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$scratch" == "$verification_root/"* ]] && [ ! -L "$scratch" ] && [ -d "$scratch" ]; then
    rm -rf --one-file-system -- "$scratch" || true
  fi
  exit "$status"
}
trap cleanup EXIT

write_command_identity() {
  local executable
  if [[ "$1" == */* ]]; then
    executable=$1
  else
    executable=$(command -v -- "$1" 2>/dev/null) || return 1
  fi

  if [ -f "$executable" ]; then
    executable=$(realpath -e -- "$executable") || return 1
    printf 'executable-path\0%s\0executable-content\0' "$executable"
    sha256sum -- "$executable"
  else
    printf 'shell-command\0%s\0bash-version\0%s\0' "$executable" "$BASH_VERSION"
  fi
}

write_tracked_metadata() {
  local repository=$1 tracked=$2 guard=$3 namespace=$4
  local record index_fields index_mode path absolute semantic_path
  local index_oid index_stage metadata digest offset batch validation_guard
  local -a paths=() regulars=()
  local -A metadata_before=() guards_before=() hashes=()
  local -A metadata_after=() guards_after=()

  batch=$(mktemp -d "$scratch/.tracked-batch.XXXXXXXX") || return 1
  while IFS= read -r -d '' record; do
    [[ $record == *$'\t'* ]] || return 1
    index_fields=${record%%$'\t'*}
    index_mode=${index_fields%% *}
    index_stage=${index_fields##* }
    [ "$index_stage" = 0 ] || return 1
    path=${record#*$'\t'}
    absolute=$repository/$path
    if [ ! -e "$absolute" ] && [ ! -L "$absolute" ]; then
      [ "$index_mode" != 160000 ] || return 1
      continue
    fi
    paths+=("$absolute")
    if [ "$index_mode" = 160000 ]; then
      [ -d "$absolute" ] && [ ! -L "$absolute" ] || return 1
    elif [ -L "$absolute" ]; then
      continue
    elif [ -f "$absolute" ]; then
      regulars+=("$absolute")
    else
      return 1
    fi
  done <"$tracked"

  : >"$batch/before"
  for ((offset = 0; offset < ${#paths[@]}; offset += 128)); do
    stat --printf '%n\0%f:%u:%g:%h:%s\0%d:%i:%f:%u:%g:%h:%s:%y:%z\0' \
      -- "${paths[@]:offset:128}" >>"$batch/before" 2>/dev/null || return 1
  done
  while IFS= read -r -d '' absolute \
    && IFS= read -r -d '' metadata \
    && IFS= read -r -d '' record; do
    metadata_before["$absolute"]=$metadata
    guards_before["$absolute"]=$record
  done <"$batch/before"

  : >"$batch/hashes"
  for ((offset = 0; offset < ${#regulars[@]}; offset += 128)); do
    sha256sum --zero -- "${regulars[@]:offset:128}" >>"$batch/hashes" || return 1
  done
  while IFS= read -r -d '' record; do
    digest=${record:0:64}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
    hashes["${record:66}"]=$digest
  done <"$batch/hashes"

  while IFS= read -r -d '' record; do
    index_fields=${record%%$'\t'*}
    index_mode=${index_fields%% *}
    index_oid=${index_fields#* }
    index_oid=${index_oid%% *}
    path=${record#*$'\t'}
    absolute=$repository/$path
    semantic_path=$namespace$path
    printf 'index\0%s\0path\0%s\0' "$index_fields" "$semantic_path"
    if [ ! -e "$absolute" ] && [ ! -L "$absolute" ]; then
      [ -z "${metadata_before["$absolute"]-}" ] || return 1
      printf 'missing\0'
      printf 'path\0%s\0missing\0' "$semantic_path" >>"$guard"
      continue
    fi
    metadata=${metadata_before["$absolute"]-}
    [ -n "$metadata" ] || return 1
    validation_guard=${guards_before["$absolute"]}
    if [ "$index_mode" = 160000 ]; then
      metadata=${metadata%:*}
      metadata=${metadata%:*}
      record=${validation_guard#*:}
      validation_guard="${validation_guard%%:*}:${record%%:*}:$metadata"
    fi
    printf 'lstat\0%s\0' "$metadata"
    printf 'path\0%s\0lstat\0%s\0' "$semantic_path" "$validation_guard" >>"$guard"
    if [ "$index_mode" = 160000 ]; then
      [ -d "$absolute" ] && [ ! -L "$absolute" ] || return 1
      write_clean_gitlink "$absolute" "$index_oid" "$semantic_path/" "$guard" || return 1
    elif [ -L "$absolute" ]; then
      printf 'symlink\0'
      readlink --zero -- "$absolute" || return 1
    elif [ -f "$absolute" ]; then
      digest=${hashes["$absolute"]-}
      [ -n "$digest" ] || return 1
      printf 'regular\0%s  -\n' "$digest"
    else
      return 1
    fi
  done <"$tracked"

  : >"$batch/after"
  for ((offset = 0; offset < ${#paths[@]}; offset += 128)); do
    stat --printf '%n\0%f:%u:%g:%h:%s\0%d:%i:%f:%u:%g:%h:%s:%y:%z\0' \
      -- "${paths[@]:offset:128}" >>"$batch/after" 2>/dev/null || return 1
  done
  while IFS= read -r -d '' absolute \
    && IFS= read -r -d '' metadata \
    && IFS= read -r -d '' record; do
    metadata_after["$absolute"]=$metadata
    guards_after["$absolute"]=$record
  done <"$batch/after"
  for absolute in "${paths[@]}"; do
    [ "${metadata_after["$absolute"]-}" = "${metadata_before["$absolute"]}" ] || return 1
    [ "${guards_after["$absolute"]-}" = "${guards_before["$absolute"]}" ] || return 1
  done
  while IFS= read -r -d '' record; do
    path=${record#*$'\t'}
    absolute=$repository/$path
    if [ -z "${metadata_before["$absolute"]-}" ]; then
      [ ! -e "$absolute" ] && [ ! -L "$absolute" ] || return 1
    fi
  done <"$tracked"
}

validate_index_flags() {
  local flags=$1 record
  while IFS= read -r -d '' record; do
    [[ $record == 'H '* ]] || return 1
  done <"$flags"
}

write_clean_gitlink() {
  local absolute=$1 expected_head=$2 namespace=$3 guard=$4
  local canonical top head_before head_after
  local index_before index_after flags_before flags_after status_before status_after

  [[ $expected_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
  canonical=$(realpath -e -- "$absolute") || return 1
  top=$(git -C "$absolute" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(realpath -e -- "$top") || return 1
  [ "$top" = "$canonical" ] || return 1
  head_before=$(git -C "$absolute" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$head_before" = "$expected_head" ] || return 1

  index_before=$(mktemp "$scratch/.gitlink-index-before.XXXXXXXX") || return 1
  index_after=$(mktemp "$scratch/.gitlink-index-after.XXXXXXXX") || return 1
  flags_before=$(mktemp "$scratch/.gitlink-flags-before.XXXXXXXX") || return 1
  flags_after=$(mktemp "$scratch/.gitlink-flags-after.XXXXXXXX") || return 1
  status_before=$(mktemp "$scratch/.gitlink-status-before.XXXXXXXX") || return 1
  status_after=$(mktemp "$scratch/.gitlink-status-after.XXXXXXXX") || return 1

  git -C "$absolute" ls-files --stage -z >"$index_before" || return 1
  git -C "$absolute" ls-files -v -z >"$flags_before" || return 1
  validate_index_flags "$flags_before" || return 1
  git --no-optional-locks -C "$absolute" status --porcelain=v1 --untracked-files=all \
    --ignore-submodules=all >"$status_before" 2>/dev/null || return 1
  [ ! -s "$status_before" ] || return 1

  printf 'gitlink\0head\0%s\0flags\0' "$head_before"
  cat "$flags_before" || return 1
  printf '\0tracked\0'
  write_tracked_metadata "$absolute" "$index_before" "$guard" "$namespace" || return 1

  git -C "$absolute" ls-files --stage -z >"$index_after" || return 1
  git -C "$absolute" ls-files -v -z >"$flags_after" || return 1
  cmp -- "$index_before" "$index_after" || return 1
  cmp -- "$flags_before" "$flags_after" || return 1
  validate_index_flags "$flags_after" || return 1
  git --no-optional-locks -C "$absolute" status --porcelain=v1 --untracked-files=all \
    --ignore-submodules=all >"$status_after" 2>/dev/null || return 1
  [ ! -s "$status_after" ] || return 1
  head_after=$(git -C "$absolute" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  [ "$head_after" = "$head_before" ] || return 1
}

write_untracked_guard() {
  local path
  while IFS= read -r -d '' path; do
    printf 'path\0%s\0' "$path"
    stat --printf '%d:%i:%f:%u:%g:%h:%s:%y:%z\0' -- "$repo_top/$path" || return 1
  done <"$1"
}

fingerprint() {
  local untracked=$scratch/untracked tracked=$scratch/tracked-index path mode relative_cwd head
  local link_target tracked_after=$scratch/tracked-index-after
  local tracked_metadata=$scratch/tracked-metadata
  local tracked_metadata_after=$scratch/tracked-metadata-after
  local tracked_guard=$scratch/tracked-guard
  local tracked_guard_after=$scratch/tracked-guard-after
  local tracked_diff=$scratch/tracked-diff
  local semantic untracked_after=$scratch/untracked-after
  local untracked_guard=$scratch/untracked-guard untracked_guard_after=$scratch/untracked-guard-after
  head=$(git -C "$repo_top" rev-parse --verify HEAD 2>/dev/null) || return 1
  relative_cwd=$(realpath --relative-to "$repo_top" "$(pwd -P)") || return 1
  git -C "$repo_top" ls-files --stage -z >"$tracked" || return 1
  : >"$tracked_guard"
  write_tracked_metadata "$repo_top" "$tracked" "$tracked_guard" "" \
    >"$tracked_metadata" || return 1
  git -C "$repo_top" -c color.ui=false diff \
    --binary --full-index --no-ext-diff --no-textconv HEAD -- >"$tracked_diff" || return 1
  git -C "$repo_top" ls-files --others --exclude-standard -z >"$untracked" || return 1
  write_untracked_guard "$untracked" >"$untracked_guard" || return 1

  semantic=$({
    printf 'dotfiles-agent-verify-v6\0common-dir\0%s\0repo-head\0%s\0cwd\0%s\0' \
      "$common_dir" "$head" "$relative_cwd"
    printf 'tracked-diff\0'
    cat "$tracked_diff" || return 1
    printf '\0tracked-metadata\0'
    cat "$tracked_metadata" || return 1
    printf '\0untracked\0'
    while IFS= read -r -d '' path; do
      printf 'path\0%s\0' "$path"
      if [ -L "$repo_top/$path" ]; then
        link_target=$(readlink -- "$repo_top/$path") || return 1
        printf 'symlink\0%s\0' "$link_target"
      elif [ -f "$repo_top/$path" ]; then
        mode=$(stat -c %a "$repo_top/$path") || return 1
        printf 'regular\0%s\0' "$mode"
        sha256sum -- "$repo_top/$path" || return 1
      else
        return 1
      fi
    done < "$untracked"
    printf 'argv\0'
    printf '%s\0' "$@"
    write_command_identity "$1" || return 1
    printf 'environment\0'
    env -0 | LC_ALL=C sort -z || return 1
  } | sha256sum | cut -d ' ' -f 1) || return 1

  # 検査したsourceと公開するsourceがずれるため検査後の採取は不可
  stage_receipt "$@"
  git -C "$repo_top" ls-files --stage -z >"$tracked_after" || return 1
  cmp -- "$tracked" "$tracked_after" || return 1
  : >"$tracked_guard_after"
  write_tracked_metadata "$repo_top" "$tracked_after" "$tracked_guard_after" "" \
    >"$tracked_metadata_after" || return 1
  cmp -- "$tracked_metadata" "$tracked_metadata_after" || return 1
  cmp -- "$tracked_guard" "$tracked_guard_after" || return 1
  [ "$(git -C "$repo_top" rev-parse --verify HEAD)" = "$head" ] || return 1
  git -C "$repo_top" ls-files --others --exclude-standard -z >"$untracked_after" || return 1
  cmp -- "$untracked" "$untracked_after" || return 1
  write_untracked_guard "$untracked" >"$untracked_guard_after" || return 1
  cmp -- "$untracked_guard" "$untracked_guard_after" || return 1
  printf '%s\n' "$semantic"
  if [ -n "$receipt_token" ]; then
    cat "$tracked_guard" "$untracked_guard" | sha256sum | cut -d ' ' -f 1
  fi
}

stage_receipt() {
  [ -z "$receipt_token" ] \
    || "@gate@" record --repo "$PWD" --command "$*" --pending "$receipt_token" \
    || true
}

discard_receipt() {
  [ -z "$receipt_token" ] || "@gate@" discard --pending "$receipt_token" || true
}

if ! before_state=$(fingerprint "$@"); then
  discard_receipt
  trap - EXIT
  rm -rf --one-file-system -- "$scratch"
  exec "$@"
fi
before=${before_state%%$'\n'*}

success_file="$project_state/$before.success"
expected_record=$(printf 'version=6\nfingerprint=%s\n' "$before")
success_file_is_safe=false
if prepare_success_file "$success_file"; then
  success_file_is_safe=true
fi

if [ "$success_file_is_safe" = true ] \
  && [ ! -L "$success_file" ] \
  && [ -f "$success_file" ] \
  && [ "$(stat -c %u "$success_file")" = "$(id -u)" ] \
  && [ "$(cat "$success_file")" = "$expected_record" ]; then
  exit 0
fi

set +e
"$@"
status=$?
set -e

if [ "$status" -eq 0 ] \
  && [ "$success_file_is_safe" = true ] \
  && after_state=$(fingerprint "$@") \
  && [ "$before_state" = "$after_state" ] \
  && prepare_success_file "$success_file"; then
  record_tmp=$(mktemp "$scratch/.success.XXXXXXXX")
  printf '%s' "$expected_record" > "$record_tmp"
  chmod 600 "$record_tmp"
  if ! mv -T "$record_tmp" "$success_file"; then
    rm -f -- "$record_tmp"
    discard_receipt
  fi
else
  discard_receipt
fi

exit "$status"
