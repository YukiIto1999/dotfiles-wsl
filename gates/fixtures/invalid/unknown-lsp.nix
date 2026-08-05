{ lib, ... }:

{
  dotfiles.toolchain.enabledLsp = lib.mkForce [ "missing-lsp" ];
}
