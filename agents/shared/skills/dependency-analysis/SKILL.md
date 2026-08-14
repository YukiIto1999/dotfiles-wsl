---
name: dependency-analysis
description: Analyzes dependency structures by defining node, edge, direction, and granularity before extracting or interpreting a graph. Use when the user asks to map or explain relationships among imports, calls, data flow, runtime interactions, build or deployment dependencies, ownership dependencies, cycles, fan-in, fan-out, transitive reachability, or hidden dependencies. Separates dependency facts from change-cost interpretations. Does not retrieve references to one known symbol, design new boundaries, review architecture quality, diagnose failures, or estimate the impact of one proposed change.
---

# 依存構造を分析する

成果は矢印や件数の一覧ではなく、意味を定義した依存graphと、その証拠から言える範囲の解釈である。依存を減らすこと自体を目的にしない。

## 問いと範囲を固定する

何を知るための分析かを先に決める。対象のrepository、subsystem、revision、environmentと、test、generated、vendored codeを含めるかを明示する。

具体的な変更による影響範囲、既存構造の良否、新しい境界や依存方向は、このSkillで判断しない。故障原因は`bug-analysis`の責務である。

## Graphの意味を定義する

抽出前に次を決める。

- nodeがfile、module、package、service、schema、artifact、ownerのどれを表し、同一性をどう判定するか
- edgeが何を表し、`A -> B`が「AはBを必要とする」など、どちら向きの関係か
- source、call、data、runtime、build、deployment、ownership/change-driverのどの依存を扱うか
- direct edgeとtransitive pathをどう区別するか
- 集約単位、時点、除外条件、未解決edgeの表し方

異なるedge typeを無名の一graphへ潰さない。source上の参照、実行時の呼び出し、dataの生成と消費、build順序、同時deploy、同じactorによる変更は別の関係である。必要なら同じnode集合に型付きedgeを重ねる。

## 依存の事実を抽出する

言語やartifactが提供する正規の仕組みを優先する。

- package manifest、compiler、module resolver、schema、service定義、deployment manifest
- AST、symbol reference、call hierarchy、query plan、runtime trace
- `rg`や`ast-grep`による候補探索と、定義元での確認
- ownership fileとGit historyによるowner、change-driver、co-changeの確認

文字列一致をsemantic dependencyとみなさない。alias、re-export、生成物、feature flag、dynamic loading、reflection、configuration、ambient stateを確認する。静的証拠からruntime edgeを断定せず、解決できないedgeは推測で補わない。

scriptは抽出、正規化、集計に使い、nodeやedgeの意味付けと設計判断を埋め込まない。既存toolが十分なら専用scriptを作らない。

## 抽出結果を確かめる

既知の依存と既知の非依存を少数選び、抽出結果とsourceを照合する。条件付き依存、test専用依存、外部package、generated codeの扱いも確認する。coverageを証明できない場合は、その限界を結果へ残す。

cycleは単純な文字列loopでなく、同じedge typeとgranularityのstrongly connected componentとして判定する。異なる層の合法な往復を、一つの循環依存に見せない。

## 構造を解釈する

metricはgraph contractの後にだけ使う。

- fan-outはnodeが直接知る対象、fan-inはそのnodeを直接必要とする対象として読む
- transitive reachabilityは変更可能性ではなく、伝播し得る経路として読む
- cycleは独立変更、初期化、build、test、deploy、ownershipへ生じる具体的なcostを確認する
- hidden dependencyはambient configuration、共有state、順序、暗黙のschemaやprotocolとして表面化させる
- co-changeは同じactorやruleを示す候補であり、source dependencyの証明にはしない

高いfan-in、fan-out、cycle、direct dependencyを単独で欠陥と判定しない。明示的なdataと安定したcontractを通る依存は必要であり得る。期待する方向がある場合は、その根拠となるownership、policy、repository ruleと、観測した方向の一致、不一致を事実として示す。規約違反や設計上の欠陥とは判定しない。

## 結果を返す

必要な項目だけを返す。

- 問い、scope、snapshot
- node、edge、方向、granularity、除外条件
- 証拠に紐づくdirect dependencyと、導出したtransitive path
- cycle、fan-in、fan-outなど、問いに必要なmetric
- 観測事実、解釈、未解決事項
- 抽出coverageと動的依存の限界

graphから新しいarchitectureを自動的に提案しない。具体的な影響判断、良否判定、境界設計が必要なら、分析結果を証拠として別の仕事へ渡す。
