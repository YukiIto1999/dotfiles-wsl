---
name: ja-writing
description: Writes and revises Japanese technical prose for a known audience and purpose. Use for Japanese README, ADR, specification, explanation, change description, report, or article, and when asked to remove generic or AI-like wording. Preserves uncertainty and project terminology. Does not decide facts, document type, code-comment content, or identifier names.
---

# 日本語を書く

文章の内容を先に成立させ、読者に合う日本語へ整える。AIらしさの判定や人間らしさの演出を目的にしない。

## 手順

1. 読者、文書の目的、読後に必要な判断や行動を確認する。repositoryに既存文書、用語、templateがあれば先に読む。
2. 根拠のある事実、そこからの解釈、提案を分ける。確認できない事実を補わず、不確実性を保つ。
3. 一段落に一つの主張を置く。段落（パラグラフ）の主題文と論理展開で書く。「構造化」を口実に安易に箇条書きへ逃げない。箇条書きは項目が同じ構造・同じ抽象度で並ぶときだけ使い、項目の冒頭を太字で辞書化（プロパティ一覧化）しない。
4. 見出しは主題を一言で射抜く簡潔なラベルにする。見出しにカッコ、英語対訳、数量、注釈を含めない。
5. 因果、対比、経緯は地の文で書く。「AはBである」の短文連打を避け、主客と目的を明示した自然な複文を構成する。単語を中黒（・）で数珠つなぎにせず、読点や接続詞で自然に結ぶ。
6. 同じ概念には同じ語を使う。対象、主体、条件を曖昧な「これ」「ツール」「仕組み」で隠さない。
7. 読者と媒体に合う敬体か常体を選び、既存文書に合わせる。語尾を機械的に散らさない。同じ文型や同じ節構成が3回続いたら、一つは入り口を変える。均一と反復のどちらを避けるか迷ったら、読者の負荷が下がるほうを選ぶ。
8. [推敲観点](references/revision.md)を使い、内容を変えずに空句、過剰な評価、定型構成、不要な装飾、不要なカッコや太字を除く。既存文書では直す箇所を選び、全体へ一律に当てない。

## 他のwriting Skillとの関係

成果物固有の事実と構成は、該当するSkillが所有する。`commit-writing`はcommitの目的、`change-writing`は差分の説明、`description-writing`は構造的な文書、`documentation-writing`は宣言の契約、`comment-writing`は実装コメントの要否を決める。日本語で書く場合だけ、このSkillで表現を整える。

## 打ち切り条件

必要な事実、読者、文書の目的が分からず、既存資料からも確認できない場合は推測で埋めない。欠けている情報と、それが文章のどの判断を変えるかを示す。
