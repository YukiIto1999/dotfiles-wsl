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
  my.mcp.targets.context7.transport.stdio.command = lib.getExe front;
}
