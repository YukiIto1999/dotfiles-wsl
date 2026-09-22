{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "project-memory" config.dotfiles.capabilities.resolved;
  integrations = pkgs.callPackage ./package.nix {
    runtime = config.dotfiles.capabilities.project-memory.runtime;
  };
in
{
  options.dotfiles.capabilities.project-memory.clientIntegrations = {
    hooks = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Shared project-memory hook CLI package.";
    };
    opencodePlugin = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "OpenCode project-memory plugin source.";
    };
  };

  config = lib.mkIf enabled {
    dotfiles.capabilities.project-memory.clientIntegrations = {
      inherit (integrations) hooks opencodePlugin;
    };
  };
}
