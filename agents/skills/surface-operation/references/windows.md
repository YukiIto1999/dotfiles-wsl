# Windowsのappのrouteと操作

## Routeを選ぶ

| 順 | route | 使う条件 |
|---|---|---|
| 1 | AnodeのWindows子session（seat）をWSLの`anode` CLIで操作する | 対象がWindowsのapp、またはWindows上のbrowserでしか判定できない要求で、利用者が指定した既存のwindowではなく、利用者の入力と画面から分けて操作できる |
| 2 | Orca Computer Use（`orca-computer-use`）で利用者のdesktopの既存windowを背景から操作する | 利用者が自身のdesktopにある既存のwindowやappを指定し、下の「既存のwindowを扱う」の前提を満たす |
| 3 | なし | 上の条件を満たすrouteがない |

利用者自身のdesktopにある既存のwindowやappを指定された場合は、route 2だけを使う。
seatで同じappを開き直して代用せず、route 2が使えなければその行を未確認にする。
「既存のwindowを扱う」より前の節はroute 1の手順である。

導入、配備、機械の設定の正本は、dotfilesの`docs/tools.md`の「Windows の独立した操作画面（Anode）」である。
installer、`anode setup`、`anode configure`は利用者の作業であり、このSkillからは実行しない。
`setup`は既存のRemote Desktop接続を切断し得るため、必要な場合は影響を添えてcallerへ返す。
WSLからのMCP初期化は確認されておらず、MCP serverとしても登録していないため、CLIだけを使う。

subcommand、引数、出力の形は、導入済みの版の`anode guide --json`と`--help`、および同じ文書が固定する上流版の文書を正とする。
本文に名前がない操作のcommandを推測しない。

## Seatの性質

seatは利用者と同じWindows userで動く別のdesktopであり、pointer、keyboard focus、画面は利用者と分かれる。
file、account、network、app単位で一つしか起動しないprogramは利用者と共有され、security sandboxではない。
利用者のsessionで既に動いている単一instanceのappや、利用者のbrowser profileを使わない。
seatでbrowserを使う場合は、このtestのために作ったprofileだけを使う。
一つのWindows sessionのseatは複数のagentが共有し、leaseで順番に使う。

## 開始する

1. `anode doctor --json`で前提を確かめる。
   Windowsに未導入である旨のexit 3が返った場合とreadyでない場合は、出力と不足をroute 2として返し、導入の入口を示す。
2. guideが示す読み取り専用の確認でseatの状態を読む。seatは共有資源であり、未起動時に作業後の所有と停止を保証できない場合は、運用担当が管理するseatの起動を先に求める。操作依頼だけで共有seatを新たに常駐させない。
   専用seatの起動・回収が許可され、他の利用者がいないことを確認できる場合だけ、`anode start --hidden --no-background-rendering`で始める。viewerは表示しない。
3. このsession固有の`ANODE_AGENT_ID`（必要なら`ANODE_AGENT_NAME`）を環境変数に置き、`anode lease acquire`でleaseを取得する。
   返ったtokenは`ANODE_LEASE_TOKEN`として以降のcommandの環境だけに渡し、引数、log、報告へ書かない。
   WSLの`anode`はこの三つの環境変数をWindows側のprocessへ渡す。
   別のagentがleaseを持つ間は順番を待ち、奪わない。
   長い中断をはさむ場合の更新は、guideの条件に従う。
4. `anode capabilities`で、このseatで画面の取得と入力が使えることを確かめる。
   seatへ接続できたことだけを、screenshotや入力が使える証拠にしない。
   使えない機能に依存する行は未確認にする。
5. 開始時のwindow一覧を記録し、このSkillが起動したappとwindowを識別する値を控える。

## 操作する

- 操作の前にwindow一覧、対象windowのUI Automationの要素、screenshotを取り、文言、control、値、状態を読む。
- controlは名前、role、自動化IDなど構造から特定できる要素を優先する。
  座標でしか操作できない場合は、同じ状態で取った最新のscreenshotから決め、操作後に状態を読み直して結果を確かめる。
- 解像度や拡大率を変えて表示条件の行を確かめる場合は、guideの手段で変え、Windowsが実際に適用した値を記録して、終了時に開始値へ戻す。
- 他のagentが起動したappやwindowへ入力しない。

## Screenshot

screenshotの保存pathはWindows側のprocessが解釈する。
本文の保存先へWindows側から書けるpathを渡し、保存後にWSL側からfileの存在を確かめて開く。
書けなければ、取得できた範囲と永続化できなかったことを記録する。

## 閉じる

証拠を保存先へ残した後、このSkillが起動したappだけをguideの手段で閉じ、未保存の変更がある場合は閉じる前に止めて状態を返す。
`anode lease release`でleaseを解放する。
既存または他の作業に利用され得るseatは終了しない。`anode kill`はseatのすべてのappを閉じるため、排他的な所有と安全な停止を確認した今回の専用seat以外に使わない。
表示条件を変えた場合は開始値へ戻す。

## 既存のwindowを扱う

- 実行ファイルの解決は`orca-cli`の入口に従い、その実行ファイルの`skills get orca-computer-use`が返す版一致guideを読んでから操作する。
  command、引数、出力の形はそのguideと`--help`を正とする。
  Orcaが起動していない、接続が拒否された、guideを取得できない場合はroute 2なしとし、`open`でOrcaを起動しない。
- `computer capabilities --json`で、対象platformがwindowの一覧、状態の取得、必要な操作を公開していることを確かめる。
  `list-windows`で利用者が指定したwindowを照合し、選んだwindowの識別子を以降のすべての操作へ渡す。照合できなければ未確認にする。
- 利用者の画面、keyboard focus、pointerを取らない背景の操作だけを使い、各結果の`delivery`を記録する。
  foregroundを要する操作は、必要な理由を示して利用者の同意を得るまで送らず、その行を未確認にする。
- 対象のdataを変える操作（保存、送信、削除、設定変更）は依頼された範囲に限り、操作後に状態を読み直して結果を確かめる。
- screenshotは、返されたpathをWSL側から開けることを確かめてから本文の保存先へcopyする。開けなければ取得できた範囲と永続化できなかったことを記録する。
- 利用者のappとwindowは閉じない。表示や値を開始時から変えた場合は、変えた内容を結果へ記録する。
