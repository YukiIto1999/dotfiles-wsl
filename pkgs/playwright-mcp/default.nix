{ pkgs, mkMcpServer }:

# host chromium を headless 起動する純 stdio server
# bot 判定を避ける Windows UA。chromium launch args で付与、browser.userAgent は無視される
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
mkMcpServer {
  name = "playwright-mcp";
  command = "${pkgs.playwright-mcp}/bin/playwright-mcp --browser chromium --executable-path ${pkgs.chromium}/bin/chromium --headless --isolated --no-sandbox --config ${config}";
}
