{ pkgs, ... }:

let
  python = pkgs.python3.withPackages (ps: [
    ps.mcp
    ps.httpx
    ps.jsonschema
  ]);
in
{
  project-memory-runtime-behavior =
    pkgs.runCommandLocal "check-project-memory-runtime-behavior" { nativeBuildInputs = [ pkgs.git ]; }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        ${python}/bin/python ${./checks/runtime.py} ${./package}
        touch "$out"
      '';
}
