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

if [ "$subcommand_index" -ge "$argument_count" ] \
  || [ "${arguments[$subcommand_index]}" != worktree ] \
  || [ "$((subcommand_index + 1))" -ge "$argument_count" ] \
  || [ "${arguments[$((subcommand_index + 1))]}" != add ]; then
  exec @gitCommand@ "$@"
fi

global_arguments=("${arguments[@]:0:subcommand_index}")
worktree_arguments=("${arguments[@]:subcommand_index+1}")
exec @gitCommand@ "${global_arguments[@]}" \
  -c alias.dotfiles-agent-managed-worktree=@worktreeAlias@ \
  dotfiles-agent-managed-worktree "${worktree_arguments[@]}"
