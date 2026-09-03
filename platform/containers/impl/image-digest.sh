usage() {
  cat <<'USAGE'
usage: dotfiles-image-digest <IMAGE>

宣言へ固定する linux/amd64 の digest を registry から取る。

example:
  dotfiles-image-digest registry.example.invalid/backend:latest
USAGE
}

case ${1-} in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

digest=$(docker manifest inspect "$1" | jq -r '
  if .Descriptor.digest then
    .Descriptor.digest
  elif .manifests then
    .manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux") | .digest
  else
    empty
  end
')

if [[ -z $digest ]]; then
  echo "FATAL: no linux/amd64 digest in the manifest of $1" >&2
  exit 1
fi

printf '%s\n' "$digest"
