---
name: runtime-observation
description: Captures runtime evidence that locates where a local process spends time, waits, or fails. Use when a .NET, Node.js, or native Linux process or a CLI is slow, hangs, spins the CPU, makes unexpected syscalls, or errors across local services, and the next step needs counters, traces, stacks, profiles, syscall logs, repeated timings, or OTLP logs and traces in the local Aspire Dashboard. Binds every capture to the process, workload, and run conditions and returns it to the caller. Does not own the reproduce-and-fix loop, benchmark validity claims, BenchmarkDotNet, MSBuild or binlog analysis, browser pages, JavaScript heap retention, production monitoring, or processes it was neither allowed to start nor given.
---

# 実行時の証拠を採る

遅延、停止、CPU の占有、例外について、原因の候補を絞れる実測を採り、条件と一緒に呼出し元へ返す。
採取は観測であり、修正、性能改善の主張、本番監視の代わりにしない。

## 問いと対象を固定する

1. 症状、比べる正常な状態、再現する操作、繰り返し回数、終了点を確かめる。
   利用者が報告した症状は観測として扱い、確認のために同じ障害を起こし直さない。
2. 対象を、自分が起動してよい command か、所有者が採取を許可した PID のどちらかに固定する。
   版、build 構成、環境変数、入力、実行 wrapper を記録する。
   `dotfiles-workload-run` は CPU weight を idle に、`dotfiles-capped-run` は CPU 上限を付けるため、wrapper の違う走行の時間を比べない。
3. 問いが別の担当に属する場合は、下の表の扱いに従う。

| 問い | 担当 |
|---|---|
| 壊れた挙動を再現して直す一連の作業 | `diagnosing-bugs`。そこから必要な採取だけを受け、結果を返して戻す |
| 変更前後の実測値または差 | 「前後を比べて測る」。比較の方法や結論の監査に `benchmark-checklist` が明示された場合は、計測条件と結果を渡す |
| .NET の関数単位の micro benchmark | `microbenchmarking` |
| MSBuild の失敗や build の遅さ | `msbuild` |
| browser の page の読込み、操作の遅さ、layout | `browser-performance` |
| JavaScript の object が解放されない理由 | `heap-analysis` |

## 問いに合う道具を選ぶ

| 調べたいこと | 入口 | 主な証拠 |
|---|---|---|
| .NET の CPU、GC、例外、thread pool の率の変化 | `dotnet-counters monitor --process-id PID --refresh-interval 1 --counters System.Runtime` | 時系列の値と変化した時刻 |
| .NET の遅い処理の時間経過と内訳 | `dotnet-trace collect --process-id PID --profile dotnet-common,dotnet-sampled-thread-time --duration 00:00:00:30 --output FILE.nettrace` | thread ごとの sampled stack と runtime event |
| .NET が止まったとき各 thread が待つ場所 | `dotnet-stack report --process-id PID` を間隔を置いて複数回 | 変わらない managed stack |
| native process の CPU の内訳 | `perf record -g -o FILE.data -- COMMAND`、続けて `perf report -i FILE.data --stdio --no-children` | 関数と DSO ごとの sample |
| file、network、lock の待ちと syscall の失敗 | `strace -f -tt -T -o FILE.trace -- COMMAND`。件数だけなら `strace -f -c -- COMMAND` | syscall、所要時間、戻り値、errno |
| native process の停止位置と thread | `gdb -q -batch -ex run -ex 'thread apply all bt' --args COMMAND ARG...`。hang は PTY で `run` し、停止後に割り込んで `thread apply all bt` | thread ごとの backtrace |
| CLI 全体の所要時間の分布 | `hyperfine --warmup 3 --runs N --export-json FILE.json 'COMMAND'` | 平均、標準偏差、min/max と各回の値 |
| Node.js の CPU を使う関数 | `node --cpu-prof --cpu-prof-dir DIR ENTRY.js` | `.cpuprofile` の self time と call tree |
| 複数 service を横断する遅延や例外 | Aspire Dashboard（後述） | trace、span、構造化 log |

`dotnet-counters` と `dotnet-trace` は、PID の代わりに末尾の `-- COMMAND` で自分が起動する子を対象にできる。
sampling profiler は CPU を使った時間を示し、I/O や lock で待つ時間は `strace` の `-T` か `dotnet-sampled-thread-time` で見る。
JIT した関数の名前を `perf` で解く必要があれば、自分が起動する process にだけ `DOTNET_PerfMapEnabled=1`（.NET）または `node --perf-basic-prof`（Node.js）を付け、生成された `/tmp/perf-<PID>.map` を回収の対象に含める。

## 採取の範囲を守る

