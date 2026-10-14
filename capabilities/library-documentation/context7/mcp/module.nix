{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  enabled = builtins.elem "library-documentation" config.dotfiles.capabilities.resolved;
  mkMcpServer = pkgs.callPackage ../../../../platform/mcp/package/mk-server.nix { };
  front = pkgs.callPackage ./package.nix {
    context7Mcp =
      self.inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.context7-mcp;
    serverBuilder = mkMcpServer;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.context7 = {
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
  };
}
