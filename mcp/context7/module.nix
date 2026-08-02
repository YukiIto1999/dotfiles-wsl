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
    port = 8771;
    # cloud の library docs API へ出る
    needsNetwork = true;
    serve = serveOverProxy (lib.getExe front);
  };
}
