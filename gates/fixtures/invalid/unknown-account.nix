{ lib, ... }:

{
  dotfiles.accounts = lib.mkForce [ "missing-account" ];
}
