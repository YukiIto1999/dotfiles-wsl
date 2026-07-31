{ config, pkgs }:

let
  reinstallSecrets = pkgs.writeShellScript "dotfiles-sops-reinstall-secrets" ''
    set -euo pipefail
    ${config.system.activationScripts.setupSecrets.text}
  '';
in
{
  inherit reinstallSecrets;
  contract = (pkgs.formats.json { }).generate "sops-generation-v1.json" {
    schemaVersion = 1;
    ciphertext = {
      path = config.sops.defaultSopsFile;
      sha256 = builtins.hashFile "sha256" config.sops.defaultSopsFile;
    };
    sopsManifest = config.system.build.sops-nix-manifest;
    inherit reinstallSecrets;
  };
}
