# 開発

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

このリポジトリ固有の保守環境と検査は [flake.nix](../../flake.nix) が定義する。Home Manager が日常利用向けに配備する command とは用途が異なる。

## Dev shell

checkout ごとに `.envrc` を一度だけ許可すると、ディレクトリへ入ったときに既定の devShell が有効になる。

```bash
cd ~/dotfiles-wsl
direnv allow
```

[`.envrc`](../../.envrc) は nix-direnv の fallback を無効にしている。flake の評価に失敗した場合は、以前の devShell を再利用せず、その場で失敗する。

direnv を使わない場合は同じ devShell へ明示的に入る。

```bash
nix develop
```

devShell に含める保守 command の正本は `flake.nix` の `devShells` である。個々の package をこの文書へ転記しない。

## 整形

リポジトリの Nix source を formatter に合わせて書き換える。

```bash
nix fmt
```

formatter の正本は `flake.nix` の `formatter` であり、CI の整形検査も同じ実装を使う。`nix fmt` はファイルを変更する command なので、実行後に diff を確認する。

## 検査

flake が宣言する build、静的検査、生成設定の構文検査をローカルで実行する。

```bash
nix flake check -L
```

`nix flake check` は検査結果を返し、`nix fmt` のように source を整形しない。検査項目の正本は各 unit の `checks.nix` であり、`flake.nix` の `mergeChecks` がそれらを集めて id の重複を拒否する。check 名の一覧はここに複製しない。どの制約がどの検査で守られているかは[機械検証に固定した制約](../reference/verified-constraints.md)を見る。

check を足したら、緑を見る前に赤を見る。検査対象を意図的に壊し、期待した message で落ちることを確かめてから戻す。落ちなければその検査は無効である。一つの検査は一つの結果だけを確かめる。複数を束ねると、最初の失敗が残りを隠す。

新しい check は[機械検証に固定した制約](../reference/verified-constraints.md)へ載せる。載せ忘れも、実在しない check 名の記載も `docs-constraint-coverage` が落とす。文書を足したときの読み手の行は `docs-reader` が落とす。

Markdown を含む作業ツリーの空白エラーは Git でも確認する。

```bash
git diff --check
```

## CI

[`.github/workflows/check.yml`](../../.github/workflows/check.yml) は `main` への push と pull request、手動実行で `nix flake check "git+file://${GITHUB_WORKSPACE}" -L` を実行する。CI は checkout 済みの Git tree を入力にし、検査内容はローカルと同じ経路で各 unit の `checks.nix` から集める。
