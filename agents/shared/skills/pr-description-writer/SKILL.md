---
name: pr-description-writer
description: Use when writing a Pull Request body for the current branch(`git diff base..HEAD` の差分から)。Summary / Why / Changes / Test plan / Rollback / Related の 6 section を出力、コミット羅列は禁止、具体検証手順を必ず含める。Trigger before `gh pr create` / after `git push -u origin <branch>` even if user does not say "PR".
---

# PR Description Writer

## When to invoke

- ユーザーが「PR」「pull request」「PR description」と依頼したとき
- branch を push する前後、`gh pr create` の準備時

## Process

1. **base branch 確認**:`git symbolic-ref refs/remotes/origin/HEAD` または明示指定
2. **差分取得**:`git log <base>..HEAD --oneline` でコミット列、`git diff <base>...HEAD --stat` で変更ファイル
3. **目的把握**:コミットメッセージとファイル変更から、ユーザーから見た価値を抽出
4. **テスト方法**:追加された tests、手動検証手順、影響範囲
5. **リスク評価**:ロールバック可否、依存変更、breaking change

## Output format

```markdown
## Summary
<1-3 bullet points で「何が変わったか」を ユーザー視点 で>

## Why
<背景・動機。link issue があれば参照>

## Changes
- <main file>: <what>
- <other file>: <what>

## Test plan
- [x] <既に実行済の検証、コピー可能なコマンド形式で>
- [ ] <これから実行する検証ステップ>
- [ ] <edge case>

## Rollback
<revert で安全か、データ移行があれば手順>

## Related
<Issues / RFCs / 議論スレッド、無ければ `none` と明示>
```

### Test plan の必須要件

- 各項目は **`[x]`(検証済)/ `[ ]`(未検証)** を明示。空 checkbox の混在は許容、無印 `-` は禁止
- 最低 1 つ、**コピー&ペーストで実行できる shell command** または `nix flake check` 等の derivation eval を含む
- 既存テストで eval される変更の場合は、**`checks.<name>`** や **`tests/<path>::<case>`** を名指しで引用(「既存 test で検証済」だけは禁止)
- 手動検証しか手段が無い場合は明示し、確認ポイントを 1 行で記述

## Don'ts

- 単なるコミット列の羅列にしない(`git log` のコピペは禁止)
- 「リファクタしました」のような曖昧表現は避け、具体的に
- Test plan に動作確認手順を必ず入れる(自動テストだけでも明記)
- N/A の section を省略しない(`Related` 等で該当無い場合は `none` と明示)
