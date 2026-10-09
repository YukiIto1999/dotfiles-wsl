{ pkgs }:

pkgs.writeShellApplication {
  name = "dotfiles-run-within";
  runtimeInputs = [ pkgs.coreutils ];
  text = builtins.readFile ./impl/run-within.sh;
}
