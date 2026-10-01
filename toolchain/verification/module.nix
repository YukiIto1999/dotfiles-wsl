{
  lib,
  pkgs,
  ...
}:

let
  entry = pkgs.writeShellApplication {
    name = "dotfiles-verify-entry";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnugrep
      jq
    ];
    text = builtins.readFile ./impl/entry.sh;
  };
in
{
  # 検証の段の入口を repository の宣言から引く実装はここだけに置く。
  # agent の停止の門は verify を、git の pre-push は verify-push を同じ解決で引く
  options.dotfiles.toolchain.verification.entry = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "repository が宣言する検証の段(verify、verify-push、verify-full)の入口を、呼び出しの綴りで答える command。";
  };

  config.dotfiles.toolchain.verification.entry = entry;
}
