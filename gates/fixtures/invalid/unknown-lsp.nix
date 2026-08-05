{ lib, ... }:

{
  dotfiles.toolchain.enabledLsp = lib.mkForce [
    "bash"
    "csharp"
    "java"
    "nix"
    "python"
    "rust"
    "typescript"
    "missing-lsp"
  ];
}
