# Contributing

このリポジトリは YukiIto1999 の個人環境を管理する。一般環境との互換性や fork の導入支援は提供しない。保守は feature branch や pull request を必須にせず、確認済みの変更を `main` へ直接 commit する。

## 変更

- 一つの commit には一つの目的だけを入れる。
- [変更箇所](docs/reference/change-map.md)から責務の所有者を特定し、生成先ではなく正本を直す。
- secret、token、鍵、個人情報を平文で追加しない。
- 振る舞いを変える場合は、変更前に対応する focused check が意図した理由で失敗することを確認する。
- rebuild、deploy、push は、source の検証と差分確認が終わってから別の操作として行う。
- `docs/`は現在の手順、構造、契約に同期させ、過去の実測や検討過程を非追跡の`work/`へ置く。
- `work/`に残した記録を共有する場合は、credentialや個人情報を除き、必要な部分だけを渡す。

## 検証

編集中は変更した unit の check だけを実行する。

```bash
nix build --no-link .#checks.x86_64-linux.<check>
```

最後のsource変更後に、repositoryの根でT1を一度実行する。

```bash
dotfiles-agent-verify -- nix run --no-write-lock-file .#verify
```

検査項目の正本は各unitの`checks.nix`で、段の集約と実行は`flake.nix`が所有する。
T1はunitの検査と全hostおよび既存variantの評価、T2の`verify-push`はそれらのsystem closureの実現、T3の`verify-full`は全量のflake checkを実行する。
T1は評価を`flake.nix`の`t1Shards`で二つの評価器に分けて同時に実行する。
予算を超えても必要な検査を後の段へ移さず、依存と実行計画を見直す。
NixのGit sourceから漏れる未追跡fileは、検証前に`git add`または`git add -N`で追跡する。

## コミット

件名は scope なし、50 文字以内の一行にする。本文と trailer は付けない。type 接頭辞はどの repository でも省かない。

```text
<type>: <日本語の要約>
```

要約は、変更の対象を読み手が扱う作業や物の名前で示し、その対象に起きた操作と、それで成り立つ結果を一つだけ短く書き、個人名を含めない。repository の中の directory や層の名前は対象にせず、採用、整備、明確化のような評価だけの語で変化を代えない。「〜の追加」「〜の見直し」のような体言止めで終え、「…する」「…した」「…を直す」「…にする」「…しない」のような動詞や形容詞の終わり方と、「…へ」「…に」のような助詞の終わり方を使わない。読点「、」と句点「。」も使わない。語を簡潔に並べるときは中黒「・」を使ってよい。

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
