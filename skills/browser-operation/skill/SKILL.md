---
name: browser-operation
description: Executes a specified user task or verifies a known implemented surface in a real browser through the configured Playwright MCP. For acceptance verification, derives material scenarios, transitions, content and viewports from requirements and changed paths, inspects rendered screenshots, and checks user-visible business results, rejection, recovery and persistence with fresh DOM actions. Returns a claim-to-evidence matrix and untested conditions. Does not design UI, author permanent test suites, audit accessibility or security, measure performance, diagnose root causes, or make unspecified changes in a real account.
---

# 実画面と業務結果を対にして確かめる

成果はpageを開いた記録ではなく、利用者が目的を達成できるかを、実画面と操作結果で判定した証拠である。
DOMに文言があること、clickが成功したこと、HTTPが200であることだけでは受入完了にしない。

指定taskの実行では、許可された結果へ至る実経路を完了する。
実装のverificationでは、以下のmatrixを作り、選んだ経路を実行し、各主張を`pass`・`fail`・`未確認`で閉じる。
検証に必要なscenarioの選択はこのSkillが所有し、利用者に画面確認や異常系を一つずつ指示させない。

## 1. 要求と変更を観測可能なmatrixへ写す

依頼、受入条件、確定済みUI brief、repositoryの仕様、既存scenarioとfixtureを読む。
変更のverificationなら変更pathからroute、form、表示、保存・取得経路、shared UIの関連consumerを辿り、今回影響する利用者taskを特定する。
pathは検証範囲の根拠であって、期待値の正本ではない。
実装の現在値を期待値へ写さず、要求のsource locatorを各主張に付ける。

URL、起動方法、test data、表示条件はrepositoryと現在のbrowser状態から解決する。
確定できない期待結果は仕様不足、到達できない状態は前提不足として区別し、判定可能な行は続ける。
既知surfaceの受入を、未知のproduct全体の探索へ広げない。

実行前に必要な行だけを次の形で固定する。
行は操作回数でなく、一つの観測可能な保証を表す。

| 主張と要求の出典／関連変更path | 初期状態・data | 入力と状態遷移 | 期待する業務結果／拒否時に変わらないもの | 実画面checkpoint | viewport・入力方法と選ぶ理由 | 許可・前提／結果と証拠 |
|---|---|---|---|---|---|---|
| 保存の結果を一覧で確認できる | 許可済みfixtureの既存件数と値 | 入力 → 保存 → 結果一覧 | 入力した対象・値・件数が一致し、重複しない | form、完了後の一覧とsummary | 実際の利用条件 | 操作範囲、後で観測を記入 |
| 不正入力を直して完了できる | 契約が拒否する入力と変更前の結果 | 拒否 → 修正 → 同じtaskを完了 | 問題と直し方が分かり、未確定の変更が残らず、契約どおり入力を保持 | errorと修正control、回復後の結果 | errorやcontrolの配置が変わる条件 | 副作用のない拒否を使う |
| 保存結果を再取得できる | 保存済みの識別可能な対象 | reloadまたは別routeから再訪 | 契約が永続化する値・件数が再表示される | 再取得後の結果 | 保存・取得経路に影響する条件 | 契約が保存を保証するときだけ含める |

例の三行を無条件にコピーしない。
今回の要求に合わせて、次の順に選ぶ。

- 明示された受入条件をすべて行へ対応させ、主要taskは入口から業務結果の確認まで閉じる。
- 変更が触れる入力条件、表示分岐、状態遷移について、成功だけでは区別できないmaterialな拒否・回復・空状態・競合などを選ぶ。
  状態名の列挙ではなく、その状態を起こす許可されたdataと次の操作を書く。
- 保存、編集、削除などの契約がある場合は、成功表示の先にある結果と、必要な再取得を含める。
  保存を伴わないtaskへreload後の保持を要求しない。
