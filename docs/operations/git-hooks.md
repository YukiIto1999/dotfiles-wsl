# Git hook

**読み手:** repository に hook を置く人と、hook に止められた commit や push を扱う運用者。作業中に読む。

Git の global 設定は `core.hooksPath` を `~/.config/git/hooks` に向け、そこへ dotfiles の dispatcher を置く。正本は [`toolchain/git/package.nix`](../../toolchain/git/package.nix) と [`toolchain/git/assets/hooks/`](../../toolchain/git/assets/hooks) である。

## 実行の順序

dispatcher は dotfiles の検査を先に実行し、通った場合だけ repository の `.githooks/<hook>` を同じ引数と標準入力で実行する。どちらかが失敗すると、その終了 status で Git の操作を止める。dotfiles の検査は pre-commit の GitHub token 検出と commit-msg の件名規約で、それ以外の hook では repository 側だけが走る。

dispatcher を置く hook は、githooks(5) の client 側 hook のうち repository が使う名前である。現在の一覧は次で確かめる。

```bash
ls ~/.config/git/hooks
```

reference-transaction と post-index-change は置かない。ref と index の更新ごとに起動されるため、置くだけで全 repository の Git 操作に process の起動が加わる。

## repository の hook

repository の hook は `.githooks/<hook>` に実行権付きで置く。repository 側で `core.hooksPath` を上書きしない。上書きすると、その repository では dotfiles の検査が走らなくなる。

repository の hook は、利用者が信頼した repository でだけ走る。信頼は repository ごとに一度だけ与え、linked worktree は同じ設定を共有する。

```bash
git config dotfiles.hooks.trusted true
```

clone しただけの repository の code を、commit や checkout のたびに実行しないためである。信頼していない repository に hook があると、dispatcher は実行せずに、そのことを stderr へ一行だけ出す。dotfiles の検査は信頼の有無にかかわらず走る。
