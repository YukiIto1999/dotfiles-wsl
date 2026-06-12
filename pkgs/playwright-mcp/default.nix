{ pkgs, mkMcpServer, userAgent }:

# host chromium を headless 起動する純 stdio server
# Windows UA は chromium launch args で付与、browser.userAgent は無視される
let
  config = pkgs.writeText "playwright-mcp-config.json" (builtins.toJSON {
    browser.launchOptions.args = [ "--user-agent=${userAgent}" "--disable-dev-shm-usage" ];
  });
in
mkMcpServer {
  name    = "playwright-mcp";
  command = "${pkgs.playwright-mcp}/bin/playwright-mcp --browser chromium --executable-path ${pkgs.chromium}/bin/chromium --headless --isolated --no-sandbox --config ${config}";
}
