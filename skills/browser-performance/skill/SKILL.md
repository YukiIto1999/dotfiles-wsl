---
name: browser-performance
description: Measures and diagnoses browser loading, responsiveness, layout shifts, and network bottlenecks through the browser-diagnostics Capability. Use for a rendered page's non-LCP performance audit, slow interactions, CLS, request chains, or a mixed browser-performance problem whose bottleneck is not yet known. Links trace evidence to the real resource and source, distinguishes laboratory from field data, and delegates identified LCP and heap work to their specialists. Does not own native .NET/Rust profiling, .NET microbenchmarks, accessibility audits, generic bug diagnosis, or browser/account setup.
---

# Browserの性能を測定し、原因へ結び付ける

## 測定対象を固定する

依頼されたURL、environment、build revision、実際の利用者経路、入力、viewport、device、network、CPU、cacheとservice workerの条件を固定する。
利用者が報告した症状と、比較する指標、正常な状態、既存のtraceやfield dataを区別する。
変更許可と測定許可を別に扱い、診断依頼だけではsourceやbrowser設定を変更しない。

gatewayのbrowser-diagnostics toolを入口にし、sessionが公開したschemaを呼出し前に読む。
Chromeを別processとして起動したり、MCPやcontainerの設定、接続先、packageを追加しない。
`list_pages`で対象のURLとtitleを確認し、取得したpage IDをpage-scoped呼出しへ渡す。
別sessionのpage IDやPlaywrightのtab/refを流用しない。
既存pageのaccount切替、logout、storage消去、profileの初期化を行わない。

専用pageを作れる場合は作成時のIDを記録し、終了時には自分のpageだけを閉じる。
networkやtraceにはtoken、個人情報、非公開URLが含まれ得るため、artifactをlocalに保存し、共有する証拠は必要箇所だけを秘匿化する。

## 問いに合うtraceを取る

1. matchingする既存traceがあれば、その条件と対象区間を確認して再利用する。
2. loadingの問題では対象navigationを含むtraceを取り、返り値のinsight set ID、計測区間、実際に観測された指標を記録する。
3. interactionの問題では入力直前から結果のpaintまでを計測し、実際のcontrolへ操作を行う。
   eventの合成、APIやstorageの直接変更で利用者経路を代用しない。
4. `performance_analyze_insight`にはtraceが返したinsight名とIDを使い、版の異なる名前を推測しない。
5. traceや必要な指標を取得できなければ、その失敗と未測定項目を残す。
   sourceやnetworkで判断できる範囲は続けるが、速度改善やCWVの合格を推定しない。

reloadだけではcacheが空だった証拠にならない。
cache条件を確認できない測定をcold loadと呼ばず、loading traceだけでINPを測ったとも書かない。
一つのlab sampleをfieldのpercentileや実利用者全体のCWVへ置き換えない。
閾値を判定へ使う場合は、その指標、集計方法、対象platformの現行定義を`web-research`で確認する。

## Traceからresourceとsourceへ追う

観測したbottleneckに対応する証拠だけを取得する。

- loadingではdocument latency、render blocking、resource discovery、依存request chainを比較する。
- interactionではinput delay、event handler、main-thread task、style/layout、paintのどこに時間があるかを区別する。
- CLSではshiftの発生区間、影響element、直前に変わったsize、font、contentを結び付け、単なる見た目の動きと区別する。
- networkでは対象requestの開始、duration、transfer size、cache、priority、initiatorを調べ、必要なrequestだけ詳細を読む。

snapshotでelementのidentityを確認し、必要なDOM属性やcomputed styleだけを読み取り専用evaluateで調べる。
accessibility treeだけからcontrast、focus trap、layout shiftを判定しない。
requestが一回の経路で出なかったことを、全経路で不要なresourceの証明にしない。

sourceへアクセスできる場合は実際のmanifest、bundler設定、import、出力resourceとの対応を辿る。
名前だけでlibrary、barrel、polyfillを重いと判定せず、実際に配信されるbyte、実行cost、browser supportとcallerを確認する。
不要なcodeの削除は対象経路だけでなく、conditional loadや別consumerも調べてから提案する。
sourceがない第三者のsiteでは、観測したnetworkとDOMまでを根拠にし、server内部やbuild設定を断定しない。

## 専門の判断へ渡す

LCP自体が依頼の主題、またはtraceでLCPがbottleneckと確認された場合は、対象page、測定条件、trace ID、resourceと観測を`debug-optimize-lcp`へ渡す。
同じbaselineを二度取り直さず、専門Skillが必要とする不足だけを追加する。

heapの保持、detached DOM、操作反復後のmemory増加が疑われる場合は、`heap-analysis`が利用可能なら操作sequence、比較条件、local snapshotを渡す。
同Skillが使うheap-diagnostics Capabilityが利用不能なら、heap原因は未確認として返す。
heap用toolの不足をLCPやnetworkの測定で埋めない。

browserのheap captureを依頼された場合は、対象page、取得許可、操作sequence、GCと終了条件を固定してから、公開された`take_heapsnapshot`のschemaを確認する。
captureの間にpageを停止させる影響と、snapshotに秘密情報が含まれる可能性を確認し、許可されたprivateな絶対pathへ保存する。
保存先がtoolのworkspace境界から拒否された場合は、repositoryへの保存、symlink、別providerの直接起動で回避しない。
capture不能とその境界を返し、未取得のsnapshotを`heap-analysis`へ渡したことにしない。

accessibilityの実画面監査は`a11y-debugging`、既知の受入条件のPlaywright verificationは`browser-operation`へ渡す。
.NETの比較microbenchmarkは`microbenchmarking`、MSBuild性能は`msbuild`、native codeや一般の故障のfeedback loopは`diagnosing-bugs`が所有する。

## 原因と比較を閉じる

変更案ごとに、症状、計測区間、resourceまたはsource、原因仮説、反証条件、最小の変更を一続きで示す。
insightのestimated savingsは推定と明示し、実測の改善量に混ぜない。
byte削減だけで応答改善を保証せず、測定noiseより小さい差を改善と断定しない。

変更と再測定が許可された場合だけ、一つの原因を変え、同じ条件と経路で比較する。
request成功、content、interaction、必要なcacheやsecurity条件が保たれることも確認する。

結果には条件、実測した指標、traceまたはrequestの証拠、原因とsourceの対応、提案または実施した変更、比較のばらつき、未測定項目を含める。
証拠で支えられる結論が出たら止め、関係しない全項目の監査を追加しない。
