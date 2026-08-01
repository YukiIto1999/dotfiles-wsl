{
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit mkMcpServer mkNpmMcp; };
in
{
  my.mcp.targets.probe.transport.stdio.command = lib.getExe front;
}
