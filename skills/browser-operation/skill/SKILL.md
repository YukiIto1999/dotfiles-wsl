---
name: browser-operation
description: Executes a specified user task or verifies an implemented surface in a real browser through the configured Playwright MCP. Use when the target behavior and browser surface are known and completion requires observed browser evidence. Identifies the correct tab and session, acts from fresh accessibility or DOM state, limits consequential actions, and returns evidence for each requested outcome. Does not design or audit UI, diagnose root causes, analyze performance, review security, or make unspecified changes in a user's real account.
---

# 実browserで操作し、観測結果を返す

## Job

指定された利用者taskを実行するか、実装済みsurfaceを受入条件どおりに検証する。成果はPlaywright MCPの呼出し履歴ではなく、対象、操作前提、実行した経路、各期待結果に対応する観測証拠、未確認事項が揃った結果である。

Playwrightは実行手段であり、何を操作し、どの状態を成功と認め、どこで止めるかはこのSkillが判断する。

## 入力を固定する

開始前に、依頼とrepositoryから次を確定する。

- 実行する利用者task、または検証する受入条件
- 対象URL、appの入口、環境、必要なviewportや入力方法
- 初期状態、使用してよいtest dataとaccount、期待する終了状態
- 外部へ結果を残す操作の有無と、利用者が明示的に許可した範囲

利用者taskでは入口から完了表示までの最短の実経路を使う。verificationでは受入条件を観測可能な主張へ分け、条件にない探索や品質監査を足さない。URL、起動方法、fixtureなどrepositoryや現在のbrowser状態から得られる情報は自分で確認する。対象、認証、必要dataのいずれかが得られず実経路を開始できない場合は、到達できた地点と不足を示して止める。

## 対象tabと初期状態を観測する

最初に`playwright.browser_tabs`でtabを列挙し、URLとtitleから対象を特定する。既存tabを使う理由がなければ専用tabを作り、作成したtabを所有対象として記録する。利用者が開いていた別tab、別account、別環境を推測で選ばない。

対象tabを選択またはnavigationしたら、`playwright.browser_snapshot`で現在のaccessibility tree、表示文言、control、状態、参照先を読む。操作対象はこの観測から決める。snapshotで判別できない属性やDOM上の状態だけを、読み取り専用の`playwright.browser_evaluate`で確認する。screenshot上の座標や見た目を操作対象の特定に使わない。

snapshotのrefはその時点の状態にだけ有効とみなす。navigation、submit、route変更、dialogの開閉、結果一覧更新など、DOMを再構成し得る操作の後は待機してsnapshotを取り直し、新しいrefから次の操作を決める。観測と実画面が食い違う場合は古いrefで試行を重ねず、再観測する。

## 観測してから操作する

1. 操作前の状態と、成功を示す画面上の変化を特定する。
2. fresh snapshotのrole、label、text、refを優先し、対象が一意であることを確かめる。
3. 複数fieldを同じformへ入力するときは`playwright.browser_fill_form`で一括入力し、fieldごとの断片的な操作を避ける。
4. click、入力、key操作は受入条件へ必要な最小限にする。`evaluate`でproductのevent、API、storageを書き換えてUI経路を迂回しない。
5. 非同期更新は固定sleepではなく、期待するtextの出現、処理中表示の消失などを`playwright.browser_wait_for`で待つ。条件を観測できない場合だけ短い時間待機し、その後に状態を取り直す。
6. 操作後のsnapshotまたは必要なDOM状態を読み、期待結果と照合してから次へ進む。

一つの操作で結果が不明なまま、submit、購入、送信などを再試行しない。画面状態と、必要なら対象requestを先に確認し、重複する可能性が残れば停止する。予期しないdialog、認証要求、環境違い、またはtaskの前提と異なる状態に到達した場合も、推測で突破しない。

## 利用者accountと外部結果を守る

閲覧、navigation、未送信入力のような可逆操作と、結果がaccountや外部systemへ残る操作を分ける。購入、課金、messageや招待の送信、公開、削除、権限・security設定・profileの変更、file upload、注文確定などは、単なるverification依頼を実行許可と解釈しない。sandboxまたは専用test accountを使う。利用者の実accountしかない場合は、確定直前の安全な状態までを観測して止め、未実行の結果を成功と報告しない。

利用者が現在の依頼で対象と結果を具体的に指定し、その結果の発生を明示的に求めた場合だけ、その範囲内で一度実行する。対象account、environment、数量、宛先が曖昧なら実行しない。既存sessionからcredential、token、cookie、個人情報を抽出または出力せず、network証拠でもrequest bodyとheaderは必要性がない限り取得しない。

既存tabでlogout、account切替、保存済み状態の消去を行わない。意図しない変更を検出したら追加操作を止め、観測した状態と影響可能性を返す。

## 必要十分な証拠を残す

証拠は主張に合わせて選ぶ。

- 文言、control、enabled/disabled、選択状態、遷移先、成功・失敗表示は操作後のsnapshotまたは必要箇所のDOMで確かめる。
- layout、重なり、画像、色、viewport内のappearanceを主張するときだけ`playwright.browser_take_screenshot`を使う。screenshot単独を機能成功の証拠にしない。
- browser errorが受入条件または観測した異常に関係するときだけconsoleを確認する。「console errorなし」と述べるなら、対象操作を含む区間のmessageを実際に確認する。
- requestの発生、method、endpoint、statusが結果判定に必要なときだけnetworkを確認する。対象URLで絞り、成功したstatic resource、body、headerを既定で収集しない。

各受入条件を`pass`、`fail`、`未確認`のいずれかにし、実際に観測した状態を添える。最終結果には対象environmentとURL、実行した利用者経路、条件ごとの証拠、保存したscreenshotがあればそのpath、安全上実行しなかった操作、残る不確実性を含める。観測していない状態を推測で補わない。

materialな不一致を見つけたら症状、再現経路、直前と直後の状態を保存する。独立した残りの条件は副作用なしに確認できる場合だけ続ける。原因の仮説検証へ広げない。

## Cleanup

証拠を取得してから、開始時のtab一覧と照合する。このSkillが作成したtabだけを`playwright.browser_tabs`で閉じる。再利用したtab、利用者が元から開いていたtab、別agentのtabは閉じず、browser全体も終了しない。cleanup自体が外部変更を増やす場合は行わず、その状態を報告する。

## Non-goals

UIの新規設計、改善提案、visual・accessibilityを含む監査は`ui-design`へ渡す。機能不良の原因特定は`bug-analysis`、計測を伴う速度・memory・Core Web Vitalsの分析は`performance-analysis`、脅威や脆弱性の調査は`security-review`が所有する。

このSkillはfrontend実装、網羅的なtest設計、公開Web調査、credential管理、APIを直接叩く代替verificationを行わない。指定taskの実行または既知の受入条件のbrowser verificationを終え、証拠とcleanupを返した時点で停止する。
