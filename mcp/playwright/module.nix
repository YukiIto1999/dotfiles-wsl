{
  lib,
  pkgs,
  mkMcpServer,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit mkMcpServer; };
in
{
  my.mcp.targets.playwright.transport.stdio.command = lib.getExe front;
}
