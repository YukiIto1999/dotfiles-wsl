---
name: comment-writing
description: Decides whether an implementation comment should exist and writes the smallest justified comment. Use when adding, revising, or reviewing comments inside executable code. Preserves only a non-obvious rejected alternative and the current constraint that forbids it, written in the noun-ended label form owned by architecture-standard. In reviews, reports findings without editing. Does not write documentation comments, TODOs, changelogs, or commented-out code.
---

# 実装コメントを書くか決める

実装コメントの内容と形の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、コメントの要否を決めて正本の形へ当てる手順だけを持つ。

| 規則 | 正本 |
|---|---|
| 残せる内容としての採らなかった実装と現在も有効な制約 | `principles/comment/rejected-alternatives.md` |
| 削除するcodeの処理の説明 | `principles/comment/no-code-explanation.md` |
| 削除する変更履歴、作業メモ、TODO、コメントアウトしたcode | `principles/comment/no-history-in-source.md` |
| 各行の文末と句読点 | `principles/documentation/sentence-endings.md` |

標準本文は、配備済みの`standard-apply` Skillの`SKILL.md`を実体まで辿り、その二段上のdirectoryから読む。
正本を読めない場合は記憶で補わず、読めなかったfileを示して止める。

reviewだけを依頼された場合は、残す、削除する、codeを直す、正本へ移す、のfindingだけを返す。
編集が依頼範囲にある場合だけ変更する。

## 手順

1. コメントを外して、配置、分割、命名、制御の流れ、型から現在の処理を読めるか確認する。
2. 読めなければコメントを足さず、まずcodeを明瞭にする。
3. 読み手が自然に選びそうな別実装と、それを採れない現在の制約があるか確認する。
4. 両方がcodeから読み取れず、将来同じ誤りが起き得る場合だけ短いコメントを残す。
5. 既存の仕様やdecision recordが正本なら、それを参照する。
   構造へ影響する長期的な決定でrepositoryがADRを採用している場合だけ、新しいADRへ分ける。
6. 残すコメントを正本の形で書く。
   日本語の語の選び方には`ja-writing`を併用し、`ja-writing`が扱う散文の文の形はコメントの文末と句読点に当てない。

## 残せる形

```text
<現在も有効な制約>のため<自然な代替案>は不可
```

文型は固定しない。
代替案と制約が具体的に分かり、名詞で終わる一行なら語順を変えてよい。

## 完了前の確認

1. 各コメントについて、自然に見えるどの実装を、現在のどの制約によって採れないかを答えられるか確かめる。
   答えられないコメントは削除する。
2. 各行の末尾の語が名詞か確かめる。
   動詞、形容詞、「です」「ます」で終わる行は、その動作や状態を表す名詞で終える形へ書き換える。
3. 各行に句点と読点がないか確かめる。
   句読点を空白や記号に置き換えて二つの内容をつないだ行も、読点がある行と同じに扱う。
4. 一行に関心が二つあるなら、一つの関心に言い直せるか確かめ、言い直せなければ行を分ける。
   分けた行が代替案と制約の組にならなければ削除する。

## 失敗例

| 誤ったコメント | 飛ばした確認 | 直し方 |
|---|---|---|
| `// 指数バックオフは採らない。上流のRetry-Afterが正本のため。` | 句点と動詞終わり。旧templateの写し | `// 上流の Retry-After が待機時間の正本のため指数バックオフは不採用` |
| `// 上流の Retry-After を優先 指数バックオフは不採用` | 句読点の代わりに空白でつないだ二つの内容 | 制約を理由として一つの行に言い直す |
| `// メッセージを順に送信する` | codeから読める処理の説明 | 削除する |
| `// 性能のため` | 採らなかった実装と制約の特定 | 代替案と制約を書けなければ削除する |
| `// 2026-08の障害対応で追加` | 変更履歴 | 削除し、必要ならcommitかdecision recordへ置く |
