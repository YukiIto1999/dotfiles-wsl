---
name: error-design
description: Designs internal failure semantics and flow after module boundaries, responsibility owners, and public failure contracts are fixed. Use when deciding where owner-local errors live, how external errors are translated, which failures propagate, when fixed recovery policy applies, when independent failures aggregate, and which existing handler observes a handled or terminal failure. Does not design public error responses, module boundaries or cross-module responsibility, diagnose an observed bug, choose reliability targets, produce severity-based review findings, implement handlers, or redesign unrelated control flow.
---

# 内部failureの意味と流れを決める

成果は共通Error型ではない。各failureが一つの意味とownerを持ち、必要な情報を失わず、処理できる場所まで一貫して届く設計である。

## 外側の契約を固定する

対象operation、module owner、retryや観測を実行するowner、既存seam、公開failure variant、callerが区別する結果、cancellation、side effect、resource lifetimeを確認する。未確定なら`interface-design`か`module-design`へ戻す。障害の原因が未確定なら`bug-analysis`を使う。

code、type、schema、adapter、caller、test、log、retryとcleanupの既存実装を読む。観測事実、固定済み契約、未確認の仮定を分ける。公開error shape、module境界、timeout値、SLO、telemetry backendを内部error設計で決めない。

## Failureを扱いの差から列挙する

代表flowごとに、発生源、意味、owner、handlerに必要なcontext、公開variantへの写像を追う。次は扱いが実際に異なる場合だけ区別する。

- callerやpolicyが通常処理として反応できるexpected failure
- 証明済みinvariantの破壊やprogrammer errorであるdefect
- successにも通常failureにも潰せないcaller cancellation。ownerが設定するdeadlineは、固定済みcontractと実際の扱いの差に従う
- 理由を必要としないabsence

message、exception class、exit statusの違いだけでvariantを増やさない。同じ扱いに収束する細かなprovider errorを全system共通taxonomyへ写さない。逆に、回復、公開mapping、resource処理が異なるfailureを一つの`return 1`やcatch-allへ潰さない。

## 意味を知るownerに置く

failure variantは、その意味と変更理由を知る既存ownerに置く。domain判断の失敗は判断owner、provider固有errorはadapter内部、retryやload sheddingで作るfailureはそのpolicy ownerが持つ。

言語とrepositoryの既存mechanismで表せるなら、新しいResult、base exception、error registry、wrapperを作らない。新しい表現は、異なる処理を型や制御flowで強制し、messageや暗黙statusより誤用を減らす場合だけ残す。

## 境界で一度だけ翻訳する

外部process、library、protocol、storageから入るraw errorは未信頼dataとして扱う。providerの語彙を理解する最初の既存boundaryで検証し、owner-localな意味へ一度だけ翻訳する。

元のcause、operation、相関情報のうち、既存handlerかobserverが安全に消費するcontextだけを保持する。secret、path、stack、vendor内部表現を公開payloadへ漏らさない。各layerでwrap、message化、logを繰り返さない。未知のprovider errorやdefectを既知のexpected failureへ偽装しない。

## 処理できる場所まで伝播する

各variantを、意味のある判断を下せる最初のhandlerまで同じ意味で伝える。中間layerはcontextを必要な分だけ加え、処理しないfailureを保持する。success、failure、cancellationの全経路でresource cleanupを閉じるが、cleanup failureで元の結果を無条件に上書きしない。

回復は、正しい代替結果、state ownership、安全性、idempotency、実行budgetを説明できる場所だけに置く。retryはtransient判定とidempotencyを満たし、固定済みの一つの実行ownerだけが行う。owner未確定なら`module-design`へ戻す。代替の正常結果を返すfallbackは、平常時から正しい結果として使われ、検証と観測ができる場合だけ採る。固定failureへの保守的な写像とは分け、invalid stateへdefaultを返さない。

独立したvalidation項目やbatch itemは、利用者がまとめて処理できる場合に集約する。依存する逐次処理、transaction前提、trustやlockの破壊はfail-fastにする。partial successを許す場合は、item identity、順序、成功と失敗の対応を固定する。

## 観測ownerを一つにする

handled、recovered、dropped、dead-letter、terminal failureを最終的に処理する固定済みownerの既存handlerが一度だけ観測する。semantic tag、operation、module、correlation、attempt、recovery decisionを必要に応じて残す。request IDやraw causeを低cardinality metric labelにしない。telemetryの失敗で本来の結果を変えない。

## 設計を閉じる

少なくとも既存表現を保つ案を対照にし、意味、誤処理の防止、情報保存、変更局所性、回復の安全性、追加mechanismで比較する。点数を合算しない。

一案を推薦し、必要なものだけを返す。

- failureとowner、既存または新しい内部表現
- 翻訳点と公開contractへの最終mapping
- propagation、cleanup、recovery、aggregationの規則
- 一度だけ観測する場所と保持するcontext
- 既存seamで後続testが確認するproperty

production code、test、review finding、incident diagnosisは作らない。内部functionやalgorithmは`code-design`、確定済み設計の実装は`tdd-implementation`へ渡す。
依頼されていないADR、計画、report形式を発明しない。
