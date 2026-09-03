---
name: impact-analysis
description: Traces the blast radius of one proposed or observed change across consumers, contracts, data, runtime, deployment, operations, tests, documentation, and ownership. Use when a symbol, schema, API, behavior, dependency, configuration, artifact, or service will be added, changed, renamed, removed, or upgraded and the user asks what must move, what can break, or what constrains rollout and rollback. Separates guaranteed, conditional, and unknown impacts. Does not map general dependency structure, implement or sequence a migration, choose a new design, or diagnose an existing failure.
---

# 変更影響を分析する

成果は検索hitの一覧ではなく、変更前後の契約差から、どのconsumerがどの条件で影響を受けるかを説明したimpact mapである。変更を実装せず、migration手順も所有しない。

## 変更を一つに固定する

現在の状態、提案後の状態、変わらない契約を具体化する。rename、削除、型変更、意味変更、既定値変更、protocol変更、dependency upgradeを同じ「変更」として扱わない。revision、environment、rollout単位も固定する。

複数の独立変更があるなら別々に分析し、相互作用がある部分だけ最後に結ぶ。変更点が未定なら、先に設計判断を確定する。このSkillで案を選ばない。

## 変化するobservableを列挙する

source diffだけでなく、consumerが観測できるものを起点にする。

- symbol、type、module、package、build output
- API、event、schema、file format、CLI、configuration
- persisted data、cache、queue、session、artifact、secret
- runtime process、service、timer、listener、resource、起動と停止の順序
- deployment topology、old/new versionの共存、operator手順
- error、latency、resource usage、security boundary

名称が同じでも意味や既定値が変わればimpactがある。名称が変わってもadapterやaliasでobservableが保たれる場合は、直接consumerへのimpactと内部変更を分ける。

## Consumerを外向きに追う

変更点からeffect sketchを外向きに描く。`dependency-analysis`の結果があれば証拠として使うが、この分析では具体的な変更に関係するpathだけを辿る。

1. 定義、writer、producer、ownerを確認する。
2. direct reader、caller、subscriber、loader、deployerを正規のresolver、schema、manifest、traceで確認する。
3. direct consumerのobservableが変わる場合だけ、そのconsumerの外側へ進む。
4. fan-outが収束するpinch pointと、別経路へ分岐する境界を記録する。
5. staticに見えないdynamic loading、reflection、configuration、external consumer、manual operationを別枠で調べる。

compilerやtype checkerは到達可能な参照を列挙する証拠になり得るが、runtime data、外部consumer、意味上の互換性まで証明しない。`rg`のhit数をblast radiusにしない。

## 互換性と状態を確認する

各consumerについて、次を分ける。

- source compatibleか
- binary、wire、schema、data、behavior compatibleか
- old producerとnew consumer、new producerとold consumerが共存できるか
- persisted stateやin-flight workを読めるか
- retry、replay、rollbackで同じ変更を再適用して安全か
- downgrade後もnew stateを扱えるか

Hyrumの法則を理由にすべてを互換契約へ昇格させない。log、metric、test、support record、public docs、実consumerから、依存されているobservableを確かめる。利用状況を観測できない外部consumerは「影響なし」でなく「不明」とする。

## Rollout境界を見つける

影響分析では、手順でなく成立条件を返す。

- atomicに切り替える必要がある範囲
- old/newが共存する期間に両方が成立する条件
- additiveな準備とdestructiveな除去の境界
- migration、backfill、rebuild、restart、cache invalidationが必要になる条件
- rollbackできなくなるcommit pointと、事前に必要な証拠
- owner、operator、external consumerへ確認が必要な事項

具体的な順序、batch size、deadline、feature flag設計、migration実行は別の仕事である。ここでは制約を根拠とともに渡す。

## 確度を分ける

- **Guaranteed:** 固定したrevision、environment、rollout単位に含まれる対象について、静的契約、schema、resolver、実測で影響が直接確認できる
- **Conditional:** version、feature flag、traffic、data shape、deploy順などの条件下で影響する
- **Unknown:** dynamic consumer、未観測のstate、外部利用、取得できないruntime証拠が残る

可能性だけの影響を必須変更として列挙しない。影響なしと結論する場合も、どのconsumer集合とobservableを確認したか示す。

## 結果を返す

必要な項目だけを返す。

- 変更前、変更後、不変部分
- 直接consumerとtransitiveなeffect path
- code、contract、data、runtime、deployment、operation、test、docs、ownerごとの影響
- guaranteed、conditional、unknownの別
- coexistence、rollout、rollbackを制約する条件
- 影響なしを確認した重要な経路
- 不足している証拠と、それを得る観測

変更fileの予想一覧だけで終えず、各対象がなぜ影響を受けるかを示す。実装方針、architectureの良否、migration計画はimpact mapから自動的に決めない。
