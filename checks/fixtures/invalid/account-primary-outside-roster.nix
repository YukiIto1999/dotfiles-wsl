{ lib, ... }:

{
  dotfiles.identity.github.primary = lib.mkForce "not-declared";
}
