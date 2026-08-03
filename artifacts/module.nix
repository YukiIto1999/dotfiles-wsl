{ lib, ... }:

{
  options.my.artifacts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          format = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "json"
                "toml"
                "yaml"
              ]
            );
            default = null;
            description = "構文検査に使う serialization format。null なら構文検査の対象外。";
          };
          deployedAt = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "配備先の絶対パス。非 null なら doctor が乖離を検査する。";
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

}
