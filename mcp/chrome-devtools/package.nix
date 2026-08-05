{
  mkMcpServer,
  mkNpmMcp,
  chromium,
}:

# Playwright は操作、DevTools は観測と原因究明を担う。browser は host の
# chromium を使い、CDP を host へ露出しない
let
  pkg = mkNpmMcp {
    pname = "chrome-devtools-mcp";
    version = "1.6.0";
    hash = "sha256-HmMsLZcUtPgrTPq077nOV1CFx1/+XpdyODEprwEsnIQ=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-el2Ljp5g9L+3lewaMrfsvX1Oo/b05gUgzkdqtce37Eg=";
  };
in
mkMcpServer {
  name = "chrome-devtools-mcp";
  command = "${pkg}/bin/chrome-devtools-mcp --headless --isolated --executablePath ${chromium}/bin/chromium";
}
