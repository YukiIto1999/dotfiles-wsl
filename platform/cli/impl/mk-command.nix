{
  config,
  lib,
  pkgs,
}:
{
  name,
  src,
  runtimeInputs ? [ ],
  vars ? { },
  extra ? { },
}:
let
  cfg = config.dotfiles.workstation;
  substitute = import ./substitute-command-vars.nix;
  baseVars = {
    inherit (cfg) dotfilesDir username;
    nixStoreDir = builtins.storeDir;
    systemProfilePath = "/nix/var/nix/profiles/system";
    sudoCommand = lib.escapeShellArg "${config.security.wrapperDir}/sudo";
  };
in
pkgs.writeShellApplication (
  {
    inherit name runtimeInputs;
    text = substitute (baseVars // vars) (builtins.readFile src);
  }
  // extra
)
