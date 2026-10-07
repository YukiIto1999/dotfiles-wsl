---
name: browser-operation
description: Executes a specified user task or verifies an implemented surface in a real browser through the configured Playwright MCP. Use when the target behavior and browser surface are known and completion requires observed browser evidence. Identifies the correct tab and session, acts from fresh accessibility or DOM state, limits consequential actions, and returns evidence for each requested outcome. Does not design or audit UI, diagnose root causes, analyze performance, review security, or make unspecified changes in a user's real account.
---

# 実browserで操作し、観測結果を返す

## Job

指定された利用者taskを実行するか、実装済みsurfaceを受入条件どおりに検証する。成果はPlaywright MCPの呼出し履歴ではなく、対象、操作前提、実行した経路、各期待結果に対応する観測証拠、未確認事項が揃った結果である。

Playwrightは実行手段であり、何を操作し、どの状態を成功と認め、どこで止めるかはこのSkillが判断する。

## 公開入口

`browser-automation` Capabilityのgatewayに公開されたPlaywright toolを使う。
本文の`playwright.browser_*`は論理名であり、現在のclientが公開した実tool名とschemaへ対応させる。
URI deviceを公開するclientでは`xd://mcp__gateway_playwright_browser_tabs`などの入口を読み、JSON引数を渡す。
MCP toolを直接公開するclientでは、そのネイティブな呼出し形式を使い、URI deviceがあると仮定しない。
tab一覧は`browser_tabs`の`action: "list"`、作成は`"new"`、選択と終了は`"select"`または`"close"`と一覧の`index`を使う。
snapshotと通常の操作は選択中のtabに作用し、Chrome DevToolsのpage IDとは共有しない。
toolが公開されていない、接続できない、または対象へ到達できない場合は、その境界を未確認として返し、別browser、provider、containerを直接起動しない。

## 入力を固定する

開始前に、依頼とrepositoryから次を確定する。

- 実行する利用者task、または検証する受入条件
- 対象URL、appの入口、環境、必要なviewportや入力方法
- 初期状態、使用してよいtest dataとaccount、期待する終了状態
- 外部へ結果を残す操作の有無と、利用者が明示的に許可した範囲

利用者taskでは入口から完了表示までの最短の実経路を使う。verificationでは受入条件を観測可能な主張へ分け、条件にない探索や品質監査を足さない。URL、起動方法、fixtureなどrepositoryや現在のbrowser状態から得られる情報は自分で確認する。対象、認証、必要dataのいずれかが得られず実経路を開始できない場合は、到達できた地点と不足を示して止める。

## 対象tabと初期状態を観測する

最初に`playwright.browser_tabs`の`action: "list"`でtabを列挙し、URLとtitleから対象を特定する。
既存tabを使う理由がなければ専用tabを作り、作成したtabとsessionを所有対象として記録する。
選択には現在の一覧の`index`を渡し、tabの作成や終了で番号が変わった場合は一覧を取り直す。
利用者が開いていた別tab、別account、別環境を推測で選ばない。
navigationには`browser_navigate`の`url`へ確定した入口を渡す。

対象tabを選択またはnavigationしたら、`playwright.browser_snapshot`で現在のaccessibility tree、表示文言、control、状態、参照先を読む。操作対象はこの観測から決める。snapshotで判別できない属性やDOM上の状態だけを、読み取り専用の`playwright.browser_evaluate`で確認する。screenshot上の座標や見た目を操作対象の特定に使わない。

snapshotのrefはその時点の状態にだけ有効とみなす。navigation、submit、route変更、dialogの開閉、結果一覧更新など、DOMを再構成し得る操作の後は待機してsnapshotを取り直し、新しいrefから次の操作を決める。観測と実画面が食い違う場合は古いrefで試行を重ねず、再観測する。

## 観測してから操作する

1. 操作前の状態と、成功を示す画面上の変化を特定する。
2. fresh snapshotのrole、label、text、refを優先し、対象が一意であることを確かめる。
   clickはそのsnapshotの`ref`を`browser_click`へ渡し、期待文言の出現は`browser_wait_for`の`text`、消失は`textGone`で待つ。
3. 複数fieldを同じformへ入力するときは`playwright.browser_fill_form`の`fields`へ各fieldの`name`、`type`、fresh snapshotの`ref`、`value`を渡して一括入力する。
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

screenshotの保存先を指定する場合は、現在の公開output契約から非公開directoryを確認し、`filename`へその中の絶対pathを渡す。
別processの相対pathの解決先やcallerの`TMPDIR`を同じ保存先とみなさず、返ったartifactのpathと読取可否を確認する。
保存先が拒否された場合は、共有directory、symlink、providerの設定変更で回避しない。

各受入条件を`pass`、`fail`、`未確認`のいずれかにし、実際に観測した状態を添える。最終結果には対象environmentとURL、実行した利用者経路、条件ごとの証拠、保存したscreenshotがあればそのpath、安全上実行しなかった操作、残る不確実性を含める。観測していない状態を推測で補わない。

materialな不一致を見つけたら症状、再現経路、直前と直後の状態を保存する。独立した残りの条件は副作用なしに確認できる場合だけ続ける。原因の仮説検証へ広げない。

## Cleanup

証拠を取得してから、開始時のtab一覧と照合する。このSkillが作成したtabだけを`playwright.browser_tabs`で閉じる。再利用したtab、利用者が元から開いていたtab、別agentのtabは閉じず、browser全体も終了しない。cleanup自体が外部変更を増やす場合は行わず、その状態を報告する。

## Non-goals

次の専門作業が依頼に含まれる場合だけ、利用可能なSkillへ渡す。

| 条件 | Skillへ渡す入力 | 受け取る結果 |
|---|---|---|
| 実装前のUI判断が必要 | `ui-design`へ利用者task、実content、観測したstate、既存の制約 | UI briefと設計上の未確定事項 |
| 観測した機能不良の原因診断が必要 | `diagnosing-bugs`へ期待と実際、再現経路、前後のsnapshot、関連するerror | 原因を支える証拠と次の検証または修正判断 |
| loading、interaction、layout shift、networkの性能測定が必要 | `browser-performance`へURL、経路、測定条件、観測した遅延 | 実測値、原因との対応、未測定項目 |
| JavaScript heap保持の調査が必要 | `heap-analysis`へ操作と終了sequence、反復条件、取得済みsnapshotがあればその非公開path | 保持経路、寿命、比較で確かめたこと |
| 脅威や脆弱性の調査が必要 | `security-review`へ対象scope、経路、観測証拠、関連source | 検証を通過した所見と証拠の不足 |

専門結果は元のtaskの観測結果と区別してcallerへ返し、handoffを理由に同じ操作を再実行しない。
Skillが利用不能なら証拠と不足する専門作業を返し、原因や測定結果を補わない。

このSkillはfrontend実装、網羅的なtest設計、公開Web調査、credential管理、APIを直接叩く代替verificationを行わない。指定taskの実行または既知の受入条件のbrowser verificationを終え、証拠とcleanupを返した時点で停止する。
