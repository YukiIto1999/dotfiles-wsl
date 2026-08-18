---
name: description-writing
description: Creates or restructures substantial technical prose such as README, ADR, specification, proposal, report, guide, or technical explanation. Use when a document must teach, explain, justify, or guide a known audience beyond a short change summary. Derives structure from reader questions and repository conventions. Does not write code comments, declaration documentation, commit messages, changelogs, or PR-only change summaries.
---

# 構造的な技術文書を書く

## 手順

1. 文書の種類、読者、読書中か作業中か、読後に必要な判断や行動を定める。既存templateと同種文書を先に読む。
2. source、code、test、decision recordから事実を集める。書き手だけが知る背景や判断が必要なら、結果を変える不足だけを質問する。
3. 読者が実際に持つ問いを並べ、その問いに答える最小の構成を作る。一般的な導入、網羅のための節、後で参照しない詳細を足さない。
4. 見出しは簡潔なラベルにする。説明や結論を文にして詰めない。見出しだけを順に読んで目的の節へ辿り着けることを確認する。
5. 一つの正本だけを置く。同期手段のない揮発値を転記せず、正本と取得方法を示す。読者が作業に必要な値は、生成か検査で正本と一致させられる場合に掲載する。
6. 文書の種類に応じて[文書別の判断](references/document-types.md)を読む。種類を混ぜない。
7. 全体を読み、矛盾、重複、未定義語、読者にだけ見えない前提を除く。各行を消したとき読者が誤るかで残す内容を決める。
8. 大きな文書か重要な判断文書だけ、文脈を持たないreaderに主要な問いを答えさせる。readerが誤った箇所を直し、儀式として毎回実行しない。
9. 日本語なら`ja-writing`を併用する。

## 禁止事項

- templateの空欄を埋めるために事実を作る。
- 学習、手順、参照、説明を一つの文書へ混ぜる。
- repositoryの現在値を手で複製する。
- 同じ要約を冒頭、各節、末尾で繰り返す。
- 文章量や節数を完成度の指標にする。
