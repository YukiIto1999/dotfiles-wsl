# Web pageのrouteと操作

## Routeを選ぶ

利用者のログイン済みtabを指定された場合は、通常の優先順より先に、明示されたtabを公開しているOMP RelayまたはOrcaの内蔵browserを選ぶ。どちらも公開せず、そのtabがWindows上の利用者のbrowser windowにある場合は、[Windows](windows.md)のroute 2で既存のwindowとして扱う。
対象のtab、account、profileを照合できなければ未確認にする。隔離されたPlaywright MCPで別tabを開いたり、別profileへログインし直したりしない。
それ以外の既存tab、実account、Orcaの外のbrowser profile、Orca appの画面も、その対象を公開するrouteだけで扱う。

| 順 | route | 使う条件 |
|---|---|---|
| 1 | Orcaの内蔵browser | Orca projectの中でOrca CLIの読み取りcommandが現在のcwdのworktreeを返し、対象が開発server、fixture、localhostなどのlocal UIである |
| 2 | clientの標準browser tool | 対象を扱えるtoolをsessionが現在のschemaとともに公開している |
| 3 | Orcaの内蔵browser | 2で対象を扱えず、Orca CLIの読み取りcommandが現在のcwdのworktreeを返し、対象が利用者の既存tabや実accountを必要としない |
| 4 | `browser-automation`のPlaywright MCP | 上の操作routeで対象を扱えず、Playwright MCPが現在のclientに公開されていて、独立したbrowser sessionで検証できる |
| 5 | `browser-diagnostics`のChrome DevTools MCP | 上の経路では実行できず、現在のtoolが対象と必要な操作を隔離したpageで扱える |
| 6 | なし | 上の条件を満たすrouteがない |

OMPで利用者のbrowserを必要としない操作には、標準browser toolで管理browserを明示し、既定のRelayに委ねない。

別のbrowser、provider、containerの起動、既存processへの接続、Orcaやbrowserの導入・起動・pairing・設定変更、画面全体の操作による代替は行わない。
利用者がChrome DevTools MCPを指定し、そのtoolが対象を扱える場合は、上の優先順にかかわらず使う。
Chrome DevTools MCPでは、現在のschemaで公開された専用pageの作成、snapshot、操作、待機、screenshotを使う。
既存tabと実accountの条件は緩めない。fileの保存先は`browser-performance`の非公開artifactの受け渡しに従う。
Orcaが無い、使えないことは次のrouteへ進む条件であり、Orcaの利用や導入を要求しない。
Windows上のbrowserでしか判定できない要求でなければ、WebをWindowsのseatで操作しない。

どのrouteでも、開始時のtab一覧と、自分が作成したtabを識別する値（page ID、なければ一覧のindexとURL）を記録する。

### Orcaの内蔵browser

- 実行ファイルの解決と版一致のguideは`orca-cli`の入口に従い、guideのbrowser gateが示すbrowser referenceを読んでから操作する。
  command名、引数、出力の形はその版のguideと`--help`を正とし、bare `orca`は実行しない。
- Orcaが起動していない、接続が拒否された、cwdがOrcaのworktreeでない、guideを取得できない場合は、このrouteなしとして次へ進む。
  `open`でOrcaを起動・再起動しない。
- cwdのworktreeのidを読み取りcommandで取得して控え、tabの一覧と作成を含むすべてのbrowser commandへ明示する。
  既定の対象はUIでactiveなworktreeとtabであり、このsessionのworktreeと一致するとは限らず、他projectのtabを返し得る。
- 開始時の一覧をそのworktreeで取り、専用tabを作るか、同じworktreeにある明示された既存tabを照合する。guideが示すpage IDを記録して、以降のすべてのpage操作に渡す。
  既定のtab、他のworktree、全worktreeを対象にしない。
- pageをhostするdesktopが応答しない不達は、状態変更の前ならrouteなし、後なら不明な結果として扱う。
- browser profileに残るsessionは利用者のaccount権限である。
  cookieの取得や、profileの作成・切替・複製で権限を広げない。
