# pull = "never" なので、宣言した digest の image が事前に無いと container が
# 起動しない。docker 自身が image の有無を答えるので、同期の状態は記録しない
usage() {
  cat <<'USAGE'
usage:
  dotfiles-sync-images [--status]

Pull the upstream images this configuration declares, by digest. With --status,
report which are missing and exit 1 when any is.
USAGE
}

status_only=0
case "${1-}" in
  --status) status_only=1 ;;
  --help | -h) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

images=@upstreamImages@
missing=0

for image in $images; do
  if @dockerCommand@ image inspect "$image" > /dev/null 2>&1; then
    printf 'OK: %s\n' "$image"
    continue
  fi
  missing=1
  if ((status_only)); then
    printf 'MISSING: %s\n' "$image"
    continue
  fi
  printf 'pulling %s\n' "$image"
  @dockerCommand@ pull --quiet "$image" > /dev/null || {
    printf 'FATAL: could not pull %s\n' "$image" >&2
    exit 1
  }
done

((status_only)) && exit "$missing"
exit 0
