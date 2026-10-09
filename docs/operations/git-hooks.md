# Git hook

**読み手:** repository に hook を置く人と、hook に止められた commit や push を扱う運用者。作業中に読む。

Git の global 設定は `core.hooksPath` を `~/.config/git/hooks` に向け、そこへ dotfiles の dispatcher を置く。正本は [`toolchain/git/package.nix`](../../toolchain/git/package.nix) と [`toolchain/git/assets/hooks/`](../../toolchain/git/assets/hooks) である。

## 実行の順序

dispatcher は dotfiles の検査を先に実行し、通った場合だけ repository の `.githooks/<hook>` を同じ引数と標準入力で実行する。
どちらかが失敗すると、その終了 status で Git の操作を止める。
dotfiles の検査は pre-commit の既知の secret 形式の検出、commit-msg の件名規約、pre-push の検証で、それ以外の hook では repository 側だけが走る。
pre-commit の検査対象と制限は [セキュリティ境界](../architecture/security.md#git-の追跡対象)を参照する。

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

## 検証の段と入口

repository は検証の段ごとに入口を宣言する。段の意味と時間予算は architecture-standard の `process/verification.md` が定め、dotfiles は入口の名前と置き場だけを解決する。

| 段 | 入口の名前 | 実行する者 |
|---|---|---|
| T1 | `verify` | agent が作業を終える前の門(`dotfiles-agent-gate`) |
| T2 | `verify-push` | push の前の pre-push |
| T3 | `verify-full` | project が選んだ契機。commit と push を止めない |

共有resolverはrepositoryの正本を呼ぶ文字列だけを返し、検査の定義やcacheを別に持たない。
Nix appにいずれかの段が宣言されていれば、三段ともNixを正本にし、未宣言の段を他の形式へ補完しない。
flakeの取得や評価が失敗した場合は、入口未宣言として通さずに拒否する。

| 置き場 | 宣言 | 呼び出し |
|---|---|---|
| `flake.nix` | `apps.<system>.verify-push` | `nix run --no-write-lock-file .#verify-push` |
| `devenv.nix` | `scripts.verify-push` | `devenv shell -- verify-push` |
| `package.json` | script `verify:push` | lock fileに応じて`pnpm verify:push`または`npm run verify:push` |
| `Makefile` | target `verify-push` | `make verify-push` |

Nixの検証段を宣言しないrepositoryは、devenv、package.json、Makefileの順で既存の入口を解決する。
これは他projectの入口への接続であり、dotfilesの検証taskの正本は`flake.nix`だけに置く。
NixのGit sourceへ入らない未追跡fileを持つrepositoryは、先に追跡してから検証する。

## push の前の検証

pre-pushは、repositoryが`verify-push`を宣言していればrepositoryの根で実行する。
送信する各refのcommitがHEADと一致し、index、作業木、未追跡file、submoduleに差分がない場合だけ、そのsourceを検証する。
annotated tagは参照するcommitで比較し、差分を隠すassume-unchangedとskip-worktreeの印も拒否する。
検証後にHEAD、source、indexの印が変わっていれば、入口が成功してもpushを拒否する。
入口を宣言しないrepositoryと、送信sourceのない削除だけのpushは検証を要求しない。

予算は入口の解決を含めて15分で、超えた検証を子孫のprocessごと止めてpushを拒否する。
必須検査を`verify-full`へ移すのでなく、必要な保証を保ったまま重複実行、選択範囲、起動とbuildの固定費を見直す。
成功、失敗、中断時には経過時間をstderrへ出す。

検証を通さずに push する必要があるときは、理由を添えて次の環境変数を渡す。

```bash
DOTFILES_VERIFY_PUSH_BYPASS='<理由>' git push
```

省いた push は、時刻、repository、HEAD、入口、理由を `~/.local/state/dotfiles-wsl/git/verify-push-bypass.log` へ追記する。この省略は利用者だけが使い、agent は使わない。`git push --no-verify` は repository の hook も含めて全てを飛ばし、記録も残らないため使わない。
入口の解決自体が失敗した場合も、利用者が理由付きbypassを指定すれば検証を省き、入口を`未解決`として記録する。
