{
  lib,
  pkgs,
  mkMcpServer,
  mkNpmMcp,
  serveOverProxy,
  ...
}:

let
  front = pkgs.callPackage ./package.nix { inherit mkMcpServer mkNpmMcp; };
in
{
  my.mcp.targets.context7 = {
    port = 18101;
    serve = serveOverProxy (lib.getExe front);
  };
}
