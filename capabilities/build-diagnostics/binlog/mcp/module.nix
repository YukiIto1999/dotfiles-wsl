{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "build-diagnostics" config.dotfiles.capabilities.resolved;
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets.binlog = {
      provider = "binlog";
      executable = lib.getExe (pkgs.callPackage ./package.nix { });
      exposure = "default";
      serverLifecycle = "session";
      lazyDiscovery = true;
      port = 8775;
    };
  };
}
