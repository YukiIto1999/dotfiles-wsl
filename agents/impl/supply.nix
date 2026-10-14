{
  lib,
  pkgs,
  mkCommand,
}:

# client binary を native profile へ供給する唯一の command の builder。
# 本番は固定の baseline だけを渡し、fixture は同じ script へ偽の nix と hook を差し込む
{
  name ? "dotfiles-agent-supply",
  src ? ./agent-supply.sh,
  manifest,
  sourceRef,
  homeDir,
  profileRootRelative,
  legacyRootRelative,
  storeDir ? builtins.storeDir,
  transactionHook ? "${pkgs.coreutils}/bin/true",
  nixPackage ? pkgs.nix,
  leadingInputs ? [ ],
}:
mkCommand {
  inherit name src;
  vars = {
    manifest = builtins.toJSON manifest;
    sourceRef = lib.escapeShellArg sourceRef;
    system = lib.escapeShellArg pkgs.stdenv.hostPlatform.system;
    homeDir = lib.escapeShellArg homeDir;
    profileRootRelative = lib.escapeShellArg profileRootRelative;
    legacyRootRelative = lib.escapeShellArg legacyRootRelative;
    nixStoreDir = lib.escapeShellArg storeDir;
    transactionHook = lib.escapeShellArg transactionHook;
  };
  runtimeInputs =
    leadingInputs
    ++ lib.optional (nixPackage != null) nixPackage
    ++ (with pkgs; [
      coreutils
      findutils
      jq
      util-linux
    ]);
}
