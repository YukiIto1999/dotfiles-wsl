{
  pkgs,
  lib,
  powershellCommand,
  wslpathCommand ? "/bin/wslpath",
}:

let
  substitutions = {
    "@base64Command@" = lib.escapeShellArg "${pkgs.coreutils}/bin/base64";
    "@powershellCommand@" = lib.escapeShellArg powershellCommand;
    "@realpathCommand@" = lib.escapeShellArg "${pkgs.coreutils}/bin/realpath";
    "@wslpathCommand@" = lib.escapeShellArg wslpathCommand;
  };
in
pkgs.writeShellApplication {
  name = "wslview";
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./impl/wslview.sh);
}
