{
  pkgs,
  hostConfig,
  ...
}:

let
  front = hostConfig.dotfiles.mcp.fronts.playwright;
  target = hostConfig.dotfiles.mcp.targets.playwright;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;
in
{
  playwright-front =
    assert front.url == "http://127.0.0.1:${toString front.port}/mcp";
    assert service.RuntimeDirectory == front.runtimeDirectory;
    pkgs.runCommandLocal "check-playwright-front" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      grep -Fq -- 'RUNTIME_DIRECTORY' ${target.executable}
      grep -Fq -- 'mktemp -d -- "$RUNTIME_DIRECTORY/playwright.' ${target.executable}
      grep -Fq -- '--output-dir "$session_dir"' ${target.executable}
      touch $out
    '';
}
