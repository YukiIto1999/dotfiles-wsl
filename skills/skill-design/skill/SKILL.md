---
name: skill-design
description: Decides whether a recurring agent capability deficit warrants a Skill, then creates, revises, or evaluates the smallest sufficient Skill package. Use when asked to turn a workflow or repeated correction into a Skill, change an existing Skill's responsibility or routing, compare it with baseline behavior, or audit Skill overlap and effectiveness. Starts with concrete scenarios and a mechanism gate, and permits a well-supported decision to create nothing. Does not build a portfolio from a taxonomy, install third-party Skills, turn a single principle or tool invocation into a Skill, or own the domain method that the candidate Skill will teach.
---

# 必要な能力だけをSkillにする

成果はSkillの追加ではなく、反復する不足を最小の所有物で解消した状態である。作らない判断を欠落として扱わない。

## 既存状況を読む

利用者の目的、反復するtask、過去の訂正、repository policy、既存Skillとその配備経路、reference、script、tool、評価方法を確認する。候補名や外部repositoryの分類から始めない。

具体的な代表scenarioを集め、Skillなしで実行するか、既存の実行記録からbaselineを得る。事実、解釈、判断を分け、基礎モデルが失敗した箇所と成果への影響を記録する。想像上の不足だけなら止める。

## 最小のmechanismを選ぶ

次を順に比較する。

1. 何も追加せず、基礎モデルで処理する
2. 常時適用する短いrepository policyにする
3. 必要時だけ読むreferenceにする
4. 決定的な処理をscriptまたはtoolへ置く
5. 既存Skillをそのまま使うか、自然に補強する
6. 方法自体に固有価値があるsignature procedureを監査して採用する
7. 独立したcustom Skillを作る

機構の選択条件とSkill admissionの詳細は、判断が必要なときだけ[admission and evaluation](references/admission-and-evaluation.md)を読む。Skillが最小十分でなければ、採らない機構と理由を示して終了する。

## Candidateの契約を固定する

作る場合は、本文より先に次を一文ずつ定める。

- Job: 何を可能にするか
- Trigger: どの状況で必要か
- Decision ownership: 何を判断するか
- Evidence: 何を根拠にするか
- Outcome: 何が得られれば完了か
- Non-goals: 近接する何を所有しないか
- Distinct methodology: baselineや隣接Skillと異なる手順

同じ判断を複数Skillが所有する、triggerを自然に分けられない、独立利用に価値がない場合は統合する。trigger、判断所有権、evidence、単独利用が実質的に異なる場合だけ分ける。一原則だけのmicro Skillと、複数能力を隠すGod Skillは作らない。

## 最小のpackageを書く

`description`をrouting contractとして、primary Job、主要trigger、重要な非対象を先に書く。本文は観察、判断、行動、referenceを読む条件、禁止事項、打ち切り、検証だけを持つ。sourceのtaxonomy、長い解説、一般論、評価harnessを移植しない。

詳細知識は一段だけのfocused referenceへ分ける。決定的な抽出、検証、変換だけをscriptへ置き、意味判断を押し込まない。外部sourceを使う場合は、[provenance](references/provenance.md)の形式でrevision、license、採用理由、local modificationを追跡する。

## Forward evalで存在理由を確かめる

baselineとSkillありの実行は、別の新しいsessionで行う。model、tool、repository、taskに必要なcontextを揃え、baselineの初期contextとSkill一覧には候補のname、description、本文、reference、候補から作った期待結果を含めない。Skillあり側でだけ候補を利用可能にする。入力、利用可能なSkill、model、実行結果は割り当て済み`TMPDIR`の評価用directoryへ残す。隔離条件を作れない場合は、baselineとupliftを推定せず「未測定」とする。

baselineで使った文面を写さず、同じ能力を要する新しいtypical scenario、境界事例、紛らわしいnear-missを使う。成果だけでなくrouting、必要な証拠取得、restraint、隣接Skillとのcompositionを比較する。

典型例が改善してもnear-missを奪う、作業や説明を増やす、隣接Skillと判断を重複する場合は修正または棄却する。本文の節、reference、scriptを一つずつ外すablationを行い、成果が変わらないものは削る。最終的にSkill全体を外して差がなければSkillを削除する。

形式validatorはpackageの妥当性だけを示す。baselineとの差、routing、composition、restraintを実測していない状態を完成としない。実行不能、timeout、judgeやfixtureの不良はSkillの失敗と混同せず、未確認として残す。
