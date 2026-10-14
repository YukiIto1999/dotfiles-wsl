: "${FIXTURE_NIX_LOG:?}" "${FIXTURE_GCROOTS:?}" "${FIXTURE_HOOK_DIR:?}"

printf 'nix-env %s\n' "$*" >>"$FIXTURE_NIX_LOG"

profile=
action=
declare -a operands=()
while (($# > 0)); do
  case $1 in
    --profile)
      profile=$2
      shift 2
      ;;
    --quiet)
      shift
      ;;
    --set | --delete-generations | --switch-generation)
      action=$1
      shift
      ;;
    *)
      operands+=("$1")
      shift
      ;;
  esac
done
[[ -n $profile && -n $action ]] || { echo "bad fake nix-env invocation" >&2; exit 2; }

directory=$(dirname -- "$profile")
name=$(basename -- "$profile")
case $action in
  --set) kind="set" ;;
  --delete-generations) kind="delete" ;;
  *) kind="switch" ;;
esac
if [[ ${FIXTURE_NIX_ENV_FAIL:-} == "$kind" ]]; then
  echo "error: fixture nix-env failure" >&2
  exit 1
fi

once=$FIXTURE_HOOK_DIR/nix-env-$kind
if [[ -f $once ]]; then
  mv -- "$once" "$once.done"
  # shellcheck disable=SC1090
  source "$once.done"
fi

highest_generation() {
  local highest=0 link number
  for link in "$directory/$name"-*-link; do
    [[ -L $link ]] || continue
    number=${link##*"$name"-}
    number=${number%-link}
    if ((number > highest)); then
      highest=$number
    fi
  done
  printf '%s' "$highest"
}

# rename による置換で、native profile の切替と同じく既存の symlink を原子的に差し替える
switch_link() {
  ln -s -- "$1" "$directory/.$name.tmp.$$"
  mv -T -- "$directory/.$name.tmp.$$" "$profile"
}

register_root() {
  ln -sfn "$1" "$FIXTURE_GCROOTS/gen-$(printf '%s' "$1" | sha256sum | cut -c1-16)"
}

case $action in
  --set)
    target=${operands[0]}
    [[ -d $target ]] || { echo "error: path is not valid: $target" >&2; exit 1; }
    last=$(highest_generation)
    if ((last > 0)) && [[ $(readlink -- "$directory/$name-$last-link") == "$target" ]]; then
      generation=$last
    else
      generation=$((last + 1))
      ln -s -- "$target" "$directory/$name-$generation-link"
      register_root "$directory/$name-$generation-link"
    fi
    switch_link "$name-$generation-link"
    ;;
  --delete-generations)
    current=$(readlink -- "$profile")
    for number in "${operands[@]}"; do
      if [[ $current == "$name-$number-link" ]]; then
        echo "error: cannot delete current generation of profile '$profile'" >&2
        exit 1
      fi
      rm -f -- "$directory/$name-$number-link"
    done
    ;;
  --switch-generation)
    number=${operands[0]}
    [[ -L $directory/$name-$number-link ]] || { echo "error: no such generation $number" >&2; exit 1; }
    switch_link "$name-$number-link"
    ;;
esac
