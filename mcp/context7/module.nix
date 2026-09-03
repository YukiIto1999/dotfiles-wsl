{
  lib,
  pkgs,
  ...
}:

let
  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  front = pkgs.callPackage ./package.nix {
    inherit mkNpmMcp;
    serverBuilder = mkMcpServer;
  };
in
{
  dotfiles.mcp.targets.context7 = {
    provider = "context7";
    executable = lib.getExe front;
    serverLifecycle = "service";
    port = 8771;
    needsNetwork = true;
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
