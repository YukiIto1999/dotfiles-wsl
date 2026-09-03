---
name: domain-modeling
description: Builds or revises a domain model from concrete business scenarios. Use when domain concepts, bounded contexts, ubiquitous language, invariants, identity, lifecycle, or cross-artifact meanings are ambiguous or changing. Challenges overloaded terms against code, schema, API, UI, and tests, then records resolved language in the repository's existing documentation structure. Does not merely read vocabulary, rename identifiers, design module boundaries or database schemas, or implement code.
---

# Domain modelを具体化する

成果は図や用語集の量ではなく、同じscenarioをcode、schema、API、UI、testで同じ意味として説明できるmodelである。実装構造を先にdomainへ投影しない。

## 現在の意味を調べる

1. repositoryの規約と既存のdomain文書、decision record、用語集を探す。固定名の`CONTEXT.md`や`docs/adr/`を新設しない。
2. code、schema、API、UI、test、利用者の説明から、同じ語が指す対象と、同じ対象に使われる語を集める。
3. 観測した実装、明文化済みの決定、利用者が決める必要のある事項を分ける。現在のcodeをdomain上の正解とみなさない。

既存modelを読むだけなら、このSkillの仕事ではない。概念、境界、語彙、不変条件のいずれかを決め直す場合に使う。

入力だけで意味が確定しない語は、canonicalな語彙として宣言しない。候補名、候補が表す意味、判定に必要なscenarioを示して利用者へ質問する。利用者が選ぶ前に候補を既定値として後続modelへ使わない。

## 具体的なscenarioから組み立てる

抽象語を定義する前に、代表例と反例を作る。各scenarioでは次を明らかにする。

- 誰が、何を、どの目的で行うか
- 操作前と操作後に何が真であるか
- 何を同時に守らなければ不正な状態になるか
- 失敗、取消、再試行、期限切れ、部分的な処理で意味がどう変わるか
- 発生時刻と記録時刻、現在状態と履歴を区別する必要があるか

語の定義だけで関係を決めず、その語では説明できないscenarioを探す。反例で崩れた抽象は、例外を足して延命せず境界か定義を直す。

## 境界と語彙を決める

同じ語が同じ規則とlifecycleを持つ範囲を一つのcontext候補とする。actor、判断、変更理由、権限、整合性が変わる箇所ではcontextを分ける可能性を検討する。directory、service、tableの境界をそのままbounded contextにしない。

各contextについて、次を決める。

- canonicalな概念名、短い定義、避ける同義語
- identity、所有者、lifecycle、valid state
- state transitionと、その前後で守る不変条件
- context間で共有する識別子と、境界で変換する概念
- 既に起きた事実として残す出来事と、現在状態から導く値

同じ表記を全contextへ強制しない。意味が同じなら語を統一し、意味が異なるなら別の語か明示的なcontext付きの語にする。

提示された事実から必ず成り立つ条件と、domain判断を置かなければ成り立たない規則を分ける。後者は不変条件として確定せず、推奨と質問にする。不変条件の数を揃えない。

aggregate、value object、event、型はmodelを実装へ写す候補であり、scenarioより先に採用しない。実装上の型、module、transaction、table、endpointの設計は、それぞれの設計Skillへ渡す。

## artifact間のずれを確かめる

requirementからdomain、code、schema、API、UI、testまで同じ概念と不変条件を追う。呼び名だけでなく、状態、取消、削除、権限、時刻、失敗の意味が途中で変わっていないか確認する。

矛盾を見つけたら、どのartifactが正しいかを推測しない。具体的なscenarioと現在の挙動を示し、利用者が所有するdomain判断を質問する。外部仕様や一般的な業界用語は判断材料であり、このsystemの意味を自動的に決めない。

## 記録する

利用者がmodelの変更や文書化を求めている場合だけ、repositoryの既存形式へ決定済みの内容を反映する。置き場がなければ新しい文書構造を発明せず、成果を回答として返す。

decision recordは、repositoryが採用しており、変更が難しく、文脈なしでは意外で、現実のtrade-offを伴う決定に限る。用語集へ実装詳細や未決定の案を混ぜない。

## 結果を返す

必要な項目だけを返す。

- contextと関係
- canonicalな語彙と避ける語
- 具体的なscenario、state transition、不変条件
- artifact間で見つかった矛盾
- 決定済み事項と、利用者が決める未決定事項

未決定事項がmodelの形を変えるなら、完成したmodelを装わず、その時点の候補と次に答える質問だけを返す。すべての語を定義しない。今回の判断に関係する概念だけを扱う。未決定事項を実装上の仮定で埋めず、modelが説明できる範囲と残る曖昧さを明示して終える。
