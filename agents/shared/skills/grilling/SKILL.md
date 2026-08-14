---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use only when the user explicitly asks to be grilled, interviewed, or stress-tested before action. Builds a dependency-ordered design tree, asks only the current frontier, supplies a recommendation for each question, and leaves factual lookup to the agent. Does not trigger for ordinary planning, design, brainstorming, or implementation, and does not replace domain-specific design work.
---

# 判断を質問で詰める

利用者と共有理解に達するまでinterviewする。論点をdesign treeとして捉え、各decisionから、その答えに依存するdecisionを枝として伸ばす。

## Frontierを一巡ずつ進める

frontierは、前提がすべて確定し、推測せずに今質問できるdecisionの集合である。

1. 依頼、既存資料、実装から、確定事項と未決定事項を分ける。
2. 未決定事項の依存関係を作り、現在のfrontierだけを選ぶ。
3. 同じfrontierの質問を一巡でまとめる。各質問を番号で区別し、推奨する答えと、その根拠を添える。
4. 利用者の回答を受けてtreeを更新する。回答に依存する質問は次の巡回まで出さない。
5. frontierが空になるまで繰り返す。

選択肢は判断に必要な差がある場合だけ示す。列挙で終わらず、現在の制約から推奨を一つ出す。質問数を埋めるために枝を増やさない。

質問は次の形を基本にする。

```markdown
**Q1. <判断を特定する短い見出し>**

<何を決めるか。必要なら実在する選択肢と帰結。>

推奨: <推奨する答えと理由>
```

## 事実とdecisionを分ける

環境、repository、tool、公開資料から確認できる事実はagentが調べる。利用者に検索や確認を委ねない。独立した広域探索だけをAGENTS.mdの条件に従ってsubagentへ委譲し、数回のtool呼出しで済む事実は自分で確認する。

調査中の事実に依存する枝だけを保留し、無関係なfrontierは先に質問する。事実の不足を利用者判断で埋めない。

product intent、risk acceptance、domain rule、優先順位、不可逆なtrade-offは利用者が所有する。推奨は出すが、回答を代行しない。

## 終了する

frontierが空で、前提、decision、残る不確実性を利用者と同じ意味で説明できれば終了する。暗黙の枝がないことを短く示し、共有理解に達したか確認する。

このSkillは確認後も実装しない。利用者の依頼に実装が含まれる場合は、共有理解の確認後に別の作業として進める。
