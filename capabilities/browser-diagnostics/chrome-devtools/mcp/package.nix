{
  mkNpmMcp,
  chromium,
  serverBuilder,
}:

let
  pkg = mkNpmMcp {
    pname = "chrome-devtools-mcp";
    version = "1.6.0";
    hash = "sha256-HmMsLZcUtPgrTPq077nOV1CFx1/+XpdyODEprwEsnIQ=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-el2Ljp5g9L+3lewaMrfsvX1Oo/b05gUgzkdqtce37Eg=";
  };
in
serverBuilder {
  name = "chrome-devtools-mcp";
  command = "${pkg}/bin/chrome-devtools-mcp --headless --isolated --executablePath ${chromium}/bin/chromium";
}
