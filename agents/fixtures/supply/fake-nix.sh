: "${FIXTURE_NIX_LOG:?}" "${FIXTURE_REV_FILE:?}" "${FIXTURE_BUILDS:?}" "${FIXTURE_GCROOTS:?}"

printf 'nix %s\n' "$*" >>"$FIXTURE_NIX_LOG"

if [[ ${1:-} == flake && ${2:-} == metadata ]]; then
  if [[ -e $FIXTURE_REV_FILE.fail ]]; then
    echo "error: unable to download the supply source" >&2
    exit 1
  fi
  printf '{"locked":{"rev":"%s"}}\n' "$(cat "$FIXTURE_REV_FILE")"
  exit 0
fi

if [[ ${1:-} == build ]]; then
  shift
  out_link=
  installable=
  while (($# > 0)); do
    case $1 in
      --out-link)
        out_link=$2
        shift 2
        ;;
      --no-write-lock-file)
        shift
        ;;
      *)
        installable=$1
        shift
        ;;
    esac
  done
  [[ $installable =~ /([0-9a-f]{40})#packages\.[^.]+\.(.+)$ ]] \
    || { echo "unexpected installable: $installable" >&2; exit 2; }
  revision=${BASH_REMATCH[1]}
  package=${BASH_REMATCH[2]}
  build=$FIXTURE_BUILDS/$package-$revision
  if [[ -e $build.hang ]]; then
    trap 'echo terminated >"$build.terminated"; exit 143' TERM
    printf '%s\n' "$$" >"$build.started"
    while true; do
      sleep 0.05
    done
  fi
  if [[ -e $build.fail ]]; then
    echo "error: build of $package failed" >&2
    exit 1
  fi
  store_path=$(cat "$build")
  ln -sfn "$store_path" "$out_link"
  ln -sfn "$out_link" "$FIXTURE_GCROOTS/out-link-$(printf '%s' "$out_link" | sha256sum | cut -c1-16)"
  exit 0
fi

echo "unsupported fake nix invocation: $*" >&2
exit 2
