# pull = "never" なので、宣言した digest の image が事前に無いと container が
# 起動しない。docker 自身が image の有無を答えるので、同期の状態は記録しない
#
# digest だけを指定して pull した image は tag を持たず、docker image prune は
# それを dangling として消す。rebuild が container を止めている間に GC timer が
# 重なると宣言済みの image が消えるため、専用 namespace の tag で prune から外す。
# 上流の tag をそのまま付けると、同じ tag を使う別 project の image を奪う
pin_namespace=dotfiles-pinned

usage() {
  cat <<'USAGE'
usage:
  dotfiles-sync-images [--status]

Pull the upstream images this configuration declares, by digest, and pin them
against dangling image pruning. With --status, report which are missing or
unpinned and exit 1 when any is.
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
drift=0

image_id() {
  @dockerCommand@ image inspect --format '{{.Id}}' "$1" 2> /dev/null || true
}

for image in $images; do
  pin="$pin_namespace/${image%@*}"
  id=$(image_id "$image")

  if [ -n "$id" ] && [ "$(image_id "$pin")" = "$id" ]; then
    printf 'OK: %s\n' "$image"
    continue
  fi

  if ((status_only)); then
    drift=1
    if [ -z "$id" ]; then
      printf 'MISSING: %s\n' "$image"
    else
      printf 'UNPINNED: %s\n' "$image"
    fi
    continue
  fi

  if [ -z "$id" ]; then
    printf 'pulling %s\n' "$image"
    @dockerCommand@ pull --quiet "$image" > /dev/null || {
      printf 'FATAL: could not pull %s\n' "$image" >&2
      exit 1
    }
  fi

  printf 'pinning %s\n' "$image"
  @dockerCommand@ tag "$image" "$pin" || {
    printf 'FATAL: could not pin %s\n' "$image" >&2
    exit 1
  }
done

((status_only)) && exit "$drift"
exit 0
