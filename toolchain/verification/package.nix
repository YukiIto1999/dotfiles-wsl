{ pkgs }:

{
  runWithin = pkgs.writeShellApplication {
    name = "dotfiles-run-within";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./impl/run-within.sh;
  };

  runEach = pkgs.writeShellApplication {
    name = "dotfiles-run-each";
    text = builtins.readFile ./impl/run-each.sh;
  };
}
