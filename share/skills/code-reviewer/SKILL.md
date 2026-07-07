---
name: code-reviewer
description: Use when reviewing a code diff(`git diff` / `git diff --staged` / `git diff origin/main...HEAD`)— Critical / Major / Minor severity + Praise(良い点)を file:line 付きで出力。観点はバグ可能性 / セキュリティ / 可読性 / 規約逸脱 / テストカバレッジ、抽象的な総評のみは出さない。Trigger on staged changes before commit / before `gh pr create` / after substantial implementation, even if user does not say "review".
---

# Code Reviewer

## When to invoke

- ユーザーが「レビューして」「review this」と依頼したとき
- 実装完了直後、commit / PR 作成前
- `git diff` / `git diff --staged` / `git diff origin/main...HEAD` のいずれかを対象に

## Review process

1. **差分の取得**:レビュー範囲を明示確認。デフォルトは `git diff --staged`、なければ `git diff`、ブランチなら `git diff <base>...HEAD`
2. **構造把握**:変更ファイルの目的と相互関係を 1 段落で要約
3. **観点別レビュー**
   - **バグ/ロジック**: 未処理エッジケース、off-by-one、null/undefined 参照、競合状態
   - **セキュリティ**: 入力検証、SQLi/XSS/コマンドインジェクション、機密情報露出、認可不備
   - **可読性**: 命名、関数長、ネスト深度、マジックナンバー
   - **規約逸脱**: 既存スタイル(隣接ファイル / リンター設定)からの乖離
   - **テスト**: カバレッジ、エッジケース、テストの読みやすさ
4. **指摘出力**:severity ごとに列挙

## Output format

```
## Review Summary
<1-2 文の総評>

## Critical (要修正、マージブロック)
- <file>:<line> — <issue>
  - 提案: <how to fix>

## Major (修正推奨)
- <file>:<line> — <issue>

## Minor (任意)
- <file>:<line> — <issue>

## Praise (良い点)
- <file>:<line> — <why it's good>
```

## Don'ts

- 抽象的な指摘(「もっと良くできる」等)は出さない。具体的に file:line と修正案
- 全肯定もしない。Critical/Major が無くても Minor を 1〜2 件は拾う
- 既存コードに同様の問題があれば「既存パターン踏襲か、機会改善か」を判断して指摘有無を決める
