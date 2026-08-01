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
  my.mcp.targets.playwright.command = lib.getExe front;
}
