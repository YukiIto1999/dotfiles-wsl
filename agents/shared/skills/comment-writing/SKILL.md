---
name: comment-writing
description: Decides whether an implementation comment should exist and writes the smallest justified comment. Use when adding, revising, or reviewing comments inside executable code. Preserves a non-obvious rejected alternative and the current constraint that forbids it. In reviews, reports findings without editing. Does not write documentation comments, TODOs, changelogs, or commented-out code.
---

# 実装コメントを書くか決める

reviewだけを依頼された場合は、残す、削除する、codeを直す、正本へ移す、のfindingだけを返す。編集が依頼範囲にある場合だけ変更する。

## 手順

1. コメントを外して、配置、分割、命名、制御の流れ、型から現在の処理を読めるか確認する。
2. 読めなければコメントを足さず、まずcodeを明瞭にする。
3. 読み手が自然に選びそうな別実装と、それを採れない現在の制約があるか確認する。
4. 両方がcodeから読み取れず、将来同じ誤りが起き得る場合だけ短いコメントを残す。
5. 既存の仕様やdecision recordが正本なら、それを参照する。構造へ影響する長期的な決定でrepositoryがADRを採用している場合だけ、新しいADRへ分ける。
6. 日本語なら`ja-writing`を併用する。

## 残せる形

```text
<自然な代替案>は採らない。<現在も有効な制約>のため。
```

文型は固定しない。代替案と制約が具体的に分かれば一文でよい。

## 削除するもの

- codeが何をするか、どう進むかの実況。
- 「性能のため」「互換性のため」だけの理由。
- 変更履歴、過去の障害対応、旧仕様との差分。
- TODO、作業メモ、コメントアウトしたcode。
- 現在の実装を拘束しない理由。
