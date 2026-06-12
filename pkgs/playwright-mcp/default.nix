{ pkgs, mkMcpServer, cdpEndpoint, userAgent }:

# playwright — stdio server driving the chromium daemon over CDP.
let
  config = pkgs.writeText "playwright-mcp-config.json" (builtins.toJSON {
    browser.userAgent = userAgent;
  });
in
mkMcpServer {
  name    = "playwright-mcp";
  command = "${pkgs.playwright-mcp}/bin/playwright-mcp --cdp-endpoint ${cdpEndpoint} --config ${config}";
}
