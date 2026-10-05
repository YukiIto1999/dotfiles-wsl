set -euo pipefail

arguments=("$@")
argument_count=${#arguments[@]}
subcommand_index=0

while [ "$subcommand_index" -lt "$argument_count" ]; do
  argument=${arguments[$subcommand_index]}
  case "$argument" in
    -C | -c | --config-env | --git-dir | --work-tree | --namespace | --super-prefix)
      test "$((subcommand_index + 1))" -lt "$argument_count" || exec @gitCommand@ "$@"
      subcommand_index=$((subcommand_index + 2))
      ;;
    -C?* | -c?* | --config-env=* | --git-dir=* | --work-tree=* | --namespace=* | --super-prefix=* | --exec-path=* | --attr-source=*)
      subcommand_index=$((subcommand_index + 1))
      ;;
    --bare | --no-replace-objects | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs | --no-optional-locks | --no-advice | --no-lazy-fetch | --paginate | --no-pager | -p | -P)
      subcommand_index=$((subcommand_index + 1))
      ;;
    --exec-path | --html-path | --man-path | --info-path | --version | -v | --help | -h | --)
      exec @gitCommand@ "$@"
      ;;
    -* | '')
      exec @gitCommand@ "$@"
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "${DOTFILES_AGENT_WORKTREE_RECORD-}" ] \
  || [ "$subcommand_index" -ge "$argument_count" ] \
  || [ "${arguments[$subcommand_index]}" != worktree ] \
  || [ "$((subcommand_index + 1))" -ge "$argument_count" ] \
  || [ "${arguments[$((subcommand_index + 1))]}" != add ]; then
  exec @gitCommand@ "$@"
fi

global_arguments=("${arguments[@]:0:subcommand_index}")
shopt -s lastpipe

worktree_heads() {
  local field path=''
  local -a fields=()

  @gitCommand@ "${global_arguments[@]}" worktree list --porcelain -z 2>/dev/null \
    | mapfile -d '' -t fields || return 1
  for field in "${fields[@]}"; do
    case $field in
      'worktree '*) path=${field#worktree } ;;
      'HEAD '*) printf '%s\0%s\0' "$path" "${field#HEAD }" ;;
    esac
  done
}

before=()
worktree_heads | mapfile -d '' -t before || exec @gitCommand@ "$@"
declare -A existing=()
for ((index = 0; index < ${#before[@]}; index += 2)); do
  existing[${before[index]}]=1
done

set +e
@gitCommand@ "$@"
status=$?
set -e

# launcher が終了時に回収できるよう、この add で増えた worktree の path と作成時の HEAD を記録する。
# 並行した add で二つ以上増えたときは、どれがこの add のものか決められないので記録しない。
after=()
if [ "$status" -eq 0 ] && worktree_heads | mapfile -d '' -t after; then
  added=()
  for ((index = 0; index < ${#after[@]}; index += 2)); do
    [ -n "${existing[${after[index]}]+set}" ] || added+=("${after[index]}" "${after[index + 1]}")
  done
  if [ "${#added[@]}" -eq 2 ]; then
    printf '%s\0%s\0' "${added[0]}" "${added[1]}" >>"$DOTFILES_AGENT_WORKTREE_RECORD" 2>/dev/null || true
  fi
fi
exit "$status"
