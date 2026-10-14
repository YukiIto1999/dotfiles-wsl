{
  lib,
  mkNpmMcp,
  src,
  chromium,
  serverBuilder,
  runtimeDirectoryPath,
  supervise,
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
  # MCP session の終了で、この session の browser と子だけを終了確認まで回収し、別 session と front 本体を止めない。
  command = "${lib.getExe supervise} --term-grace 10 --kill-grace 5 -- ${pkg}/bin/chrome-devtools-mcp --headless --isolated --no-usage-statistics --no-performance-crux --executablePath ${chromium}/bin/chromium --filesystemRoot ${runtimeDirectoryPath}";
}
