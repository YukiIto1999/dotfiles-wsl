{ lib, ... }:

{
  dotfiles.containers.enabled = lib.mkForce [ "missing-container" ];
}
