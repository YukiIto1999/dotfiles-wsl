{
  pkgs,
  commandBuilder,
  apiUrl,
}:

let
  python = pkgs.python3.withPackages (ps: [
    ps.mcp
    ps.httpx
    ps.jsonschema
  ]);
in
commandBuilder {
  name = "dotfiles-memory";
  src = ./package/entry.sh;
  runtimeInputs = [ pkgs.git ];
  vars = {
    inherit apiUrl;
    python = "${python}/bin/python";
    source = "${./package}";
  };
  extra = {
    meta.mainProgram = "dotfiles-memory";
    passthru = { inherit python; };
  };
}
