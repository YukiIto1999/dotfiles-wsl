{ lib, ... }:

{
  dotfiles.mcp.enabledProviders = lib.mkForce [ "missing-provider" ];
}
