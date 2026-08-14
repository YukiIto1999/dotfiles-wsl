---
name: refactoring
description: Restructures existing code without changing a fixed set of observable behaviors. Use when asked to extract, inline, move, rename, consolidate, simplify, remove indirection, or improve testability while preserving functionality. Establishes a passing behavior baseline, adds characterization only when necessary, makes one reversible structural change at a time, and reruns focused evidence. Does not implement new behavior, optimize performance or resource use, redesign architecture or public contracts, perform a migration, review code without editing, or own the local REFACTOR step inside an active TDD cycle.
---

# Behaviorを保って構造を変える

成果は短いcodeや新しい抽象ではなく、指定した構造上の痛みを取り除き、選んだobservableが変わっていない状態である。

## Preservation contractを固定する

変更前に次を具体化する。

- 対象範囲と、解消する一つの構造上の痛み
- 維持するpublic interface、output、error、side effect、state、ordering
- performanceやresource behaviorを契約として維持する必要があるか
- 呼び出し元、参照、owner、既存ADRと規約
- 変更中に使うfocused command

現在のbehaviorに誤りがあり期待結果も変えるなら、別のbehavior changeとして`bug-analysis`と`tdd`へ渡す。module境界、public contract、architectureを新しく決めるなら設計、dataやprotocolのold/newを切り替えるなら`migration`の仕事である。latency、throughput、memory、resource useの改善が目的なら、`performance-analysis`でbottleneckを確定し、最適化の実装へ渡す。

## Safety netを成立させる

変更前のsourceでfocused checkを実行し、baselineがpassすることを確認する。既存testがpreservation contractを観測しない場合だけ、安定したconsumer seamへcharacterization testを追加する。期待値は望ましい将来でなく、保存すると決めた現在のbehaviorから得る。

characterization testは、対象observableを意図的に変えたときに失敗することをfixtureか一時的なmutationで確かめ、mutationを戻す。productionの計算をtestへ複製したり、production helperをoracleとして共有したりしない。

test pointとchange pointは同じ場所でなくてよい。testabilityのためにseamが必要なら、既存のinjectionかparameterを先に使う。新しい抽象は対象が必要とするmemberだけに絞り、既存public signature、default wiring、error、side effectを保つ。testからだけ使うglobal mutable hookは作らない。

## 一つの構造変更を選ぶ

痛みを直接なくす最小の可逆な変換を選ぶ。新しいhelper、wrapper、interface、factoryを足す前に、次の順で十分かを確認する。

1. 不要なcodeかindirectionを削除する
2. 言語、標準library、frameworkの既存機能を使う
3. repositoryの既存mechanismか既存dependencyへ揃える
4. それでも残る一つのknowledgeや変化軸だけを新しい抽象へ置く

行数やfile数の最小化を目的にしない。異なる理由で変わるcodeを一つへ畳まず、productionと独立oracleの意図的な重複も消さない。抽象を追加する場合は、何を隠し、どの変更を局所化するかを説明できることを条件にする。

## 小さい段階で変える

rename、extract、inline、move、dependencyの差し替えを一度に重ねない。一つの変換だけを行い、次を確認する。

- focused checkが同じ期待値でpassする
- compiler、type checker、正規のresolverで参照漏れがない
- public signature、default wiring、error、side effectがpreservation contractと一致する
- diffに別のbehavior changeや無関係なcleanupが混ざっていない

failureをtestの期待値変更で吸収しない。構造変更がbehaviorを変えたのか、安全網がimplementation detailへ結合していたのかを分ける。原因が分からないまま次の変換へ進まない。

各段のGREENをcheckpointにし、次の変換が不要なら止める。利用者の既存変更を戻さず、自分の段階だけを管理する。

## 完了する

最初に定めた痛みが消え、追加した抽象が必要な所有物だけを持ち、preservation contractが同じ証拠で成立したら完了する。最後のsourceに対し、影響する高コストなverificationが必要なら一度だけ実行する。

結果には、変更前後の構造、維持したobservable、各段のverificationを残す。characterizationを追加した場合と、完了判断に影響する未観測behaviorがある場合だけ、その内容を加える。途中で新しいbehavior、migration、architecture decisionが必要だと分かったら、refactoringへ混ぜずに別の仕事として止める。
