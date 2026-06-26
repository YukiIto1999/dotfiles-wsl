{
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  ...
}:

let
  front = pkgs.callPackage ../../../pkgs/probe-mcp { inherit mkMcpServer mkNpmMcp; };
in
{
  my.mcp.targets.probe.command = lib.getExe front;
}
