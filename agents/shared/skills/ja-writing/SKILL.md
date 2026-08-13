---
name: ja-writing
description: Writes and revises Japanese technical prose for a known audience and purpose. Use for Japanese README, ADR, specification, explanation, change description, report, or article, and when asked to remove generic or AI-like wording. Preserves uncertainty and project terminology. Does not decide facts, document type, code-comment content, or identifier names.
---

# 日本語を書く

文章の内容を先に成立させ、読者に合う日本語へ整える。AIらしさの判定や人間らしさの演出を目的にしない。

## 手順

1. 読者、文書の目的、読後に必要な判断や行動を確認する。repositoryに既存文書、用語、templateがあれば先に読む。
2. 根拠のある事実、そこからの解釈、提案を分ける。確認できない事実を補わず、不確実性を保つ。
3. 一段落に一つの主張を置く。主張に必要な根拠、条件、帰結だけを続ける。同じ結論を言い換えて繰り返さない。
4. 同じ概念には同じ語を使う。対象、主体、条件を曖昧な「これ」「ツール」「仕組み」で隠さない。
5. 読者と媒体に合う敬体か常体を選び、既存文書に合わせる。語尾を機械的に散らさない。
6. [推敲観点](references/revision.md)を使い、内容を変えずに空句、過剰な評価、定型構成、不要な装飾を除く。

## 他のwriting Skillとの関係

成果物固有の事実と構成は、該当するSkillが所有する。`commit-writing`はcommitの目的、`change-writing`は差分の説明、`description-writing`は構造的な文書、`documentation-writing`は宣言の契約、`comment-writing`は実装コメントの要否を決める。日本語で書く場合だけ、このSkillで表現を整える。

## 打ち切り条件

必要な事実、読者、文書の目的が分からず、既存資料からも確認できない場合は推測で埋めない。欠けている情報と、それが文章のどの判断を変えるかを示す。
