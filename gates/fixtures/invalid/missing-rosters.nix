{ lib, ... }:

{
  dotfiles = {
    accounts = lib.mkForce [ ];
    agents.enabled = lib.mkForce [ ];
    containers.enabled = lib.mkForce [ ];
    mcp.enabledProviders = lib.mkForce [ ];
    toolchain.enabledLsp = lib.mkForce [ ];
  };
}
