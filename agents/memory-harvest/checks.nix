{ pkgs, ... }:

{
  agent-memory-harvest-behavior =
    pkgs.runCommandLocal "check-agent-memory-harvest-behavior"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        python3 ${./checks/harvest_test.py} ${./package} ${../journal/package}
        touch "$out"
      '';
}
