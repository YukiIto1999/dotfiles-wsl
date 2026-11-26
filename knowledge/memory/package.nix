{
  lib,
  python3,
  git,
  writeShellApplication,
  apiUrl,
}:

let
  python = python3.withPackages (ps: [
    ps.mcp
    ps.httpx
    ps.jsonschema
  ]);
in
writeShellApplication {
  name = "dotfiles-memory";
  runtimeInputs = [ git ];
  text = ''
    export PROJECT_MEMORY_URL=${lib.escapeShellArg apiUrl}
    exec ${python}/bin/python ${./package}/main.py "$@"
  '';
  passthru = { inherit python; };
}
