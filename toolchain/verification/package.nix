/**
  native検証の実行部品の構築
  pkgs: 実行入口を生成する固定済みpackage集合
  supervise: 子孫回収を所有するplatformのnative command
  戻り値: 所有子孫の終了を待つ期限付き起動packageと、成功した検査出力を次の段まで保持するbuild package
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
  # nix は runtimeInputs に入れず呼び出し側の PATH のものを使う。agent の shim の --no-link 方針を通した nix と同じ入口で build するため
  buildRooted = pkgs.writeShellApplication {
    name = "dotfiles-verification-build";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = builtins.readFile ./impl/build-rooted.sh;
  };
in
{
  inherit buildRooted;

  # 別 session に移った子孫も回収する supervisor が、走行の期限と公開 PID に届く INT の取消を引き受ける
  # 資源予約の入場は鍵を渡した呼出し（検査本体）だけが受ける。鍵の無い短い段は予約の待ちへ並べず、数秒の処理が数分の待ちを負わない
  # 待ちの上限と走行の枠はどちらも SECONDS で、走行の枠は入場から数える。待った秒数は --result の file に残り、呼び出し側が予算から外す
  # 目標の秒は走行の枠とは別の記録で、走行が目標へ達した時点の scope の読取を --result と journal に残すだけで、取消にも走行の枠にも使わない
  runWithin = pkgs.writeShellApplication {
    name = "dotfiles-run-within";
    text = ''
      usage() {
        printf 'usage: dotfiles-run-within [--resource-key KEY] [--result FILE] [--resource-target-seconds SEC] SECONDS COMMAND [ARG...]\n' >&2
        exit 64
      }
      resource_policy=${lib.escapeShellArg (toString resourcePolicy)}
      resource_key=()
      result=()
      resource_target=()
      while [ "$#" -ge 1 ]; do
        case $1 in
        --resource-key | --result | --resource-target-seconds)
          [ "$#" -ge 4 ] || usage
          case $1 in
            --resource-key) resource_key=(--resource-key "$2");;
            --result) result=(--result "$2");;
            --resource-target-seconds) resource_target=(--resource-target-seconds "$2");;
          esac
          shift 2
          ;;
        *) break ;;
        esac
      done
      [ "$#" -ge 2 ] || usage
      seconds=$1
      shift
      reservation=()
      if [ -n "$resource_policy" ] && [ "''${#resource_key[@]}" -gt 0 ]; then
        wait_until=$(${lib.getExe pkgs.python3} -c 'import math,sys,time; s=float(sys.argv[1]); assert math.isfinite(s) and s>0; print(time.time()+s)' "$seconds")
        reservation=(--resource-policy "$resource_policy" --resource-wait-until "$wait_until" "''${resource_key[@]}" "''${resource_target[@]}")
      fi
      exec ${lib.getExe supervise} --require-drained --interrupt-cancels --term-grace 10 \
        --resource-run-seconds "$seconds" "''${reservation[@]}" "''${result[@]}" -- ${lib.getExe runWithinCore} "$@"
    '';
  };
}
