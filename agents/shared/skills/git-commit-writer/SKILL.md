---
name: git-commit-writer
description: Use when writing a Conventional Commits message for staged changes(`git diff --staged` で取得)。type / scope / breaking change を自動判定、複数論理変更が混ざっていれば `git reset` 経由の分割を提案。Trigger on `git add` 完了後 / `git status` で staged changes あり / commit 直前 even if user does not say "commit".
---

# Git Commit Writer

## When to invoke

- ユーザーが「コミット」「commit」「commit message を書いて」と依頼したとき
- 実装完了後、`git add` 済みの状態

## Process

1. **対象確認**:`git diff --staged` で staged 変更を取得。staged が空なら `git status` を見て確認
2. **分割判定**:1 commit に **無関係な** 複数の論理変更(例: 機能追加 + 別所の rename)が混ざっていれば、`git reset` + 分割提案。一方、**機能と一体の付随変更**(新機能 + その usage を docs に追記、新機能 + 対応 test)は 1 commit で OK
3. **type 判定**:変更内容から以下を選択:
   - `feat`: 新機能
   - `fix`: バグ修正
   - `refactor`: 振る舞いを変えない内部改善
   - `docs`: ドキュメントのみ
   - `test`: テストのみ
   - `chore`: ビルド/依存/設定
   - `style`: フォーマットのみ
   - `perf`: パフォーマンス改善
   - `revert`: revert
4. **scope 判定**:以下の優先順位で判定:
   1. 変更ファイルの **basename**(拡張子除く)を **kebab-case** 化(例: `lib/csv_parser.go` → `csv-parser`)
   2. 複数ファイルで同一モジュール配下なら **モジュール名** を kebab-case 化(例: `src/server/middleware/auth.py` + `src/server/middleware/utils.py` → `middleware` or `auth`)
   3. `lib/` / `src/` / `pkg/` 等の generic dir 名は **scope として採用しない**
5. **breaking change 検出**:以下の場合に `!` + `BREAKING CHANGE:` フッターを付与:
   - public API の signature 変更 / 削除 / 互換性破壊
   - 環境変数 / config schema の **必須化**(optional → required)
   - **公開 struct / record / class への field 追加** は **ambiguous case**: callsite を `git grep` で確認し、struct literal が positional(`MyStruct{a, b, c}`)で書かれていれば BREAKING、named-field 限定(`MyStruct{A: a, B: b}`)なら non-breaking。確認できない場合は **非 breaking として保守的に扱い**、PR レビューに判断を委ねる
6. **本文構成**:subject(50 chars 以内)+ 必要なら本文(72 chars 折返し、why を中心に)

## Output format

```
<type>(<scope>)!?: <subject>

<body>

<footer>
```

例:
```
feat(auth): add OAuth2 PKCE flow for mobile clients

Mobile apps cannot safely store client secrets, so PKCE is required.
The web flow remains unchanged.

Refs: #1234
```

## Don'ts

- 「とりあえず動く」のような曖昧な subject は出さない
- 50 chars 制限を超えない(subject)
- WIP commit は別途 `wip:` プレフィックスで明示(rebase 前提)
