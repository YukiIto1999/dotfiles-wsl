{ pkgs }:

{
  atomicPublishTestHook = pkgs.writeShellApplication {
    name = "fixture-atomic-publish-hook";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../../fixtures/install-agents/fake-atomic-publish-hook.sh;
  };
}
