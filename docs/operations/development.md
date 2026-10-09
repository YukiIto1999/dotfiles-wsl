# 開発

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

このリポジトリ固有の保守環境と検査は [flake.nix](../../flake.nix) が定義する。Home Manager が日常利用向けに配備する command とは用途が異なる。

## Dev shell

checkout ごとに、その root で `.envrc` を一度だけ許可すると、ディレクトリへ入ったときに既定の devShell が有効になる。

```bash
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

検査項目は各unitの`checks.nix`に置き、`flake.nix`が収集して段ごとに実行する。

```bash
nix run --no-write-lock-file .#verify-full
```

編集中は変更したunitのcheckだけを`nix build --no-link .#checks.x86_64-linux.<check>`で実行する。
最後のsource変更後には、repositoryの根でT1を一度実行する。

```bash
dotfiles-agent-verify -- nix run --no-write-lock-file .#verify
```

同じ source、command、環境で成功済みなら、`dotfiles-agent-verify` は保存した成功を返す。source か環境が変われば実行し直す。agent session ごとに新しい target directory を作らず、runtime が割り当てる Cargo の build-dir を使う。

T1の`verify`は全unitの検査と全hostおよび既存variantのtoplevel評価を行い、T2の`verify-push`はunitの検査とsystem closureを実現する。
`verify-full`は既存の全量flake checkを呼び、CIと明示的な全量確認の経路を保つ。
Nix buildの成功だけでは終了gateの証跡にならず、宣言した入口を既存wrapperで通した同じsourceに限り受理される。
T1は入口の解決、指紋の取得、検査、証跡の保存を含めて120秒以内とし、wrapperが残り時間で停止して非ゼロ終了にする。
成功証跡は検査前のsourceへ固定して走行ごとに仮保存し、cacheの保存と後始末、証跡の公開が時間内に完了した場合だけwrapperが確定するため、公開途中の失敗や中断、sourceの差し替えでは未検査のsourceに対する終了を認めない。
nativeな`verify`自身も検査を120秒で止め、外側の期限や中断を内側のprocess groupへ転送して終了を待つが、wrapperを通さない実行は終了gateを開かない。
検査を変更したときは、予算を理由に必須の検査をT3へ移さず、Nixの依存と再利用を見直す。
未追跡fileはNixのGit sourceに含まれないため、検証前に`git add`または`git add -N`で追跡する。
checkの一覧は複製せず、どの制約がどの検査で守られているかは[機械検証に固定した制約](../reference/verified-constraints.md)を見る。

check を足したら、緑を見る前に赤を見る。検査対象を意図的に壊し、期待した message で落ちることを確かめてから戻す。落ちなければその検査は無効である。一つの検査は一つの結果だけを確かめる。複数を束ねると、最初の失敗が残りを隠す。

新しい check は[機械検証に固定した制約](../reference/verified-constraints.md)へ載せる。載せ忘れも、実在しない check 名の記載も `docs-constraint-coverage` が落とす。文書を足したときの読み手の行は `docs-reader` が落とす。

Markdown を含む作業ツリーの空白エラーは Git でも確認する。

```bash
git diff --check
```

## unit の中で path を書く

同じ root unit 配下の Nix 資材は、参照元からの `./` または `../` で指す。root unit をまたぐ実装参照は作らず、型付き option を介す。境界検査に登録した共通 helper だけは相対 path で import できる。`${self}` は repository 全体の走査や、checkout 全体を必要とする実行時 path に使う。

`${self}` と `./` は様式の違いではない。`./x` は `x` だけを含む独立した store path になり、`${self}/x` は checkout 全体の store path の中を指す。実行時に隣のファイルを解決する script は後者でなければ壊れる。単体で完結する fixture と data は前者でよい。

repo root から見た path を unit の中の file にそのまま書かない。`skills/fixtures/x` を `skills/` unit の中に書くと `skills/skills/fixtures/x` に解決する。

## CI

[`.github/workflows/check.yml`](../../.github/workflows/check.yml)は`main`へのpushとpull request、手動実行で、checkout済みのGit treeの`verify-full`を実行する。
CI独自の検査一覧を持たず、rootのNix appから各unitの`checks.nix`とhost closureを検査する。

commit の粒度と件名は [Contributing](../../CONTRIBUTING.md) に従う。
