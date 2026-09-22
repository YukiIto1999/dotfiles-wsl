{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled =
    builtins.elem "project-memory" config.dotfiles.capabilities.resolved
    && config.dotfiles.capabilities.registry."project-memory".implementation == "hindsight";
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  runtime = pkgs.callPackage ./package.nix {
    commandBuilder = mkCommand;
    apiUrl = config.dotfiles.platform.containers.services.hindsight.endpoints.http.url;
  };
in
{
  options.dotfiles.capabilities.project-memory.runtime = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
  };

  config = lib.mkIf enabled {
    dotfiles.capabilities.project-memory.runtime = runtime;
    dotfiles.platform.cli.commands.memory = runtime;
  };
}
