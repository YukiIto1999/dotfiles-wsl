{
  lib,
  pkgs,
  ...
}:

let
  supervise = pkgs.callPackage ./package.nix { };
in
{
  options.dotfiles.platform.supervise.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = ''
      絶対pathのcommandを一度だけ起動し、子孫の終了をwaitpidのECHILDで観測する監督器である。
      `dotfiles-supervise [--term-grace SEC] [--kill-grace SEC] [--result FILE] [--argv0 NAME] [--hold-fd N] [--parent-death-cancels PID] [--require-drained] [--interrupt-cancels] -- COMMAND...`の形で呼ぶ。
      SIGTERMとSIGHUPはsession全体の取消とし、SIGINTとSIGQUITは既定ではsession全体の取消として扱わない。
      `--interrupt-cancels`を明示した呼び出しだけは、SIGINTをSIGTERMと同じsession全体の取消として扱い、終了処理も終了statusも同じ規則に従う。
      SIGQUITは`--interrupt-cancels`の有無にかかわらず取消として扱わない。
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
      `--resource-policy FILE --resource-deadline EPOCH`はhost共通のFIFO予約を取得してからcommandを起動する。
      policyは走行の種類classと観測commandと利用者専用のregistryとmemoryPercentとcpuCountと観測の有効秒数を持つ。
      classは待つ者のいる検証のacceptanceか、待つ者のいない検証のdeepで、計測の一行に残るだけで予約の規則は変えない。
      `--resource-memory BYTES`と`--resource-cpus COUNT`は同じpolicy内で当該呼出しの需要を明示する。
      明示しない物理memoryの需要は最初の有効な観測で確定し、最も厳しい上限へ切り詰める。
      上限は物理memory総量と各cgroupのlimitBytesの最小値で、既定値はその上限のmemoryPercent%である。
      `--resource-key KEY`を渡した走行は、記録があればfingerprintが現在と一致し30日以内の新しい5件のピークの最大に20%を足した値を既定値の代わりに予約する。
      明示した物理memoryが上限を超える場合は、待たずにcommandを起動せず70で返す。
      資源予約を持つ走行は所有する子孫のPSS合計を約1秒ごとに測り、ピークが予約を超えるとstderrへ一行を出す。
      `--result`のfinished段階には、その走行のmemoryPeakBytesとmemoryReservedBytesが加わる。
      資源予約を持つ走行は、終了のたびに計測の一行をjournaldのnative socket（policyのjournalSocket、既定は`/run/systemd/journal/socket`）へ`SYSLOG_IDENTIFIER=dotfiles-supervise`で送る。
      MESSAGEはJSON一行で、class、key、入れ子か、入場したか、待機秒数とその理由、走行秒数、終了status、ピークと予約のbyteを持つ。
      送れない場合はstderrへ一行を出すだけで、commandの終了statusを変えない。
      記録は`''${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-wsl/workload/demand/`へ鍵のsha256ごとに置き、鍵を渡した走行だけが読み書きする。
      子孫の回収を確認でき、commandが取消も期限到達も無く自分で0で終了した走行と、ピークが予約を超えた走行だけを新しい順に10件まで残す。
      fingerprintはgit repositoryの根にある依存と検証入口の宣言のindexのsha256で、repositoryでなければ空文字列である。
      記録の読み書きの失敗はstderrへ一行を出し、commandの終了statusを変えず、読めない場合は既定値で予約する。
      観測不能や圧迫では新規実行だけを待たせ、期限切れは未起動のdeferred記録と124で返す。
      待機も実行も同じ絶対期限に含め、資源予約を持つ実行にはrequire-drainedを適用する。
      入れ子は生存する祖先の予約内で実行し、明示した需要が祖先予約を超える場合と偽の継承は拒否する。
      記録由来と既定値由来の需要は祖先の予約へ切り詰め、拒否しない。
      予約は子孫終了まで保持し、所有者不明の実行記録を空きとして自動削除しない。
    '';
  };

  config.dotfiles.platform.supervise.package = supervise;
}
