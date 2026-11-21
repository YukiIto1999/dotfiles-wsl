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
      exposure = "default";
      executable = lib.getExe front;
      serverLifecycle = "session";
      # stdio の tool 登録は API key に依らず、discovery seed は key も network も無い sandbox で生成できる
      lazyDiscovery = true;
      port = 8771;
      needsNetwork = true;
    };
  };
}
