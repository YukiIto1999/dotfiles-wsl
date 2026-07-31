{ lib, pkgs, ... }:

{
  options.my.devShellPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    internal = true;
    description = "保守作業の devShell が公開する package。flake が devShell 出力へ写像する。";
  };

  config.my.devShellPackages = with pkgs; [
    actionlint
    deadnix
    jq
    nixfmt-tree
    shellcheck
    statix
    taplo
    yq
  ];
}
