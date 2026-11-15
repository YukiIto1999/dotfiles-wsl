/**
  native検証の実行部品の構築
  pkgs: 実行入口を生成する固定済みpackage集合
  supervise: 子孫回収を所有するplatformのnative command
  戻り値: 所有子孫の終了を待つ期限付き起動package
*/
{
  pkgs,
  supervise,
  resourcePolicy ? null,
}:

let
  inherit (pkgs) lib;
  runWithinCore = pkgs.writeShellApplication {
    name = "dotfiles-run-within-core";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./impl/run-within.sh;
  };
in
{
  # timeout の process group だけでは別 session へ移った子孫を止められないため supervise の下で起動
  # 猶予が run-within.sh の timeout --kill-after より短いと command 自身の停止を KILL が先に切るため不可
  # 公開 PID への INT を取消として扱ってきた呼び出し側のため supervise 既定の INT 無視は不可
  runWithin = pkgs.writeShellApplication {
    name = "dotfiles-run-within";
    text = ''
      usage() {
        printf 'usage: dotfiles-run-within [--resource-key KEY] SECONDS COMMAND [ARG...]\n' >&2
        exit 64
      }
      ${lib.optionalString (resourcePolicy == null) ''
        # 資源予約の無い構成でも呼び出し側が同じ引数で呼べるように、鍵は受け取って使わない
        if [ "$#" -ge 1 ] && [ "$1" = --resource-key ]; then
          [ "$#" -ge 4 ] || usage
          shift 2
        fi
      ''}
      ${lib.optionalString (resourcePolicy != null) ''
        resource_key=()
        if [ "$#" -ge 1 ] && [ "$1" = --resource-key ]; then
          [ "$#" -ge 4 ] || usage
          resource_key=(--resource-key "$2")
          shift 2
        fi
        [ "$#" -ge 2 ] || usage
        deadline=$(${lib.getExe pkgs.python3} -c 'import math,sys,time; s=float(sys.argv[1]); assert math.isfinite(s) and s>0; print(time.time()+s)' "$1")
        exec ${lib.getExe supervise} --require-drained --interrupt-cancels --term-grace 10 \
          --resource-policy ${lib.escapeShellArg (toString resourcePolicy)} --resource-deadline "$deadline" \
          "''${resource_key[@]}" -- ${lib.getExe runWithinCore} "$@"
      ''}
      exec ${lib.getExe supervise} --require-drained --interrupt-cancels --term-grace 10 -- ${lib.getExe runWithinCore} "$@"
    '';
  };
}
