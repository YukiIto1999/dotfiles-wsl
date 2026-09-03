{ lib, ... }:

{
  dotfiles.identity.github.accounts = lib.mkForce [
    "account-1"
    "account-2"
    "account-3"
    "missing-account"
  ];
}
