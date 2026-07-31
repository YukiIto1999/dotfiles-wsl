{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my;

  substitute =
    vars: text:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames vars
    )) (builtins.attrValues vars) text;

  # 全 command が使う値。command 固有の値は各 unit が vars で足す
  baseVars = {
    inherit (cfg) dotfilesDir username;
    nixStoreDir = builtins.storeDir;
    systemProfilePath = "/nix/var/nix/profiles/system";
    sudoCommand = lib.escapeShellArg "${config.security.wrapperDir}/sudo";
  };
in
{
  options.my.commands = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    description = "config から生成する運用コマンド。flake.nix の packages 出力が nixosConfiguration 経由でここを参照する。";
  };

  # 各 unit が自分の command を組み立てるための契約。実体は所有する unit が持つ
  config._module.args.substituteCommandVars = vars: text: substitute (baseVars // vars) text;

  config._module.args.mkCommand =
    {
      name,
      src,
      runtimeInputs ? [ ],
      vars ? { },
      extra ? { },
    }:
    pkgs.writeShellApplication (
      {
        inherit name runtimeInputs;
        text = substitute (baseVars // vars) (builtins.readFile src);
      }
      // extra
    );
}
