{ lib, pkgs, ... }:

{
  # 生成した設定を検査側が形式ごとに見つけるための登録簿
  options.my.gates.devShellPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    internal = true;
    description = "保守作業の devShell が公開する package。flake が devShell 出力へ写像する。";
  };

  config.my.gates.devShellPackages = with pkgs; [
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
