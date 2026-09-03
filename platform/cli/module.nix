{
  config,
  lib,
  ...
}:

{
  options.dotfiles.platform.cli.commands = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    description = "config から生成する運用コマンド。flake.nix の packages 出力が nixosConfiguration 経由でここを参照する。";
  };

  config.environment.systemPackages = builtins.attrValues config.dotfiles.platform.cli.commands;
}
