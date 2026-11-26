#!/usr/bin/env bash
# dotfiles-rebuild: build and activate this host from the dotfiles checkout.
# The default source is the committed HEAD, so uncommitted edits made by other sessions in the
# shared checkout are never deployed by accident. --worktree deploys the working tree instead.
set -euo pipefail

repo=@dotfilesDir@
host=@hostName@

usage() {
  cat <<'EOF'
usage: dotfiles-rebuild [switch|boot|test|build|dry-activate] [--worktree]
       dotfiles-rebuild rollback

  switch        build HEAD and activate it now (default)
  boot          build HEAD and activate it at the next WSL start
  test          activate without adding a boot entry
  build         build only; print the closure difference to the running system
  dry-activate  show what activation would change
  rollback      switch back to the previous system generation
  --worktree    use the working tree, including uncommitted changes, instead of HEAD

Update inputs explicitly with `nix flake update [INPUT]` and commit flake.lock first.
EOF
}

action=switch
worktree=false
for argument in "$@"; do
  case "$argument" in
    switch | boot | test | build | dry-activate | rollback) action=$argument ;;
    --worktree) worktree=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

# One writer at a time; a second rebuild waits instead of interleaving activations.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/dotfiles-rebuild.lock"
flock 9

previous=$(readlink -f /run/current-system)

if [ "$action" = rollback ]; then
  @nixosRebuild@ switch --rollback --sudo
else
  if [ "$worktree" = true ]; then
    ref="git+file://$repo"
  else
    rev=$(git -C "$repo" rev-parse HEAD)
    ref="git+file://$repo?rev=$rev"
    if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
      echo "dotfiles-rebuild: building HEAD $rev; uncommitted changes in $repo are not included (use --worktree to include them)" >&2
    fi
  fi

  if [ "$action" = build ]; then
    out=$(nix build --no-link --print-out-paths "$ref#nixosConfigurations.$host.config.system.build.toplevel")
    nix store diff-closures "$previous" "$out" || true
    echo "$out"
    exit 0
  fi

  if [ "$action" = dry-activate ]; then
    @nixosRebuild@ dry-activate --sudo --flake "$ref#$host"
    exit 0
  fi

  @nixosRebuild@ "$action" --sudo --flake "$ref#$host"
fi

current=$(readlink -f /run/current-system)
if [ "$current" != "$previous" ]; then
  nix store diff-closures "$previous" "$current" || true
fi

# WSL reads /etc/wsl.conf only when the distribution starts.
if ! cmp -s /run/booted-system/etc/wsl.conf /run/current-system/etc/wsl.conf 2>/dev/null; then
  echo "dotfiles-rebuild: /etc/wsl.conf differs from the booted generation; run 'wsl.exe --shutdown' from Windows when no session needs the WSL VM" >&2
fi
