set -euo pipefail

created_links=()

rollback() {
  local link
  for link in "${created_links[@]}"; do
    rm -f -- "$link"
  done
  created_links=()
}

die() {
  rollback
  printf 'dotfiles-agent-protect: %s\n' "$1" >&2
  exit 70
}

usage() {
  printf '%s\n' 'usage: dotfiles-agent-protect [--resolved] ROOTS-DIRECTORY PATH...' >&2
  exit 2
}

print_resolved=false
if [ "${1-}" = --resolved ]; then
  print_resolved=true
  shift
fi
[ "$#" -ge 2 ] || usage
roots_dir=$1
shift
case "$roots_dir" in
  /*) ;;
  *) die "roots directory is not absolute: $roots_dir" ;;
esac

uid=$(id -u)
if ! mkdir -m 700 "$roots_dir" 2>/dev/null; then
  test ! -L "$roots_dir" || die "roots directory is a symlink: $roots_dir"
  test -d "$roots_dir" || die "roots directory is not a directory: $roots_dir"
  test "$(stat -c %u "$roots_dir")" = "$uid" || die "roots directory has another owner: $roots_dir"
fi
chmod 700 "$roots_dir" || die "cannot secure roots directory: $roots_dir"

store_pattern='^[0-9a-z]{32}-[A-Za-z0-9+._?=-]+$'
printed=()

for path in "$@"; do
  [ -r "$path" ] || die "cannot read: $path"
  # 開いた file descriptor が、profile の symlink を辿った先の store object を、root を取る間も保持する。
  # path の読取りと root の取得の間に profile が動いても、保護する対象はこの open が確定させたものだけである。
  exec {held}<"$path" || die "cannot open: $path"
  resolved=$(readlink "/proc/$$/fd/$held") || die "cannot resolve: $path"
  case "$resolved" in
    *' (deleted)') die "the object was already deleted: $path" ;;
    /nix/store/*) ;;
    *) die "not in the Nix store: $path -> $resolved" ;;
  esac
  rest=${resolved#/nix/store/}
  name=${rest%%/*}
  [[ $name =~ $store_pattern ]] || die "not a store object name: $name"
  object=/nix/store/$name
  link=$roots_dir/$name

  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$object" ] || die "root already names another object: $link"
  else
    # 失効した object を substituter から取り直さず、保護できないものは起動させない。
    @nixStoreCommand@ --realise --add-root "$link" --indirect --option substitute false "$object" >/dev/null \
      || die "cannot protect $object"
    created_links+=("$link")
  fi
  [ -L "$link" ] && [ "$(readlink "$link")" = "$object" ] || die "the root of $object was not created: $link"
  exec {held}<&-

  if [ "$print_resolved" = true ]; then
    printed+=("$resolved")
  else
    printed+=("$object")
  fi
done

printf '%s\n' "${printed[@]}"
