---
name: browser-performance
description: Measures and diagnoses browser loading, responsiveness, layout shifts, and network bottlenecks through the browser-diagnostics Capability. Use for a rendered page's non-LCP performance audit, slow interactions, CLS, request chains, or a mixed browser-performance problem whose bottleneck is not yet known. Links trace evidence to the real resource and source, distinguishes laboratory from field data, and delegates identified LCP and heap work to their specialists. Does not own native .NET/Rust profiling, .NET microbenchmarks, accessibility audits, generic bug diagnosis, or browser/account setup.
---

# Browserの性能を測定し、原因へ結び付ける

## 測定対象を固定する

依頼されたURL、environment、build revision、実際の利用者経路、入力、viewport、device、network、CPU、cacheとservice workerの条件を固定する。
利用者が報告した症状と、比較する指標、正常な状態、既存のtraceやfield dataを区別する。
変更許可と測定許可を別に扱い、診断依頼だけではsourceやbrowser設定を変更しない。

`browser-diagnostics` Capabilityのgatewayに公開されたChrome DevTools toolを入口にし、呼出し前に現在のschemaを読む。
本文の短い操作名を、現在のclientが公開した実tool名とschemaへ対応させる。
URI deviceを公開するclientでは`xd://mcp__gateway_chrome_devtools_list_pages`などの入口へJSON引数を渡す。
MCP toolを直接公開するclientでは、そのネイティブな呼出し形式を使い、URI deviceがあると仮定しない。
Chromeを別processとして起動したり、MCPやcontainerの設定、接続先、packageを追加しない。
`list_pages`へ`{}`を渡してURL、title、page IDを確認し、`pageId`を要求する呼出しにはそのIDを渡す。
選択中のpageに作用するschemaなら、先に`select_page`の`pageId`で対象を選ぶ。
専用pageは`new_page`の`url`で作成し、`take_snapshot`が返した最新の`uid`を`click`やform操作へ渡す。
別sessionのpage IDやPlaywrightのtab/refを流用しない。
会話の再開や同じ会話IDは、providerのpageやtraceが残っている証拠にはならない。
再開時は公開toolで現在のpageとtraceの可用性を確かめ、元のsessionの状態が失われていた場合は、取得済みartifactで判断できる範囲と再接続後に未観測の範囲を分ける。
既存pageのaccount切替、logout、storage消去、profileの初期化を行わない。

専用pageを作れる場合は作成時のIDを記録し、終了時には自分のpageだけを閉じる。
networkやtraceにはtoken、個人情報、非公開URLが含まれ得るため、artifactをlocalに保存し、共有する証拠は必要箇所だけを秘匿化する。
fileをexportするときは、次の非公開artifactの受け渡しを使う。
providerの保存先とcallerに割り当てた`TMPDIR`は別のprocessの契約として扱い、callerの環境変数を書き換えない。

## 問いに合うtraceを取る

1. matchingする既存traceがあれば、その条件と対象区間を確認して再利用する。
2. loadingでは対象URLへのnavigation後に`performance_start_trace`へ`pageId`と`reload: true`を渡し、対象navigationを含める。
   `autoStop: true`で完了した結果か、自分で開始したtraceに対する`performance_stop_trace`の結果から、insight set ID、計測区間、実際の指標を記録する。
3. interactionでは`reload: false`、`autoStop: false`で入力直前に開始し、実controlを操作して結果のpaintまで観測した後、同じ`pageId`で停止する。
   eventの合成、APIやstorageの直接変更で利用者経路を代用しない。
   clickの次のpaintで終わる指標と、非同期responseの後に結果が表示されるまでの待ち時間を混ぜない。
   結果が非同期に更新される経路では、同じtrace内のrequest終了、response処理、後続のmain-thread work、layout、結果のpaintを時系列で対応させ、区間ごとの実測値とsourceを示す。
   inputから最初のpaintまでの値だけで後続の停止を説明せず、見えていない区間の時間やnetworkの寄与をsourceの定数から推定して測定値にしない。
4. `performance_analyze_insight`へ同じ`pageId`と、traceが返した`insightSetId`、`insightName`を渡し、版の異なる名前を推測しない。
5. traceや必要な指標を取得できなければ、その失敗と未測定項目を残す。
   sourceやnetworkで判断できる範囲は続けるが、速度改善やCWVの合格を推定しない。

reloadだけではcacheが空だった証拠にならない。
cache条件を確認できない測定をcold loadと呼ばず、loading traceだけでINPを測ったとも書かない。
一つのlab sampleをfieldのpercentileや実利用者全体のCWVへ置き換えない。
閾値を判定へ使う場合は、指標、集計方法、対象platformとversionを`web-research`へ渡し、現行定義と一次sourceを受け取ってから照合する。
同Skillが利用不能で定義を確認できなければ、実測値だけを返し、未確認の閾値による合否を付けない。

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

## 非公開artifactの受け渡し

Chrome providerは、frontが所有するmode `0700`のruntime directoryを自身の`TMPDIR`とfilesystem rootに使う。
trace、screenshot、heapのfile exportは同じ保存先と回収手順を使う。

