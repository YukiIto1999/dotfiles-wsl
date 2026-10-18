/**
  全repositoryへ配るGit hookの構築
  lib: 実行fileと引数を解決するNixpkgs library
  pkgs: hookの実行入口を生成する固定済みpackage集合
  verificationEntry: repositoryが宣言するT2の入口の解決command
  supervise: 検証の所有子孫を回収するplatformのnative command
  戻り値: hook名をkeyとする実行package集合
*/
{
  lib,
  pkgs,
  verificationEntry,
  supervise,
}:

let
  verificationPrograms = import ../verification/package.nix { inherit pkgs supervise; };
  # githooks(5) の client 側 hook のうち、repository が `.githooks/` に置いて使う名前。
  # reference-transaction と post-index-change は ref と index の更新ごとに起動されるため、
  # 置くだけで全 repository の git 操作に process の起動が加わる。配らない。
  hookNames = [
    "applypatch-msg"
    "commit-msg"
    "post-applypatch"
    "post-checkout"
    "post-commit"
    "post-merge"
    "post-rewrite"
    "pre-applypatch"
    "pre-auto-gc"
    "pre-commit"
    "pre-merge-commit"
    "pre-push"
    "pre-rebase"
    "prepare-commit-msg"
  ];

  # hook は git を呼んだ process の PATH で動く。systemd service など bash を持たない
  # 呼び出し元からも同じ検査を通すため、interpreter と使う command を hook 自身に固定する。
  mkScript =
    name: text:
    pkgs.writeShellApplication {
      inherit name text;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
      ];
    };

  # dotfiles が全 repository に課す検査。ここに無い hook では repository 側だけが走る。
  globalChecks = {
    pre-commit = mkScript "git-global-pre-commit" (builtins.readFile ./assets/hooks/pre-commit);
    commit-msg = mkScript "git-global-commit-msg" (builtins.readFile ./assets/hooks/commit-msg);
    pre-push = mkScript "git-global-pre-push" (
      builtins.replaceStrings
        [ "@verificationEntry@" "@runWithin@" ]
        [ (lib.getExe verificationEntry) (lib.getExe verificationPrograms.runWithin) ]
        (builtins.readFile ./assets/hooks/pre-push)
    );
  };

  dispatcher =
    name:
    mkScript name (
      builtins.replaceStrings
        [ "@hook@" "@globalCheck@" ]
        [
          name
          (lib.optionalString (globalChecks ? ${name}) (lib.getExe globalChecks.${name}))
        ]
        (builtins.readFile ./assets/hooks/dispatch)
    );
in
lib.genAttrs hookNames dispatcher
