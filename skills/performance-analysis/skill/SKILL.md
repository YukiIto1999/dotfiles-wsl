---
name: performance-analysis
description: Identifies the measured bottleneck behind latency, throughput, CPU, memory, allocation, I/O, database, network, build, or browser performance problems. Use when performance is slow, regressed, variable, resource-heavy, or approaching a stated limit and the cause is not proven. Pins the workload and measurement conditions, decomposes the critical path and saturation, and tests causal hypotheses. Does not implement optimizations, set universal budgets, audit general code quality, or diagnose functional failures.
---

# 性能のボトルネックを分析する

成果は最適化案の一覧ではなく、どの条件で何が目標指標を支配しているかを示すmeasurement-backedな説明である。codeの見た目からanti-patternを探さず、原因を確かめる前に実装を変えない。

## 問いと尺度を固定する

利用者が観測している仕事、問題となる尺度、満たすべき条件を定める。

- latencyは平均だけでなく分布と必要なpercentileを扱う
- throughputはconcurrency、arrival model、backpressure、成功率と結ぶ
- CPU、memory、allocation、GC、I/O、network、lock、queueは単位と測定範囲を示す
- browserではfieldとlab、coldとwarm、device、network、route、interactionを分ける
- buildやbatchではinput size、parallelism、cache state、成果物の同一性を揃える

projectがSLO、budget、代表workloadを定めているならそれを使う。donorの固定閾値をproject要件へ置き換えない。要求が未定でも測定はできるが、速いか遅いかの規範判断とbottleneckの特定を分ける。
browser性能を分析する場合は、計測条件を固定してから`chrome-devtools` MCP targetでperformance trace、Core Web Vitals、heap、Lighthouseのうち仮説に必要な証拠だけを取得する。通常の画面操作を性能証拠の代わりにせず、このSkillが尺度、trace範囲、比較、因果判定を所有する。

## 比較可能なbaselineを作る

revision、hardware、OS、runtime、dependency、configuration、dataset、load shape、concurrency、cache、warmup、測定時間、sample数を記録する。比較するrunでは、調べる変数以外を揃える。

単発値や平均だけで結論を出さない。runごとの分布、variance、outlier、p50とtailを確認し、差がnoiseより大きいかを見る。production metric、trace、profileは実trafficを示す。synthetic benchmarkは条件を隔離する。片方だけで他方を証明したことにしない。

instrumentation自体のoverhead、sampling bias、coordinated omission、closed/open workloadの違いを確認する。比較不能な既存dataは捨てず、観測事実として残した上で因果判定には使わない。

## 待ち時間と仕事量を分解する

end-to-endのcritical pathは、queue、service、downstream wait、serialization、renderなどのwall-clock stageへ分ける。合計や差分に使うstageだけ、重複しない境界で測る。CPU、allocationとGC、filesystem、database、lock、networkはstageに重ねてよいresource attributionとして、profiler、query plan、heap、allocation profile、waterfall、runtime metricで測る。

resource利用率だけをbottleneckと呼ばない。次を区別する。

- service timeとqueueing time
- utilizationとsaturation
- wall timeとon-CPU time
- live memoryとallocation rate
- bytes、operation count、latency
- direct workとretry、duplicate、wasted work
- critical path上の仕事と並行して隠れる仕事

全repositoryを既知のanti-patternで検索する前に、metricかtraceが指すroute、process、query、span、resourceへ範囲を絞る。sourceは観測を説明する候補であり、遅そうに見えるcodeだけでは根拠にならない。

## 仮説を因果で確かめる

差分、profile、traceから必要な数だけ仮説を作る。各仮説に、正しければ変わるmetric、変わらないmetric、反証条件を書く。一度に一変数だけ変え、次のいずれかで確かめる。

- good/bad revision、host、dataset、configのdifferential
- commitやinput rangeのbisection
- query plan、call path、resource limitを隔離するcontrolled probe
- suspected workを除くか置き換えるshadow、replay、prototype
- loadやconcurrencyを変えたthroughput、latency、queueの曲線

bottleneckと呼べるのは、対象条件で目標指標のmaterialな部分を占め、その要因を隔離したprobeが同じ条件の指標を変える場合である。相関だけならcandidateとする。bottleneckを生んださらに深い理由が未確定なら、箇所の特定とroot causeを分ける。

正しさ、処理結果、error率、resource leakを犠牲にして速くなった結果は改善の証拠にしない。現在の依頼が分析だけなら、probeのためにproduction codeや運用設定を変更しない。

## 結果を返す

必要な項目だけを返す。

- workload、environment、revision、metric、測定方法
- baselineの分布、variance、比較可能性
- critical pathとresource saturationの内訳
- 確認したbottleneck、因果を支えるprobe、適用条件、確信度
- 反証した候補と重要な非bottleneck
- 未確定のroot cause、fieldへの外挿、不足している証拠

最適化候補を求められても、まずこの分析を終える。実装は確認したbottleneckを入力に別工程で行い、同じworkloadと測定方法で前後を比較する。機能上のerrorや誤出力と、実画面での利用者taskや使いやすさの監査は対象外とする。
