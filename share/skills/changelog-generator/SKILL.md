---
name: changelog-generator
description: Use when generating a release changelog from Conventional Commits history(前回 tag..HEAD)to Keep a Changelog 形式。Breaking change / Added / Changed / Fixed / Reverted で分類、内部コミット(ci / docs(internal) / chore(release))は除外。Trigger on `CHANGELOG.md` 編集 / `gh release create` 直前 / 新しい `v*.*.*` tag 切る前 even if user does not say "changelog". 前提は 前回 tag が `git tag --sort=-v:refname` で取得可能であること。
---

# Changelog Generator

## When to invoke

- ユーザーが「changelog」「リリースノート」と依頼したとき
- バージョンタグを切る前後

## Process

1. **対象範囲決定** — `git tag --sort=-v:refname | head -1` で前回タグ、それと HEAD の間
2. **コミット取得** — `git log <prev-tag>..HEAD --pretty=format:'%H|%s|%b'`
3. **分類** — type 別に振り分け(Conventional Commits 前提):
   - `feat` → **Added**
   - `fix` → **Fixed**
   - `refactor` / `perf` / `chore(deps)` → **Changed**
   - 破壊的 (`!` または `BREAKING CHANGE:`) → **⚠ Breaking changes** に **のみ** 掲載(`Added` 等への二重掲載は禁止)
   - `revert` → **Reverted**
4. **フィルタ** — `chore(release)`, `chore(ci)`, `docs(internal)` 等のユーザー向けでないコミットは除外
5. **整形** — Keep a Changelog の標準形式に従う

## Output format

```markdown
## [<version>] - <YYYY-MM-DD>

## ⚠ Breaking changes
- <what changed and migration> (<7-char-hash>)

## Added
- <feature> (<7-char-hash>)

## Changed
- <change> (<7-char-hash>)

## Fixed
- <fix> (<7-char-hash>)

## Reverted
- <reverted feature> (<7-char-hash>)
```

### 出力規約

- 全 section header は `##`(version header と同じ level に揃える、`###` は使わない)
- 該当 commit が無い section は **完全に省略**(空 section や `(none)` のような placeholder は出さない)
- **Section order**: `## ⚠ Breaking changes` → `## Added` → `## Changed` → `## Fixed` → `## Reverted`(欠落 section は silently skip、order 自体は固定)
- commit reference は **短縮ハッシュ 7 文字**を `(<hash>)` 形式で末尾に付ける(full hash / URL リンクは長くなるため不採用)
- 破壊的変更は `feat!` でも `## Breaking changes` のみに掲載、`## Added` には入れない
- **`BREAKING CHANGE:` body** は bullet 末尾に `— <migration note>` 形式で inline する(`BREAKING CHANGE:` literal prefix は出力に含めない)
- **`## Reverted` の bullet** は元 revert commit の subject から `revert:` prefix を剥がし、対象 commit の subject(scope 含む)をそのまま掲載(例: `revert: feat(api): experimental rate-limit header` → `feat(api): experimental rate-limit header (3ccc333)`)

## Don'ts

- 内部コミット(CI 設定、test 追加のみ等)を release notes に混ぜない
- 1 行で重複する commit は集約(typo 修正 × 3 → 1 行)
- ユーザーに見えない場所の変更は省略(internal helper の rename 等)
