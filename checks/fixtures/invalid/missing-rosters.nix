{ lib, ... }:

{
  dotfiles = {
    agents.enabled = lib.mkForce [ ];
    capabilities.enabled = lib.mkForce [ ];
    skills.enabled = lib.mkForce [ ];
    toolchain.enabledLsp = lib.mkForce [ ];
  };
}
