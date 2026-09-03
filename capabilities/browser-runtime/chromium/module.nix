{ lib, pkgs, ... }:

{
  options.dotfiles.capabilities.browser-runtime.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "browser Capability implementation が共有する browser runtime package";
  };

  config.dotfiles.capabilities.browser-runtime.package = pkgs.chromium;
}
