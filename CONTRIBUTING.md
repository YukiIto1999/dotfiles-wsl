# Contributing

このリポジトリは YukiIto1999 の個人環境を管理する。一般環境との互換性や fork の導入支援は提供しない。保守は feature branch や pull request を必須にせず、確認済みの変更を `main` へ直接 commit する。

## 変更

- 一つの commit には一つの目的だけを入れる。
- [変更箇所](docs/reference/change-map.md)から責務の所有者を特定し、生成先ではなく正本を直す。
- secret、token、鍵、個人情報を平文で追加しない。
- 振る舞いを変える場合は、変更前に対応する focused check が意図した理由で失敗することを確認する。
- rebuild、deploy、push は、source の検証と差分確認が終わってから別の操作として行う。

## 検証

編集中は変更した unit の check だけを実行する。

```bash
nix build --no-link .#checks.x86_64-linux.<check>
```

最後の source 変更後に、全件確認を一度実行する。

```bash
dotfiles-agent-verify -- nix flake check -L --no-write-lock-file
```

## コミット

件名は scope なし、50 文字以内の一行にする。本文と trailer は付けない。

```text
<type>: <日本語の要約>
```

使用できる type は次のとおり。

| type | 用途 |
|---|---|
| `feat` | 機能を追加する |
| `fix` | 不具合を修正する |
| `refactor` | 振る舞いを変えずに構造を直す |
| `docs` | 文書だけを変更する |
| `test` | 検査だけを変更する |
| `build` | build や依存関係を変更する |
| `ci` | CI を変更する |
| `chore` | 上記に含まれない保守を行う |
| `style` | 意味を変えずに形式を整える |
| `perf` | 性能を改善する |
| `revert` | 既存の commit を取り消す |

```text
feat: TypeScript の language server を追加する
fix: resource reaper の競合を防ぐ
docs: セットアップ手順を更新する
```

`fix(agents): ...` のような scope、複数行の説明、AI attribution は commit-msg hook が拒否する。
