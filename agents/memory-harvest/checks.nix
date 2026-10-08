{
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  runtime = hostConfig.dotfiles.capabilities.project-memory.runtime.override {
    apiUrl = "http://127.0.0.1:18082";
  };
in
{
  agent-memory-harvest-behavior =
    pkgs.runCommandLocal "check-agent-memory-harvest-behavior"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        ${pkgs.python3}/bin/python ${./checks/harvest_test.py} ${./package} ${../journal/package} ${lib.getExe runtime}
        touch "$out"
      '';
}
