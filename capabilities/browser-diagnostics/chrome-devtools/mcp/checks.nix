{
  pkgs,
  hostConfig,
  ...
}:

let
  wrapper = hostConfig.dotfiles.platform.mcp.targets.chrome-devtools.executable;
in
{
  chrome-devtools-front =
    assert hostConfig.dotfiles.platform.mcp.targets.chrome-devtools.needsNetwork;
    pkgs.runCommandLocal "check-chrome-devtools-front" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      # npm による Nix store 外ブラウザ取得の禁止
      grep -Fq -- '--executablePath ${hostConfig.dotfiles.capabilities.browser-runtime.package}/bin/chromium' ${wrapper}

      grep -Fq -- '--headless' ${wrapper}
      grep -Fq -- '--isolated' ${wrapper}

      # host 上での CDP 公開を要する既存ブラウザ接続の禁止
      if grep -qE -- '--browser(Url|WSEndpoint|-url)' ${wrapper}; then
        echo "chrome-devtools front attaches to an existing browser" >&2
        exit 1
      fi
      touch $out
    '';
}
