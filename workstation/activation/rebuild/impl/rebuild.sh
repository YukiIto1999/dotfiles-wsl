# NixOS の generation と profile が transaction を持つ。ここはその上に層を作らず、
# WSL 固有の再起動判定と、flake を汚れたまま適用しないことだけを足す
usage() {
  cat <<'USAGE'
usage:
  dotfiles-rebuild [--plan]

Build the flake and switch to it. NixOS keeps the previous generation, so a failed
activation leaves the running system on the profile it already had; run the command
again after fixing the cause. Use `nixos-rebuild --rollback switch` to step back.
With --plan, print what would change and exit without switching.
USAGE
}

die() {
  printf 'FATAL: %s\n' "$2" >&2
  exit "$1"
}

plan_only=0
case "${1-}" in
  --plan) plan_only=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

dotfiles=@configuredDotfiles@
cd "$dotfiles" || die 2 "cannot enter $dotfiles"

# flake は tracked file しか見ない。未 stage の変更は無視されるので、気づかずに
# 古い内容を配備しないよう先に止める
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  die 2 "commit or stage the working tree before rebuilding"
fi

candidate=$(nix build --no-link --print-out-paths \
  "$dotfiles#nixosConfigurations.@hostName@.config.system.build.toplevel") ||
  die 2 "candidate build failed"

restart_plan=$(@wslRestartRequired@ --plan "$candidate") ||
  die 2 "could not classify the restart requirement"

if ((plan_only)); then
  @nvd@ diff /run/current-system "$candidate" || true
  printf 'plan: %s\n' "$restart_plan"
  exit 0
fi

@sudoCommand@ @nixosRebuild@ switch --flake "$dotfiles#@hostName@" ||
  die 2 "nixos-rebuild switch failed; the previous generation is still active"

case $restart_plan in
  switch) ;;
  *)
    printf 'WSL restart required. From Windows:\n' >&2
    printf '  wsl.exe --terminate %s\n' "@distroName@" >&2
    ;;
esac
