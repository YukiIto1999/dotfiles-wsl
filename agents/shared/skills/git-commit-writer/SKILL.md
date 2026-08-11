---
name: git-commit-writer
description: Use when writing a one-line, unscoped Conventional Commit message for staged changes (`git diff --staged`). Select the type, keep one purpose per commit, and reject body, trailer, scope, and AI attribution. Trigger after `git add`, when staged changes exist, or immediately before commit.
---

# Git Commit Writer

## When to invoke

- ユーザーが commit または commit message の作成を依頼したとき
- 実装と検証が終わり、変更を stage したとき

## Process

1. `git diff --staged` で対象を確認する。staged が空なら `git status --short` を確認し、件名を作らない。
2. 無関係な目的が混ざっている場合は、対象 path を明示した `git restore --staged -- <paths>` で分ける。実装、その検査、対応文書は一つの目的として扱う。
3. 次の type から一つを選ぶ。
   - `feat`: 機能追加
   - `fix`: 不具合修正
   - `refactor`: 振る舞いを変えない構造変更
   - `docs`: 文書だけの変更
   - `test`: 検査だけの変更
   - `build`: build または依存関係の変更
   - `ci`: CI の変更
   - `chore`: ほかに分類できない保守
   - `style`: 意味を変えない形式変更
   - `perf`: 性能改善
   - `revert`: 既存 commit の取り消し
4. 差分の結果を表す日本語の要約を付ける。件名全体を 50 文字以内にする。
5. repository root の `CONTRIBUTING.md` と同じ形式であることを確認する。

## Output format

```text
<type>: <日本語の要約>
```

例:

```text
feat: TypeScript の language server を追加する
fix: resource reaper の競合を防ぐ
docs: セットアップ手順を更新する
```

## Don'ts

- `fix(agents): ...` のような scope を付けない。
- body、footer、trailer、AI attribution を付けない。
- `wip:` や独自 type を作らない。
- 「調整する」「更新する」だけで対象と結果が分からない件名にしない。
- 50 文字を超えない。
