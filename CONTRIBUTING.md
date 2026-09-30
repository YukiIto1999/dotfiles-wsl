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

件名は scope なし、50 文字以内の一行にする。本文と trailer は付けない。type 接頭辞はどの repository でも省かない。

```text
<type>: <日本語の要約>
```

要約は変更の目的を一つだけ短く示し、個人名を含めない。「〜の追加」「〜の見直し」のような体言止めで終え、「…する」「…した」「…を直す」「…にする」「…しない」のような動詞や形容詞の終わり方と、「…へ」「…に」のような助詞の終わり方を使わない。読点「、」と句点「。」も使わない。語を簡潔に並べるときは中黒「・」を使ってよい。

件名は句点を付けない見出しとして一覧で読まれる。名詞で終えると、時制も主語も意図の表明も持たないラベルとして閉じ、並べても揃って読める。動詞で終えると文になり、句点がないため途中で切れた文に読める。「…する」は予定を、「…した」は報告を持ち込むが、見出しにはどちらも要らない。一行のラベルに読点があれば、そこに二つの関心が入っている印になる。中黒は語を並べるだけで文を作らないため許容する。文書の本文はこの逆で、句点で終わる完結した文で書く。

使用できる type は次のとおり。

| type | 用途 |
|---|---|
| `feat` | 機能の追加 |
| `fix` | 不具合の修正 |
| `refactor` | 振る舞いを変えない構造の変更 |
| `docs` | 文書だけの変更 |
| `test` | 検査だけの変更 |
| `build` | build や依存関係の変更 |
| `ci` | CI の変更 |
| `chore` | 上記に含まれない保守 |
| `style` | 意味を変えない形式の調整 |
| `perf` | 性能の改善 |
| `revert` | 既存の commit の取り消し |

```text
feat: TypeScript の language server の追加
fix: resource reaper の競合の防止
docs: セットアップ手順の更新
fix: 読点・句点を含む件名の拒否
```

`fix(agents): ...` のような scope、複数行の説明、動詞や形容詞や助詞で終わる要約、読点、句点、AI attribution は commit-msg hook が拒否する。