- contentやresponsive変更なら、実dataの長い文言、件数、locale、折り返し、navigationの切替など、変更を壊し得る代表条件を選ぶ。
  viewportの幅と高さは対象projectの対応範囲、breakpoint、利用条件から定める。
  配置や操作が変わる境界には両側の代表を割り当て、同じ挙動の幅を機械的に増やさない。
- shared UIでは、変更した性質が異なる使われ方をするconsumerを代表として選び、なぜ他を同等と扱うかを残す。
  異なる結果、回復経路、配置を、同じcomponentという理由だけでまとめない。

未選択のmaterialな条件と理由をmatrixに併記する。
明示条件を代表例で省略したり、scenario数、全viewport、点数をcoverageの目標にしたりしない。
幅のresizeだけを実端末、touch、software keyboard、別browserの確認として数えない。
特定taskの実行依頼には、結果に不要な拒否操作やviewport変更を足さない。

## 2. 公開browserと所有するpageを固定する

`browser-automation` Capabilityが公開するPlaywright toolを使う。
本文の`playwright.browser_*`は論理名なので、現在のclientが公開する実tool名とschemaを読む。
URI deviceなら`xd://mcp__gateway_playwright_browser_tabs`などへJSON引数を渡し、直接MCPならそのネイティブ形式を使う。
到達不能やtool未公開は未確認として返し、別browser、provider、containerを直接起動しない。

最初に`browser_tabs`の`action: "list"`でURLとtitleを確認する。
既存tabを使う必要がなければ`"new"`で専用tabを作り、開始時のtab一覧と自分が作ったtabを記録する。
専用tabはaccountやstorageの隔離を意味しない。
許可されたtest account・environment・dataを別に確認する。

選択と終了は現在の一覧の`index`を使う。
tabの作成・終了、他agentの操作で対象が変わり得る場合は一覧を取り直して選択し、URLと状態を確かめる。
Playwrightのtab indexをChrome DevToolsのpage IDと混同しない。
navigationは確定した入口へ行う。

`browser_run_code`が公開されている場合も、引数として渡されるnativeな`page`を使う。
fresh DOMから一意なlocatorを解決し、同じpageで操作と観測を行う。
browserをlaunch/connectし直す、contextや別pageを勝手に作る、`pages()[0]`を推測で選ぶ、`page.request`などでUIを迂回する経路は使わない。

## 3. Fresh DOMで動かし、rendered screenshotを読む

各scenarioを、初期状態 → 操作 → 待機 → 業務結果と実画面の照合、の順で進める。

1. 対象tabで`browser_snapshot`を取り、現在のaccessibility tree、文言、control、値、状態を読む。
   判別できない属性だけを読み取り専用の`browser_evaluate`で補う。
   ref方式ではこのsnapshotのrefを使い、native page方式ではrole・label・text、明示されたtest IDで一意なlocatorを解決する。
2. matrixの入力を通常のclick、入力、key操作で実行する。
   同じformの複数fieldは公開されている`browser_fill_form`を優先する。
   JavaScriptでevent、API、storage、DOM、styleを書き換えてtaskや不具合を迂回せず、`force`で届かないcontrolを押さない。
3. 成否の文言、処理中表示の消失、期待URLやcontrolの状態など、今回の結果を示す条件で待つ。
   公開された`browser_wait_for`、native locatorの待機などを使い、固定sleepや`networkidle`を完了の代わりにしない。
   one-shotの値取得は条件が成立した後の観測であり、自動retryする判定と同じではない。
4. navigation、submit、route変更、dialog開閉、一覧更新、viewport変更などの後はsnapshotを取り直す。
   新しいrefまたは現在のDOMから次の操作を決める。
   値が同じでも別状態の古いrefを再利用しない。
5. verificationでは、matrixで選んだmaterialな実画面checkpointを`browser_take_screenshot`で撮り、返された画像を実際に開いて読む。
   主要taskの操作面と業務結果、関連する拒否・回復や別layoutの代表状態を含める。
   保存したpath、DOM snapshot、画像比較のpassだけで目視済みとしない。