- snapshotのrefはtabごとで、navigationやtab切替で失効する。

### 標準browser toolとPlaywright MCP

本文の論理名を、現在のclientが公開する実tool名とschemaへ対応づけてから呼ぶ。
OMPは、標準browser toolを公開するsessionでPlaywright MCPを読み込まない（harnessが同種のbrowser serverを除外する）。
Playwright MCPが現在のclientに公開されていなければ、4は使えないrouteとして5へ進む。
5も使えない場合だけ、状態変更前に限り、対象URL、許可されたdataと操作、matrixをcallerへ返し、MCPの接続や設定を追加しない。操作結果が返るまでは未確認とする。

Playwrightのtabは現在の一覧の`index`で選び、作成や終了で変わるため、操作の前に一覧を取り直す。
既存tabを使う必要がなければ専用tabを新規に作る。
Playwrightのtab indexをChrome DevToolsのpage IDと混同しない。
navigationは確定した入口へ行う。

`browser_run_code`が公開されている場合も、引数として渡されるnativeな`page`を使う。
fresh DOMから一意なlocatorを解決し、同じpageで操作と観測を行う。
browserをlaunch/connectし直す、contextや別pageを勝手に作る、`pages()[0]`を推測で選ぶ、`page.request`などでUIを迂回する経路は使わない。

## Fresh DOMで操作する

- 対象tabでsnapshotを取り、現在のaccessibility tree、文言、control、値、状態を読む。
  判別できない属性だけを、routeが公開する読み取り専用のpage評価で補う。
  ref方式ではこのsnapshotのrefを使い、native page方式ではrole・label・text、明示されたtest IDで一意なlocatorを解決する。
- 同じformの複数fieldは、公開されている一括入力を優先する。
  JavaScriptでevent、API、storage、DOM、styleを書き換えず、`force`で届かないcontrolを押さない。
- 公開された待機（text、URL、selector、loadなど）やnative locatorの待機を使い、固定sleepや`networkidle`を完了の代わりにしない。
  one-shotの値取得は条件が成立した後の観測であり、自動retryする判定と同じではない。
- navigation、submit、route変更、dialog開閉、一覧更新、viewport変更などの後はsnapshotを取り直し、新しいrefまたは現在のDOMから次の操作を決める。

## Screenshotとviewport

実viewportのscreenshotを既定にする。
full-pageはscroll可能な全体を写すため、初期viewport内で見えることの証拠にはしない。
下方の結果やcontrolは、通常のscroll経路で到達してそのviewportを撮る。
element画像は該当箇所の補助であり、周辺との重なりを確かめる代わりにはしない。
routeがviewportを公開された手段で変えられない場合は、実測した現在のviewportだけを証拠にし、他の幅の行は未確認にする。
DOMのvisible判定だけでは、透明な表示や視覚的な隠れまで保証しない。

保存はrouteの現在の契約に従う。
`filename`のようにrelativeを推奨するtoolでは出力directory内の相対名を使い、絶対pathが許可される場合だけその契約で確認した非公開directoryを指定する。
Playwright MCPの出力directoryはsessionの終了で回収されるため、読める間に本文の保存先へcopyする。
callerの`TMPDIR`や別processのpathを同じ保存先と仮定しない。

## Consoleとnetwork

consoleは受入条件または観測した異常に関係する場合、networkは対象requestの発生・method・endpoint・statusが結果判定に必要な場合だけ調べる。
nativeなrequest待機が必要なら操作前に登録し、対象requestが契約上発生するかを先に確かめる。
request成功を利用者の結果の代わりにせず、static resourceや不要なbody・headerを収集しない。

## 閉じる

現在のtab一覧と開始時の一覧を照合し、作成したtabだけを、記録したidで選んだrouteのtab操作により閉じる。
再利用したpageのviewportなどを変更した場合は、記録した開始値へ安全に戻せる範囲で戻す。