1. Capabilityが宣言する`runtimeDirectoryPath`を保存先として使う。
   現行の`browser-diagnostics` frontでは`/run/mcp-front-chrome-devtools`であり、公開された配備契約と異なる場合はその契約のpathを確認してから使う。
   現在の利用者が所有するmode `0700`の実directoryであることを確認する。
   directoryがない、symlinkである、所有者やpermissionが異なる場合は、変更せずCapabilityの配備不備として返す。
2. 確認したruntime directory内に`mktemp -d`で自分専用のmode `0700`のstagingを作り、公開toolの`filePath`へその中の絶対pathを渡す。
   解析と保持のためには、callerの割り当て済み`TMPDIR`内にも別の非公開directoryを作る。
3. capture成功後はfileをmode `0600`にしてcallerのdirectoryへ移動し、空になった自分のstagingだけを回収する。
   後続の解析へは移動後の絶対pathとcapture条件を渡し、終了時は自分のfileとdirectoryだけを回収する。
4. captureや転送に失敗した場合は自分のstaging内のpartial fileを回収し、未取得または未転送のartifactを成功と扱わない。
   providerのruntime directoryでもpathが拒否された場合は、配備済みwrapperのfilesystem rootとproviderの保存先の不一致を返す。

拒否された保存先をrepository、symlink、共有`/tmp`へ変えたり、workspace全体の許可、任意page code、別providerの直接起動で回避しない。
同じ拒否を確認するためだけにexportを再試行しない。

## 専門の判断へ渡す

LCP自体が依頼の主題、またはtraceでLCPがbottleneckと確認された場合だけ、利用可能な`debug-optimize-lcp`へ対象page、測定条件、traceの返却IDまたはartifact、resourceと観測を渡す。
LCPの原因と比較結果を受け取り、元の性能結果へ統合する。
同じbaselineを二度取り直さず、専門Skillが必要とする不足だけを追加する。
同Skillが利用不能なら取得済みtraceを返し、未実施のLCP専門診断を明示する。

heap保持、detached DOM、操作反復後のmemory増加が疑われる場合は、利用可能な`heap-analysis`へ操作と終了sequence、比較条件、取得済みlocal snapshotを渡し、保持経路と実装上の寿命の結果を受け取る。
snapshotが不足する場合は次のcapture手順で許可された分だけ取得する。
heap-diagnostics Capabilityまたは専門Skillが利用不能なら、取得済みの観測を返し、heap原因は未確認とする。
heap用toolの不足をLCPやnetworkの測定で埋めない。

browserのheap captureを依頼された場合は、対象page、取得許可、操作sequence、GCと終了条件を固定し、`take_heapsnapshot`の現在のschemaへ`pageId`と非公開staging内の絶対`filePath`を渡す。
captureの間にpageを停止させる影響と、snapshotに秘密情報が含まれる可能性を確認し、非公開artifactの受け渡しで保存と転送を行う。
`heap-analysis`からの取得依頼はcapture-onlyとして扱い、転送後のpath、capture条件、観測した終了点、fileの回収責任を同じcallerへ返して止める。
この取得経路から`heap-analysis`を再呼出ししない。
capture不能ならその境界と不足する配備契約を返し、未取得のsnapshotを渡したことにしない。

実画面のaccessibility監査が必要なら`a11y-debugging`へ対象page、入力方法、該当controlと観測証拠を渡し、検証された問題と未確認事項を受け取る。
既知の受入条件のverificationが必要なら`browser-operation`へURL、許可されたaccountと操作、経路、期待結果を渡し、条件ごとの観測結果を受け取る。
.NETの比較microbenchmarkは`microbenchmarking`へ対象、baseline、workloadと実行条件、MSBuild性能は`msbuild`へprojectと遅いcommand、logと環境を渡す。
native codeや一般の故障の原因診断は`diagnosing-bugs`へ症状、再現経路、期待と実際、関連sourceを渡す。
これらの別専門作業は依頼に含まれ、Skillが利用可能な場合だけ行い、結果をcallerへ返して元の測定scopeへ戻る。
利用不能なら証拠と未実施の仕事を返し、別手段で専門診断を済ませたことにしない。

## 原因と比較を閉じる

変更案ごとに、症状、計測区間、resourceまたはsource、原因仮説、反証条件、最小の変更を一続きで示す。
insightのestimated savingsは推定と明示し、実測の改善量に混ぜない。
byte削減だけで応答改善を保証せず、測定noiseより小さい差を改善と断定しない。

変更と再測定が許可された場合だけ、一つの原因を変え、同じ条件と経路で比較する。
request成功、content、interaction、必要なcacheやsecurity条件が保たれることも確認する。

結果には条件、実測した指標、traceまたはrequestの証拠、原因とsourceの対応、提案または実施した変更、比較のばらつき、未測定項目を含める。
証拠で支えられる結論が出たら止め、関係しない全項目の監査を追加しない。

終了時は、自分で開始した未停止のtraceだけを公開`performance_stop_trace`で停止し、自分で作成したpageだけを`close_page`の`pageId`で閉じる。
最後のpageなど公開toolが終了を拒否する場合はbrowser全体を終了せず、残したpageと理由を返す。
callerへ渡したartifactは合意した保持と回収責任に従い、他のsessionのpage、trace、fileは回収しない。
