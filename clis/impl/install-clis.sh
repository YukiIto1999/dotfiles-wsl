if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  cat <<'USAGE'
usage: dotfiles-install-clis

Installs the AI CLI binaries declared in my.clis (upstream installer script
or GitHub release archive, depending on each CLI's install.kind) into
~/.local/bin. Run as the target user, not root.
USAGE
  exit 0
fi

fail() { echo "FATAL: $*" >&2; exit 1; }
log()  { printf '== %s\n' "$*"; }

[[ ${EUID} -ne 0 ]] || fail "run as the target user, not root"

# 初回マシンでは ~/.local/bin がまだ PATH に無い
export PATH="$HOME/.local/bin:$PATH"

install -d -m 0755 "$HOME/.local/bin"

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found in PATH"
}

require curl
require jq
require tar
require gzip
require install
require uname

arch_key() {
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "x86_64" ;;
    aarch64|arm64) printf '%s\n' "aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

install_installer_script() {
  local name=$1 url=$2

  log "$name"
  curl -fsSL "$url" | bash

  command -v "$name" >/dev/null 2>&1 || fail "$name not found after upstream installer; ensure ~/.local/bin is in PATH"
  "$name" --version || fail "$name installed but version check failed"
}

install_github_release() {
  local name=$1 binary=$2 repo=$3 asset_x86_64=$4 asset_aarch64=$5 archive_path=$6
  local asset arch api url tmp member

  arch="$(arch_key)"
  case "$arch" in
    x86_64)  asset=$asset_x86_64 ;;
    aarch64) asset=$asset_aarch64 ;;
  esac

  log "$name"
  api="https://api.github.com/repos/${repo}/releases/latest"
  url="$(curl -fsSL "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' | head -n1)"
  [[ -n $url && $url != "null" ]] || fail "release asset not found: ${asset}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  curl -fL "$url" -o "$tmp/$asset"

  if [[ -n $archive_path ]]; then
    member=$archive_path
  else
    member="$(tar -tzf "$tmp/$asset" | head -n1)"
  fi
  [[ -n $member ]] || fail "empty archive: ${asset}"

  tar -xzf "$tmp/$asset" -C "$tmp"
  [[ -f "$tmp/$member" ]] || fail "binary not found in archive: ${member}"

  install -m 0755 "$tmp/$member" "$HOME/.local/bin/$binary"
  "$HOME/.local/bin/$binary" --version || fail "$binary installed but version check failed"
}

# roster から導出する install 手順
while IFS='|' read -r name kind binary arg1 arg2 arg3 arg4; do
  [[ -n $name ]] || continue

  case "$kind" in
    installer-script) install_installer_script "$binary" "$arg1" ;;
    github-release)   install_github_release "$name" "$binary" "$arg1" "$arg2" "$arg3" "$arg4" ;;
    *) fail "unknown install kind for $name: $kind" ;;
  esac
done <<< "
@installTable@
"
