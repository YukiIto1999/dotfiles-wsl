{
  mkNpmMcp,
  chromium,
  serverBuilder,
  runtimeDirectoryPath,
}:

let
  pkg = mkNpmMcp {
    pname = "chrome-devtools-mcp";
    version = "1.10.1";
    hash = "sha256-ASy89ugy1PZwna0MIde+8XCJ6Ure6c8zF50V6gqa3ys=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-f2NTg/ijemxWlSpVranPCYQo11N4hcj1uW0KAt1ZCOw=";
  };
in
serverBuilder {
  name = "chrome-devtools-mcp";
  env.TMPDIR = runtimeDirectoryPath;
  command = "${pkg}/bin/chrome-devtools-mcp --headless --isolated --executablePath ${chromium}/bin/chromium --filesystemRoot ${runtimeDirectoryPath}";
}
