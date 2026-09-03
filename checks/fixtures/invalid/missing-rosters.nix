{ lib, ... }:

{
  dotfiles = {
    identity.github.accounts = lib.mkForce [ ];
    agents.enabled = lib.mkForce [ ];
    capabilities.enabled = lib.mkForce [ ];
    skills.enabled = lib.mkForce [ ];
    toolchain.enabledLsp = lib.mkForce [ ];
  };
}
