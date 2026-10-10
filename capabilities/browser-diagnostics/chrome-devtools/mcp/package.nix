{
  mkNpmMcp,
  src,
  chromium,
  serverBuilder,
  runtimeDirectoryPath,
}:

let
  pkg = mkNpmMcp {
    pname = "chrome-devtools-mcp";
    inherit src;
    inherit ((builtins.fromJSON (builtins.readFile "${src}/package.json"))) version;
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-f2NTg/ijemxWlSpVranPCYQo11N4hcj1uW0KAt1ZCOw=";
  };
in
serverBuilder {
  name = "chrome-devtools-mcp";
  env.TMPDIR = runtimeDirectoryPath;
  command = "${pkg}/bin/chrome-devtools-mcp --headless --isolated --executablePath ${chromium}/bin/chromium --filesystemRoot ${runtimeDirectoryPath}";
}
