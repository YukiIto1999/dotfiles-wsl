---
name: module-design
description: Designs module responsibility, ownership, seams, coarse contracts, and dependency direction by comparing materially different allocations under fixed actors, change drivers, state, artifact lifecycles, and system constraints. Use when deciding which module owns a responsibility, state, or artifact; whether to add, split, merge, or retain modules; or where a module dependency should point. Does not design module-internal code, exact APIs, types, schemas, errors, or versions; change service, process, repository, or deployment topology; define domain vocabulary; review an existing architecture without a design request; or edit code.
---

# Moduleの責務境界を決める

成果はfolder構成ではなく、変更理由と所有物が対応し、周辺へ必要以上の知識を漏らさない責務配置である。

## 判断材料を固定する

現在のcode、契約、文書、履歴から次を調べ、観測した事実、確定済みの制約、未確認の仮定を分ける。

- actorと現在のaccountable owner
- 変更を起こす仕様、利用者、外部mechanismと変更頻度
- domain上の所有者と既存のmodule境界
- mutable state、生成物、設定、source、packageのlifecycle
- 同時に整合させる必要がある判断とtransaction
- security、compatibility、latency、build、deploy、runtimeの制約

domainの意味やsystem topologyが未確定で責務配置を変える場合は、該当する設計へ戻す。仮定で埋めてmodule案を完成させない。

## 分けられない責務を見つける

同じ理由で変更され、同じstateかartifact lifecycleを所有し、一緒に整合させる必要がある判断をまとめる。手続きの順番、framework、file type、vendor名、見かけ上のentityだけを境界根拠にしない。

責務ごとに、所有する判断、state、artifactと、所有しないものを示す。moduleが隠す知識と、callerへ残す知識を区別する。

## 責務配置の異なる案を作る

実行可能な案を複数作る。名前やdirectoryだけでなく、責務か所有物の配置を変える。可能なら、既存ownerへ置いて新しいmoduleを作らない案を必ず対照にする。

各案を同じ形式で記述する。

- moduleの責務と、その責務を担う現在のaccountable owner
- 所有する、または所有しないstateとartifact
- 隠す判断と公開する粗いcapabilityかevent
- 許可するsource dependencyと向き
- runtime interactionとlifecycle
- 代表的な変更で触るmodule、contract、build、deploy、owner

source dependencyとruntime callの向きを同じarrowへ潰さない。method signature、type、schema、error、versioningは後続のinterface設計へ渡す。

contractは、隠す判断、change driver、stateを所有するmoduleが持つ。source dependencyはcontract ownerへ向け、runtime callerとcall directionは別に記述する。変動する外部mechanismが安定したpolicyを支配する場合は、policy ownerのcontractをmechanismが実装する向きへ反転する。同じlifecycleにある安定した直接依存を、layerの対称性、testability、inversion自体を理由に反転しない。

## 制約と実費で比較する

ownership、atomicity、consistency、security、既存topology、compatibility、operational lifecycleに反する案を先に失格にする。残る案は点数を合算せず、次の実費で比較する。

- 代表的な変更が何moduleへ伝播するか
- coordinated edit、lockstep release、fragile testが増えるか
- shared mutable state、temporal contract、ambient contextを作るか
- callerの知識とcontract burdenを増やすか
- runtime crossing、build、deploy、operationを不要に増やすか
- 境界の導入や撤去が可逆か

同じ制約下で、一案が全ての重要軸で他案以上なら、その案を選ぶ。支配関係がなければ、今回優先するchange driverかriskと、犠牲にする性質を明記して一案を選ぶ。hybridは元案の欠点を併合せず、責務配置が一貫する場合だけ作る。

## 新しいmoduleを棄却できるようにする

新しいmoduleは、独立したchange driver、stateかartifact lifecycle、またはaccountable ownershipを一箇所へ封じ込め、代表的な変更の調整量を減らす場合だけ残す。共通version、共有helper、vendor名、対称なdirectory、将来の可能性だけでは新境界を作らない。

新moduleなしの案が同じ制約を満たし、caller knowledgeや変更伝播を増やさないなら、既存ownerを選ぶ。file数やdiffの短さだけを理由に既存ownerを選ばない。

## 結果を返す

必要な項目だけを返す。

- 確定した制約、観測事実、判断を変える仮定
- 責務配置の異なる案
- 各案のowner、state、artifact lifecycle、粗いcontract、dependency direction
- hard constraintで棄却した案
- dominanceかtrade-offによる推薦案と、犠牲にした性質
- interface、architecture、domain、実装へ渡す未決事項

文書形式を指定されていなければ、ADR、diagram、移行計画を新しく作らない。選択に使わなかった一般原則や全案の長い再説明も加えない。

module内部のclass、function、algorithmは扱わない。service、process、repository、deployment topologyやteam構造を変更しない。現在のaccountable ownerは制約として扱い、teamや担当者の再編で責務配置を解決しない。既存構造のfindingやseverityを出すだけのreview、codeの移動、refactoring、migrationへ進まない。
