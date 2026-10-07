---
name: dependency-analysis
description: Analyzes dependency structures by defining node, edge, direction, and granularity before extracting or interpreting a graph. Use when the user asks to map or explain relationships among imports, calls, data flow, runtime interactions, build or deployment dependencies, ownership dependencies, cycles, fan-in, fan-out, transitive reachability, or hidden dependencies. Separates dependency facts from change-cost interpretations. Does not retrieve references to one known symbol, design new boundaries, review architecture quality, diagnose failures, or estimate the impact of one proposed change.
---

# 依存構造を分析する

成果は矢印や件数の一覧ではなく、意味を定義した依存graphと、その証拠から言える範囲の解釈である。依存を減らすこと自体を目的にしない。

## 問いと範囲を固定する

何を知るための分析かを先に決める。対象のrepository、subsystem、revision、environmentと、test、generated、vendored codeを含めるかを明示する。

具体的な変更による影響範囲、既存構造の良否、新しい境界や依存方向は、このSkillで判断しない。
故障原因や性能劣化の診断は`diagnosing-bugs`の責務である。

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
- 既知のpathは`Read`、file名は`Glob`、symbolの定義と参照は利用可能なLSP、exact textは`Grep`や`rg`、構文patternは利用可能な`ast-grep`で直接確認する。
- 表現や所在が不明な場合だけ、scope、知りたい関係、edge type、既知のanchorを`repository-research`へ渡し、sourceで確認した定義と経路、未確定事項を受け取って抽出を続ける。
- ownership fileとGit historyによるowner、change-driver、co-changeの確認

文字列一致をsemantic dependencyとみなさない。alias、re-export、生成物、feature flag、dynamic loading、reflection、configuration、ambient stateを確認する。静的証拠からruntime edgeを断定せず、解決できないedgeは推測で補わない。

scriptは抽出、正規化、集計に使い、nodeやedgeの意味付けと設計判断を埋め込まない。既存toolが十分なら専用scriptを作らない。

manifestやtraceの取得には、repositoryが宣言するcommandか、sessionに公開されたCapability toolを使う。
MCPの操作名と実際のtool名や引数は区別し、利用前に公開schemaで確認する。
container-backedな証拠も公開されたCapability経由で取得し、providerのprocess、database、containerへ直接入らない。
`repository-research`や必要なCapabilityが使えない場合は、既知の入口からnative toolで確認できる範囲を進め、取得できないedgeと必要な証拠を未解決として返す。

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

graphから新しいarchitectureを自動的に提案しない。
一つの変更の影響判断が必要なら、変更前後の契約、型付きgraph、source locator、未解決edgeを`impact-analysis`へ渡し、consumerごとのimpactと確度を受け取る。
境界やinterfaceの設計が依頼された場合は、問い、graphの意味、観測した依存、変更制約を`codebase-design`へ渡し、設計判断を依存の観測事実とは分けて扱う。
故障や性能regressionの診断が依頼された場合は、症状、revision、environment、関連するedgeの証拠と不明点を`diagnosing-bugs`へ渡す。
受け取った原因は、その診断が確認した条件と証拠に限って使い、graphだけから原因を認定しない。
これらのhandoffは、その専門仕事が依頼され、対応するSkillが利用可能な場合だけ行う。
使えない場合も依存分析は完了させ、未実施の専門仕事と引き継げる証拠を返す。
