{
  lib,
  pkgs,
  mkMcpServer,
  serveOverProxy,
  mkNpmMcp,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit mkMcpServer mkNpmMcp; };
in
{
  my.mcp.targets.probe = {
    port = 18102;
    serve = serveOverProxy (lib.getExe front);
  };
}
