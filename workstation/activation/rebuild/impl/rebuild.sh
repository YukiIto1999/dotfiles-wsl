usage() {
  cat <<'USAGE'
usage:
  dotfiles-rebuild [--rollback] [--plan]

Build the committed flake and switch to it, or select the previous system generation
with --rollback. Both actions check the working tree and the WSL restart requirement.
A build first updates the architectureStandard input to its latest revision and commits
flake.lock; with --plan the update is applied to the plan only and then discarded.
With --plan, print what would change and exit without switching.
A failed activation can leave the profile and running services in different states;
inspect the system before retrying or rolling back.
USAGE
}

die() {
  printf 'FATAL: %s\n' "$2" >&2
  exit "$1"
}

standard_subject='fix: 標準の実行 package の最新版への更新'

# オフラインでも修復の rebuild を通す必要のため更新失敗での停止は不採用
follow_standard() {
  local update_log
  update_log=$(mktemp) || die 2 "could not create a temporary file"
  if ! nix flake update architectureStandard > "$update_log" 2>&1; then
    printf 'WARN: could not update the standard input; the executed package stays at the locked revision\n' >&2
    cat "$update_log" >&2
    rm -f -- "$update_log"
    return 0
  fi
  rm -f -- "$update_log"
  [[ -n $(git status --porcelain --untracked-files=no) ]] || return 0
  if ((plan_only)); then
    trap 'git restore --source=HEAD --staged --worktree -- flake.lock' EXIT
    return 0
  fi
  if ! { git add -- flake.lock && git commit -q -m "$standard_subject" -- flake.lock; }; then
    git restore --source=HEAD --staged --worktree -- flake.lock
    die 2 "could not record the standard update"
  fi
}

plan_only=0
rollback=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      ((plan_only == 0)) || { usage >&2; exit 2; }
      plan_only=1
      ;;
    --rollback)
      ((rollback == 0)) || { usage >&2; exit 2; }
      rollback=1
      ;;
    --help | -h)
      [[ $# -eq 1 && $plan_only -eq 0 && $rollback -eq 0 ]] || { usage >&2; exit 2; }
      usage
      exit 0
      ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

dotfiles=@configuredDotfiles@
system_profile="@systemProfilePath@"
distro_name=@distroName@
cd "$dotfiles" || die 2 "cannot enter $dotfiles"

working_tree=$(git status --porcelain --untracked-files=no) ||
  die 2 "could not inspect the working tree"
[[ -z $working_tree ]] || die 2 "commit the working tree before rebuilding"

((rollback)) || follow_standard

if ((rollback)); then
  generations=$(@sudoCommand@ nix-env --list-generations --profile "$system_profile") ||
    die 2 "could not list system generations"
  previous_generation=
  current_found=0
  while read -r generation metadata; do
    [[ $generation =~ ^[0-9]+$ ]] || continue
    if [[ $metadata == *"(current)"* ]]; then
      current_found=1
      break
    fi
    previous_generation=$generation
  done <<< "$generations"
  [[ $current_found -eq 1 && -n $previous_generation ]] ||
    die 2 "no previous system generation is available"
  candidate=$(readlink -e "$system_profile-$previous_generation-link") ||
    die 2 "could not resolve the previous system generation"
  rebuild_args=(switch --rollback)
else
  candidate=$(nix build --no-link --print-out-paths \
    "$dotfiles#nixosConfigurations.@hostName@.config.system.build.toplevel") ||
    die 2 "candidate build failed"
  rebuild_args=(switch --flake "$dotfiles#@hostName@")
fi

restart_plan=$(@wslRestartRequired@ --plan "$candidate") ||
  die 2 "could not classify the restart requirement"

if ((plan_only)); then
  @nvd@ diff /run/current-system "$candidate" || true
  printf 'plan: %s\n' "$restart_plan"
  exit 0
fi

if ! @sudoCommand@ @nixosRebuild@ "${rebuild_args[@]}"; then
  printf 'Inspect the system profile, running system and failed services before retrying:\n' >&2
  printf '  readlink -f %s\n' "$system_profile" >&2
  printf '  readlink -f /run/current-system\n' >&2
  printf '  systemctl --failed\n' >&2
  printf '  journalctl -b -p err\n' >&2
  die 2 "nixos-rebuild ${rebuild_args[*]} failed; activation may be partially applied"
fi

case $restart_plan in
  switch) ;;
  *)
    printf 'WSL restart required. From Windows:\n' >&2
    printf "  wsl.exe --terminate '%s'\n" "${distro_name//\'/\'\'}" >&2
    ;;
esac
