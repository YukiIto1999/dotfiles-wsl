{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "code-quality" config.dotfiles.capabilities.resolved;
  mkCommand = import ../../../../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  scanner = pkgs.callPackage ./package.nix {
    commandBuilder = mkCommand;
    serverUrl = config.dotfiles.platform.containers.services.sonarqube.endpoints.http.url;
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.cli.commands.sonarqube-scan = scanner;
  };
}
