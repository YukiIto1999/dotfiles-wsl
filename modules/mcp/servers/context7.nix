{ lib, pkgs, mkMcpServer, mkNpmMcp, ... }:

let
  front = pkgs.callPackage ../../../pkgs/context7-mcp { inherit mkMcpServer mkNpmMcp; };
in
{
  my.mcp.targets.context7.command = lib.getExe front;
}
