install_manifest=$(cat <<'DOTFILES_INSTALL_MANIFEST'
@installManifest@
DOTFILES_INSTALL_MANIFEST
)

if [[ ${1:-} == "--print-manifest" ]]; then
  printf '%s\n' "$install_manifest"
  exit 0
fi

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  cat <<'USAGE'
usage: dotfiles-install-agents

Installs the agent client binaries declared in dotfiles.agents (upstream installer
script or GitHub release archive, depending on each client's install.kind) into
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

@versionArgsDecoder@

arch_key() {
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "x86_64" ;;
    aarch64|arm64) printf '%s\n' "aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

check_version() {
  local binary=$1 version_args_json=$2

  run_version_check "$binary" "$version_args_json" || fail "$binary installed but version check failed"
}

install_installer_script() {
  local record=$1 binary url version_args_json

  binary=$(jq -r '.binary' <<< "$record")
  url=$(jq -r '.install.scriptUrl' <<< "$record")
  version_args_json=$(jq -c '.versionArgs' <<< "$record")

  log "$binary"
  curl -fsSL "$url" | bash

  command -v "$binary" >/dev/null 2>&1 || fail "$binary not found after upstream installer; ensure ~/.local/bin is in PATH"
  check_version "$binary" "$version_args_json"
}

install_github_release() {
  local record=$1 name binary repo asset_x86_64 asset_aarch64 archive_path version_args_json
  local asset arch api url tmp member

  name=$(jq -r '.name' <<< "$record")
  binary=$(jq -r '.binary' <<< "$record")
  repo=$(jq -r '.install.repo' <<< "$record")
  asset_x86_64=$(jq -r '.install.assetByArch.x86_64' <<< "$record")
  asset_aarch64=$(jq -r '.install.assetByArch.aarch64' <<< "$record")
  archive_path=$(jq -r '.install.binaryInArchive // ""' <<< "$record")
  version_args_json=$(jq -c '.versionArgs' <<< "$record")

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
  check_version "$HOME/.local/bin/$binary" "$version_args_json"
}

# client contract から導出する install 手順
while IFS= read -r record; do
  kind=$(jq -r '.install.kind' <<< "$record")
  name=$(jq -r '.name' <<< "$record")

  case "$kind" in
    installer-script) install_installer_script "$record" ;;
    github-release)   install_github_release "$record" ;;
    *) fail "unknown install kind for $name: $kind" ;;
  esac
done < <(jq -c '.[]' <<< "$install_manifest")
