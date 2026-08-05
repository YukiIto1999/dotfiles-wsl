{
  helpers,
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  inherit (helpers.execTokens) tokensOf;
  front = hostConfig.my.contract.mcp.fronts.chrome-devtools;
  service = hostConfig.systemd.services.${front.service}.serviceConfig;

  # 起動 flag は wrapper の中にある。ExecStart には mcp-proxy と wrapper しか出ない
  wrapper = builtins.head (
    builtins.filter (token: lib.hasSuffix "chrome-devtools-mcp" token) (tokensOf service.ExecStart)
  );
in
{
  chrome-devtools-front =
    assert hostConfig.my.mcp.targets.chrome-devtools.needsNetwork;
    pkgs.runCommandLocal "check-chrome-devtools-front" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      # host の chromium を使う。指定しないと npm 側が store 外から取る
      grep -Fq -- '--executablePath ${hostConfig.my.contract.mcp.chromium}/bin/chromium' ${wrapper}

      # WSL に表示先は無い。profile も残さない
      grep -Fq -- '--headless' ${wrapper}
      grep -Fq -- '--isolated' ${wrapper}

      # browserUrl と browserWSEndpoint は CDP を持つ既存 browser へ繋ぐ。
      # host へ CDP を露出する経路を作らない
      ! grep -qE -- '--browser(Url|WSEndpoint|-url)' ${wrapper}
      touch $out
    '';
}
