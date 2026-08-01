{
  pkgs,
  playwrightMcp ? pkgs.playwright-mcp,
  chromium ? pkgs.chromium,
}:

# host chromium を headless 起動する front
# bot 判定を避ける Windows UA、chromium launch args で付与、browser.userAgent は無視される
let
  userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";
  config = pkgs.writeText "playwright-mcp-config.json" (
    builtins.toJSON {
      browser.launchOptions.args = [
        "--user-agent=${userAgent}"
        "--disable-dev-shm-usage"
      ];
    }
  );
in
# 常駐するので session ごとの出力先は playwright-mcp 自身が output-dir の下に作る
pkgs.writeShellScriptBin "playwright-mcp-front" ''
  exec ${playwrightMcp}/bin/playwright-mcp \
    --browser chromium \
    --executable-path ${chromium}/bin/chromium \
    --headless \
    --isolated \
    --no-sandbox \
    --config ${config} \
    "$@"
''
