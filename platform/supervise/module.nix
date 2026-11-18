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
      `--resource-policy FILE --resource-wait-until EPOCH --resource-run-seconds SEC`はclassごとの入場を通ってからcommandを起動する。
      policyはclass（待つ者のいる検証のacceptanceか、待つ者のいない検証のdeep）、観測command、利用者専用の状態directory、memoryPercent、観測の有効秒数、systemd-runとsystemctlのargv、cgroupの根、classごとのsliceの相対pathを持つ。
      入場できた走行は、classのsliceの下の走行ごとのscopeで動く。受入はscopeのMemoryLowへ、deepはMemoryHighへ需要を書き、deepにはoom_score_adj 1000を与える。
      受入は他の受入が待っていても止まらない。deepは受入が待つ間は入場せず、同時に一走行だけである。受入がmemoryで収まらないときは、動いているdeepのscopeだけを`systemctl --user stop --no-block`で取り消す。受入とsessionは取り消さない。
      取り消す側は、stopの前にscope名を持つ`cancel-<scope名>`の空のfileを状態directoryへ残す。deepのsupervisorは終了時にそのfileを読んで消し、commandの終了statusにはよらず、取り消された走行として143で返し、実測を記録しない。fileを残せなければ取り消さない。
      受入の空きの判定は、動いている受入のscopeが予約まで使い増せる量（memory.lowから現在の使用量を引いた量）を各上限の空きと比べる。deepの増分は数えない。
      観測の圧迫は、受入はfailureだけ、deepはwarningでも入場を止める。
      入れ子は`/proc/self/cgroup`がclassのscopeの下にあれば、そのscopeの中で外側のclassのまま実行する。入れ子で昇格せず、scopeも作らず、待たない。
      `--resource-memory BYTES`は同じpolicy内で当該呼出しの物理memory需要を明示する。CPUは予約しない。入れ子では外側のscopeの需要を超える明示を70で拒否する。
      明示しない物理memoryの需要は最初の有効な観測で確定し、最も厳しい上限へ切り詰める。
      上限は物理memory総量と各cgroupのlimitBytesの最小値で、既定値はその上限のmemoryPercent%である。
      `--resource-key KEY`を渡した走行は、記録があれば新しい5件のピークの最大を既定値の代わりに予約し、記録が無ければ記録directoryの他の鍵の最新のピークの中央値（件数が偶数なら大きい側）を、それも無ければ既定値を予約する。
      明示した物理memoryが上限を超える場合は、待たずにcommandを起動せず70で返す。scopeを作れない場合も70で、commandは起動しない。
      待機と走行は別に数える。`--resource-wait-until`までに入場できなければcommandを起動せず75で返し、`--resource-run-seconds`は入場して起動した時から数えて、超えれば取り消して124で返す。
      `--resource-target-seconds SEC`は走行の秒数がSECに達した時点の読取を残す目標で、`--resource-run-seconds`と同じく入場して起動した時から数える。記録だけに使い、取消にも走行の枠にも使わず、`--resource-policy`が要る。
      資源予約を持つ走行は所有する子孫のPSS合計を約1秒ごとに測り、ピークが予約を超えるとstderrへ一行を出す。
      `--result`のfinished段階には、その走行のmemoryPeakBytesとmemoryReservedBytesとwaitSecondsが加わる。未起動の走行のfinished段階もwaitSecondsを持つ。
      起動した走行のfinished段階にはrunSecondsと、走行のscopeのcgroupから終了時に読んだcpuSeconds（cpu.statのusage_usec）、cpuStallSeconds（cpu.pressureのsome）、ioStallSeconds（io.pressureのfull）、memoryStallSeconds（memory.pressureのfull）の秒（ミリ秒精度）、targetSeconds、atTargetも加わる。
      終了時の読取は終了を始める時に行い、読めなかった項目は約1秒ごとの読取の直近の値で、一度も読めなければnullである。上限での取消と外からの取消でも読み、読めなくても終了statusは変えない。scopeを作らない入れ子の走行は全てnullである。
      目標が渡され、走行が目標の時点でなお動いていれば、atTargetがその時点の同じ四つの項目を持つ。目標より前に終わった走行と、目標の無い走行ではnullである。
      資源予約を持つ走行は、終了のたびに計測の一行をjournaldのnative socket（policyのjournalSocket、既定は`/run/systemd/journal/socket`）へ`SYSLOG_IDENTIFIER=dotfiles-supervise`で送る。
      MESSAGEはJSON一行で、class、key、入れ子か、入場したか、待機秒数とその理由、走行秒数、終了status、ピークと予約のbyte、走行のscopeから読んだcpuSeconds、cpuStallSeconds、ioStallSeconds、memoryStallSeconds、targetSeconds、atTargetを持つ。
      送れない場合はstderrへ一行を出すだけで、commandの終了statusを変えない。
      記録は`''${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-wsl/workload/demand/`へ鍵のsha256ごとに置き、鍵を渡した走行だけが読み書きする。
      子孫の回収を確認でき、commandが取消も期限到達も無く自分で0で終了した走行と、ピークが予約を超えた走行だけを新しい順に10件まで残す。
      記録の読み書きの失敗はstderrへ一行を出し、commandの終了statusを変えず、鍵の記録を読めない場合は記録の無い鍵と同じ需要で予約する。
      走行の所有と生死はscopeのcgroupとwaitpidのECHILDが持ち、走行を表す記録fileは持たない。状態directoryには、判定の排他のregistry.lockと、受入が待つ間だけ共有で持つacceptance.waitingのlockだけがある。
      取消の印のcancel-fileは走行の記録ではなく、supervisorが強制終了されて読まれなかったものだけが残り、scopeが無く一時間を過ぎたものを次の取消が消す。
      supervisor自体が強制終了されても、commandが残る間はそのscopeが空きの計算に数えられ続け、他の走行を止めない。
      資源予約を持つ実行にはrequire-drainedを適用する。
    '';
  };

  config.dotfiles.platform.supervise.package = supervise;
}
