{
  lib,
  pkgs,
  mkMcpServer,
  ...
}:

let
  front = pkgs.callPackage ../../../pkgs/playwright-mcp { inherit mkMcpServer; };
in
{
  my.mcp.targets.playwright.command = lib.getExe front;
}
