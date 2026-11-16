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
  # 資源予約の入場は鍵を渡した呼出し（検査本体）だけが受ける。鍵の無い短い段は予約の待ちへ並べず、数秒の処理が数分の待ちを負わない
  # 待ちの上限と走行の枠はどちらも SECONDS で、走行の枠は入場から数える。待った秒数は --result の file に残り、呼び出し側が予算から外す
  runWithin = pkgs.writeShellApplication {
    name = "dotfiles-run-within";
    text = ''
      usage() {
        printf 'usage: dotfiles-run-within [--resource-key KEY] [--result FILE] SECONDS COMMAND [ARG...]\n' >&2
        exit 64
      }
      ${lib.optionalString (resourcePolicy == null) ''
        # 資源予約の無い構成でも呼び出し側が同じ引数で呼べるように、鍵と結果の file は受け取って使わない
        while [ "$#" -ge 1 ]; do
          case $1 in
          --resource-key | --result)
            [ "$#" -ge 4 ] || usage
            shift 2
            ;;
          *) break ;;
          esac
        done
      ''}
      ${lib.optionalString (resourcePolicy != null) ''
        resource_key=()
        result=()
        while [ "$#" -ge 1 ]; do
          case $1 in
          --resource-key)
            [ "$#" -ge 4 ] || usage
            resource_key=(--resource-key "$2")
            shift 2
            ;;
          --result)
            [ "$#" -ge 4 ] || usage
            result=(--result "$2")
            shift 2
            ;;
          *) break ;;
          esac
        done
        if [ "''${#resource_key[@]}" -gt 0 ]; then
          [ "$#" -ge 2 ] || usage
          wait_until=$(${lib.getExe pkgs.python3} -c 'import math,sys,time; s=float(sys.argv[1]); assert math.isfinite(s) and s>0; print(time.time()+s)' "$1")
          exec ${lib.getExe supervise} --require-drained --interrupt-cancels --term-grace 10 \
            --resource-policy ${lib.escapeShellArg (toString resourcePolicy)} --resource-wait-until "$wait_until" \
            --resource-run-seconds "$1" "''${resource_key[@]}" "''${result[@]}" -- ${lib.getExe runWithinCore} "$@"
        fi
      ''}
      exec ${lib.getExe supervise} --require-drained --interrupt-cancels --term-grace 10 -- ${lib.getExe runWithinCore} "$@"
    '';
  };
}