6. 画像では要求に関係する内容と結果が読めるか、欠け・重なり・切れ・折り返し・画像欠落・sticky領域による隠れがないか、次のcontrolが見えるかを照合し、何がどこで見えた／見えなかったかを書く。
   見た目の好みや新しいUI設計を受入基準へ足さない。

実viewportのscreenshotを既定にする。
full-pageはscroll可能な全体を写すため、初期viewport内で見えることの証拠にはしない。
下方の結果やcontrolは、通常のscroll経路で到達してそのviewportを撮る。
element画像は該当箇所の補助であり、周辺との重なりを確かめる代わりにはしない。

画像はvisual evidence、snapshotとDOMは意味・値・操作対象の証拠として対にする。
DOMのvisible判定だけでは、透明な表示や視覚的な隠れまで保証しない。
screenshotから座標や操作対象を推測せず、不一致を見つけたらfresh snapshotまたは読み取り専用DOMで対象を特定する。

保存は公開output契約に従う。
`filename`がrelativeを推奨するtoolではoutput directory内の相対名を使い、絶対pathが許可される場合だけその契約で確認した非公開directoryを指定する。
返された画像またはartifactを実際に読めた範囲を記録し、callerの`TMPDIR`や別processのpathを同じ保存先と仮定しない。
画像を読めない場合は機能の観測だけを返し、該当visual行を未確認にする。
保存拒否を共有directory、symlink、provider設定の変更で回避しない。

## 4. 業務結果、拒否、回復、保存を閉じる

matrixの期待値と実観測を各遷移の直後に照合する。
最後だけを見ると途中の誤りが消えるため、拒否時と回復時も別に観測する。

- 成功toast、dialogの閉鎖、URLの変化の先にある、対象の名前・値・件数・集計・状態などを確かめる。
  要求された利用者taskの出力まで一致して初めて業務結果をpassにする。
- 拒否では、問題と修正方法、契約が保持する入力、未確定の値・件数・状態が変わっていないことを確認する。
  disabledなsubmitの存在だけを回復の証拠にしない。
- 回復では、示された修正・取り消し・再試行の経路を通常のUIで辿り、taskを完了できるか、契約が防ぐ二重確定がないかを確かめる。
  失敗表示を消しただけで回復済みにしない。
- 永続化の保証がある場合は、許可されたreloadや再訪で対象を再取得し、保存値と件数を照合する。
  再表示が示す保証の範囲を限定し、browser storageの保持だけからserver保存、別端末共有、transactionの正しさを主張しない。
- 非同期の拒否・競合・遅延は、対象projectが用意した許可済みfixtureやUI経路で起こす。
  到達手段がなければその条件を未確認にし、無断でnetwork mock、offline化、API直叩き、storage変更を作らない。
  transientな処理中状態を見られなかった場合も、見えたと補わない。

consoleは受入条件または観測した異常に関係する場合、networkは対象requestの発生・method・endpoint・statusが結果判定に必要な場合だけ調べる。
nativeなrequest待機が必要なら操作前に登録し、対象requestが契約上発生するかを先に確かめる。
request成功を利用者の結果の代わりにせず、static resourceや不要なbody・headerを収集しない。
「console errorなし」は、対象操作を含む区間を実際に読んだ場合だけ述べる。

不一致は期待と実際、初期状態、入力列、viewport、直前・直後のsnapshotと画像を残す。
既知の失敗を推測でpassへ戻さず、独立した残りの行は副作用なしに実行できる場合だけ続ける。
原因診断やfrontend修正へ自動で広げない。

## 利用者accountと外部結果を守る

閲覧、navigation、未送信入力と、accountや外部systemへ結果を残す操作を分ける。
購入、課金、message・招待の送信、公開、削除、権限・security設定・profile変更、file upload、注文確定などは、verification依頼だけを実行許可と解釈しない。
許可されたsandboxまたは専用test accountを使い、実accountしかない場合は確定直前の安全な状態までを観測し、未実行の結果は未確認にする。

