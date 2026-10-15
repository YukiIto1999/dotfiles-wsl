{
  lib,
  pkgs,
  ...
}:

let
  supervise = pkgs.writeShellApplication {
    name = "dotfiles-supervise";
    text = ''
      exec ${lib.getExe pkgs.python3} -I -S ${./impl/supervise.py} "$@"
    '';
  };
in
{
  options.dotfiles.platform.supervise.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = ''
      絶対pathのcommandを一度だけ起動し、子孫の終了をwaitpidのECHILDで観測する監督器である。
      `dotfiles-supervise [--term-grace SEC] [--kill-grace SEC] [--result FILE] [--argv0 NAME] [--hold-fd N] [--parent-death-cancels PID] [--require-drained] -- COMMAND...`の形で呼ぶ。
      SIGTERMとSIGHUPはsession全体の取消とし、SIGINTとSIGQUITはsession全体の取消として扱わない。
      commandの終了または取消で終了処理を始め、所有する全processへSIGTERM、猶予、SIGKILLの順に送る。
      commandの終了status（signalは128+n）を保つが、`--require-drained`なしでSIGKILL後の猶予が過ぎても所有processが残る場合は70、起動できない場合は126か127、使い方が不正な場合は2を返す。
      `--result`のJSONはstartedとfinishedの段階、client_status、drained、remainingを持つ。
      `--argv0`は起動するfileを変えず、そのfileが受け取るargv[0]だけを替える。
      `--hold-fd`のdescriptorはcommandと子孫へ渡さず、全processの終了確認までsupervisorが保持する。
      `--require-drained`なしで終了を確認できなければ、切り離したholderが残存processの終了までdescriptorを保持する。
      `--parent-death-cancels`には呼び出し側自身のPIDを渡し、その親を失った場合は起動準備前の終了も含めて取消とする。
      指定しなければsessionは呼び出し側より長く生きる。
      `--require-drained`はopt-inの強い完了契約で、SIGKILL後の猶予が過ぎても所有を手放さず、kernelがwaitpidのECHILDを報告するまで返らない。
      猶予の経過を完了とは扱わず、猶予後は定期的にstderrと`--result`のdraining段階へ診断を出して待ち続ける。
      draining段階はdrainedがfalseで、remaining、unsignalable、observation_error、seconds_past_kill_graceを持つ。
      signalを拒むprocessとprocess tableの読取失敗も終了とは扱わず、同じ診断へ出して待ち続ける。
      /procから自身を観測できない場合は、commandを起動せず70を返す。
      起動したcommandのdrainedがtrueになるのはECHILDの確認後だけである。
      `--result`の全段階にcompletionが加わり、起動したcommandのfinished段階にはkill_grace_expiredも加わる。
      supervisor自身が`--hold-fd`を終了確認まで保持するので、切り離したholderは作らない。
      supervisor自体を強制終了した場合は、子孫の終了を確認していない。
    '';
  };

  config.dotfiles.platform.supervise.package = supervise;
}
