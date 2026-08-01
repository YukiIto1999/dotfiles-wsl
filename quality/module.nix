{ lib, pkgs, ... }:

{
  # 生成した設定を検査側が形式ごとに見つけるための登録簿
  options.my.artifacts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          format = lib.mkOption {
            type = lib.types.enum [
              "json"
              "toml"
              "yaml"
            ];
            description = "構文検査に使う serialization format。";
          };
          source = lib.mkOption {
            type = lib.types.path;
            description = "配備側と検査側が共有する immutable source。";
          };
        };
      }
    );
    default = { };
    internal = true;
    description = "実配備 producer が一度だけ生成する不変設定 artifact。配備方法は各 module が所有する。";
  };

  options.my.quality.devShellPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    internal = true;
    description = "保守作業の devShell が公開する package。flake が devShell 出力へ写像する。";
  };

  config.my.quality.devShellPackages = with pkgs; [
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