現在の依頼で対象と結果が具体的に指定され、その結果の発生を明示的に求められた場合だけ、指定範囲内で一度実行する。
account、environment、数量、宛先が曖昧なら実行しない。
submitの結果が不明なまま再送せず、画面と必要な対象requestを先に確認し、重複可能性が残れば止める。
予期しない認証要求、dialog、環境違いを推測で突破しない。

credential、token、cookie、個人情報を抽出・出力せず、画像にも不要な個人情報を含めない。
既存tabでlogout、account切替、保存状態の消去をしない。
fixtureや作成dataの削除も許可範囲内に限る。
意図しない変更は追加操作を止め、観測状態と影響可能性を返す。

## 5. 証拠と未確認を返し、所有物だけを閉じる

結果は最初のmatrixに返す。
各行に実行した初期状態・data・入力列、期待と実際、`pass`・`fail`・`未確認`、snapshot/DOMの該当結果、画像locatorと具体的なvisual観測を付ける。
業務値と見た目の結果が異なれば分けて報告し、一方のpassで他方を隠さない。

対象environment・URL・許可範囲、実viewportと入力方法、coverageの選択理由、実行しなかったmaterial条件と理由を添える。
未確認は、仕様不足、data/環境不足、tool不足、安全上の停止、未選択を区別する。
単なる未選択を、対象外またはpassとしない。
実行したbrowser経路を永久test suiteや全条件の保証として報告しない。

証拠を取得した後、現在のtab一覧と開始時の一覧を照合し、このSkillが作成したtabだけを`browser_tabs`で閉じる。
再利用したtab、他agentや利用者のtab、browser全体を終了しない。
再利用したpageのviewportなどを変更した場合は、記録した開始値へ安全に戻せる範囲で戻す。
cleanupが外部変更を増やす場合は行わず、残る状態を報告する。

## 境界とhandoff

受入結果と専門監査は別の成果である。
accessibility treeを操作に使ったこと、keyboardで一経路を通ったこと、見た目を読んだことはaccessibility適合を意味しない。
待機して画面が出たことは性能閾値の達成、認証したことや拒否が一件出たことはsecurityの保証ではない。

別専門作業が依頼された場合だけ、利用可能なSkillへ次を渡し、元のmatrixと専門結果を区別してcallerへ返す。

| 条件 | 引き渡す入力 | 受け取る結果 |
|---|---|---|
| 実装前のUI判断・未確定な設計を決める | `ui-design`へtask、実content、要件の不足、観測したstateと画像、既存制約 | UI briefと設計判断。今回の観測を設計入力へ戻す |
| 実画面のaccessibility監査 | `a11y-debugging`へsurface、入力方法、対象state、設計要件、snapshotと画像 | 所見、確認した基準、未確認。受入passへ混ぜない |
| 機能不良の原因診断 | `diagnosing-bugs`へ期待と実際、入力列、前後の証拠、関連errorとsource | 原因を支える証拠と次の検証・修正判断 |
| interaction、layout shift、networkなどの性能計測 | `browser-performance`へURL、経路、環境と測定条件、観測した遅延 | 実測値と不足。LCP・page loadなら`debug-optimize-lcp`へ同じ入力を渡す |
| JavaScript heap保持の調査 | `heap-analysis`へ操作・終了sequence、反復条件、取得済みsnapshotがあれば非公開path | 保持経路と寿命、比較で確かめたこと |
| 脅威や脆弱性の調査 | `security-review`へscope、信頼境界、経路、観測証拠と関連source | 検証された所見と不足証拠 |

利用不能な専門作業は未実施として返し、同じ操作をhandoffだけのために繰り返さない。
このSkillは既知surfaceの実行と受入証拠を所有し、永久testの作成、CIの設定、全productの探索、API代替verification、credential管理を所有しない。
新たな回帰testが必要なら、破った保証、再現入力列、観測証拠をcallerへ渡し、対象projectのtest ownerに実装を委ねる。
