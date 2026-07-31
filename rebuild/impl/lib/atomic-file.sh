dotfiles_atomic_publish_no_replace() {
  local temporary=$1 target=$2 parent=$3

  [[ $temporary == "$parent/"* && $target == "$parent/"* &&
    $temporary != "$target" && -f $temporary && ! -L $temporary ]] || return 1
  sync --data "$temporary" || return 1
  if mv -T --no-copy --update=none-fail -- "$temporary" "$target" 2>/dev/null; then
    sync --data "$target" || return 1
    sync "$parent" || return 1
    return 0
  fi
  [[ -e $target || -L $target ]] && return 2
  return 1
}

# shellcheck disable=SC2329 # Shared embedded API; read-only consumers need only no-replace.
dotfiles_atomic_publish_replace() {
  local temporary=$1 target=$2 parent=$3

  [[ $temporary == "$parent/"* && $target == "$parent/"* &&
    $temporary != "$target" && -f $temporary && ! -L $temporary ]] || return 1
  sync --data "$temporary" || return 1
  mv -T -- "$temporary" "$target" || return 1
  sync --data "$target" || return 1
  sync "$parent" || return 1
}
