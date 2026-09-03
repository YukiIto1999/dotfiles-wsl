{ config, lib, ... }:

{
  dotfiles.skills.enabled = lib.mkForce (
    builtins.attrNames config.dotfiles.skills.registry ++ [ "unknown-skill" ]
  );
}
