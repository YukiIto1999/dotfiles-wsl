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
  # 検証の段の入口と時間予算を repository の宣言から引く実装はここだけに置く。
  # agent の停止の門は verify を、git の pre-push は verify-push を同じ解決で引き、agent の wrapper は verify の予算も同じ command から読む。
  options.dotfiles.toolchain.verification.entry = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "repository が宣言する検証の段(verify、verify-push、verify-full)の入口を呼び出しの綴りで答える command。Nix の入口は root の verification-budget.json の frontend と entries に登録し、入口解決では評価器を起動しない。--budget は同じ宣言にある段の時間予算を秒で答え、--candidates は不正な宣言下の canonical 呼び出し判別用の候補を答える。";
  };

  config.dotfiles.toolchain.verification.entry = entry;
}
