{ pkgs, ... }:

{
  agent-journal-behavior =
    pkgs.runCommandLocal "check-agent-journal-behavior"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
        python3 ${./checks/journal_test.py} ${./package}
        touch "$out"
      '';
}
