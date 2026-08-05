{ lib, ... }:

{
  dotfiles.agents.enabled = lib.mkForce [
    "claude"
    "missing-agent"
  ];
}
