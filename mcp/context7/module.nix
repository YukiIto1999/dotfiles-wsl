{
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  serveOverProxy = pkgs.callPackage ../package/serve-over-proxy.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
  };
in
{
  dotfiles.mcp.targets.context7 = {
    provider = "context7";
    port = 8771;
    # cloud の library docs API へ出る
    needsNetwork = true;
    serve = serveOverProxy (lib.getExe front);
    probe = {
      tool = "resolve-library-id";
      args = {
        libraryName = "nixpkgs";
        query = "Nix option types";
      };
      timeout = 30;
    };
  };
}