- `strace`、`perf`、`gdb` は自分で起動する方法を既定にする。すでに動いている対象を採る必要があり許可がある場合は、道具が公開する PID 指定を使う。`gdb` の attach は対象を停止させるため、その停止も許可された場合だけ使う。
  この host で `ptrace_scope=1` のときは、対象が tracer を許可していない限り、子孫以外への ptrace は通常拒否される。`perf` は採取する event と kernel の制約を確認する。
- .NET の 3 CLI は、採取を許可された local process に限り、対象と同じ user と `TMPDIR` で PID を指定して接続する。
  長い `TMPDIR` で診断 socket に接続できない場合は、再起動してよい検証用の process に限り、`mktemp -d "$XDG_RUNTIME_DIR/dn.XXXXXX"` で作った短い私有 directory をその起動 command と診断 command の `TMPDIR` にだけ渡す。
  既存 process、session 全体の環境変数、project の設定は変えない。
- 権限や kernel の制限（`EPERM`、`perf_event_paranoid`、`ptrace_scope`）で採れない場合は、sysctl を下げず、採れなかった項目と理由を返す。
- trace、stack、syscall log には内部 path、token、個人情報が入り得る。
  `umask 077` で作業木の外に私有 directory を作って出力先を明示し、repository、共有 log、履歴 memory へ生の出力を置かない。
  共有する抜粋は秘匿化する。
- 高負荷の再現や長い計測は `dotfiles-workload-run --seconds N -- COMMAND` から起動する。
  監督器が報告した未起動と、起動後に採れた途中の計測を分ける。終了値だけから採取範囲を決めない。

## Aspire Dashboard で OTLP を読む

対象が OTLP を環境変数の設定で出力する場合だけ使う。
OTLP を出さない app や、OTLP の設定を環境変数で上書きできない app はこの経路で観測できないため、project の依存や code に計装を足すのは編集を許可された場合に限る。
Node.js では OpenTelemetry SDK を project が既に組み込んでいることを確認し、無ければ計装の不足として返す。

1. `aspire-dashboard status` を実行する。
   0 なら既に動いている Dashboard を使い、自分が起動したものでなければ停止しない。
   1 なら未起動なので自分で起動し、3 なら起動中のため 0 になるまで待つ。
2. 自分で起動する場合、`aspire-dashboard run` は前景で動き続けるため、名前を付けた background service として起動する。
   `aspire-dashboard status` が 0 になってから送信と読取を始める。
   instance は一つだけで、二重の起動は失敗する。
3. `aspire-dashboard exec --service NAME -- COMMAND` で対象を起動する。
   OTLP の送り先は wrapper が `127.0.0.1` の `18890` へ設定し、`4317` と `4318` は AI CLI の telemetry collector が使うため対象へ渡さない。
4. `aspire-dashboard otel traces --format Json --limit 50` で候補を探し、`--trace-id ID` で span の木を、`aspire-dashboard otel logs --format Json` で同じ時間帯の log を読む。
   失敗だけを見る場合は `--has-error true` を付ける。
   browser の token や API key を引数、file、出力へ書かない。
   metric は `aspire otel` では読めない。必要なら Dashboard UI の `Metrics` を使う。
5. 自分が起動した Dashboard だけを `aspire-dashboard stop` で止める。
   停止すると一時保存された telemetry は削除されるため、必要な trace と log を先に私有 directory へ保存する。

開発中に再現できる問題だけを対象にし、起動前に起きた障害の遡及調査や本番監視に使わない。

## 前後を比べて測る

変更の前後や二つの案の速さを比べる依頼では、変更そのもの以外の実行条件を揃える。同じ wrapper、build 構成、依存の版、入力と data、環境変数で同じ回数ずつ走らせる。依存の変更を測るなら、それ以外を揃える。
起動の順が片側に偏らないよう両側を交互に走らせ、各回の所要時間、終了 status、出力または生成物の確認結果を保存する。
失敗した回と、対象の処理が実行されたと確かめられない回は、所要時間の集計に混ぜず件数として返す。
両側の回数、中央値と範囲、失敗の件数を並べ、求められた差は何を割った値かを明示する。観測した範囲を越える性能保証とは区別する。

## 解釈して返す

採取ごとに、対象 process と版、起動 command または PID、workload、繰り返し回数、wrapper、時刻、出力 file の絶対 path を結び付ける。
一回の sample を回帰や改善の証明にせず、同じ条件で比べた値と、条件の違う値を分ける。
観測した事実（どの stack、syscall、span が時間を占めたか）と、そこから立てた原因の仮説を分け、仮説を確かめる次の採取か、呼出し元が判断する点を示す。
採れなかった項目、権限や kernel の制限、計装の不足は未確認として残す。

終了時は、自分が起動した対象 process、Dashboard、background job だけを止める。
呼出し元へ渡す capture は path と回収責任を伝え、自分だけが使った一時 file と perf map を消す。
提供された process、他者の Dashboard、既存の file は止めず、消さない。
