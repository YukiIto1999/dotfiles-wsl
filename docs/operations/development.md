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

同じ source、command、環境で成功済みなら、`dotfiles-agent-verify` は保存した成功を返す。source か環境が変われば実行し直す。agent session ごとに新しい target directory を作らず、[`toolchain/execution/`](../../toolchain/execution)の実行方針が割り当てる Cargo の build-dir を使う。

配備済みの`dotfiles-agent-verify`がcheckoutの宣言より古い間は、同じ宣言から組み立てたwrapperをcheckoutから起動する。

```bash
nix run --no-write-lock-file .#dotfiles-agent-verify -- nix run --no-write-lock-file .#verify
```

`nix run .#verify`の直接実行と`dotfiles-agent-gate waive`は、wrapperが確定した証跡の代わりにならない。

T1の`verify`は全unitの検査と全hostおよび既存variantのtoplevel評価を行い、T2の`verify-push`はunitの検査とsystem closureを実現する。
`verify-full`は既存の全量flake checkを呼び、CIと明示的な全量確認の経路を保つ。
Nix buildの成功だけでは終了gateの証跡にならず、宣言した入口を既存wrapperで通した同じsourceに限り受理される。
T1とT2の時間予算は、rootの[`verification-budget.json`](../../verification-budget.json)の`verify.seconds`と`verify-push.seconds`を唯一の正本とする。
このfileは`{"version":1,"frontend":"nix","entries":["verify","verify-push","verify-full"],"verify":{"seconds":N},"verify-push":{"seconds":M}}`の形で、NとMは1以上2147483647以下の整数である。
`flake.nix`の各入口は評価時に、`dotfiles-agent-verify`とpre-pushは走行の開始時に、同じfileを読む。
wrapperとpre-pushは静的な宣言を一度snapshotへ読み、同じsnapshotから時間予算と入口を解決する。
解決の間に登録を編集しても、canonicalな呼び出しが無期限の局所cacheへ切り替わることはない。
fileの欠落と不正な値は、既定値でも無制限でも補わず拒否する。
共有resolverは`frontend`と`entries`から入口を解決し、入口の有無を調べるためにNixを取得、評価しない。
Nix appを自動検出しないため、他projectがNixの検証入口を使うときもこの登録が必要である。
登録済みの入口の予算が読めない場合は、終了gateとpre-pushも拒否する。
追跡済みの登録fileを削除しても入口なしとして通さず、欠落として拒否する。
T1は入口の解決、指紋の取得、検査、証跡の保存を`verify.seconds`で制限し、wrapperは残り時間を使い切った時点で取消を開始して非ゼロ終了にする。
成功証跡は検査前のsourceへ固定して走行ごとに仮保存し、cacheの保存と後始末、証跡の公開が時間内に完了した場合だけwrapperが確定するため、公開途中の失敗や中断、sourceの差し替えでは未検査のsourceに対する終了を認めない。
pre-pushは検査前と検査後の`git status`と`git ls-files`の失敗も拒否し、sourceを確認できなかった走行ではremoteのrefを更新しない。
nativeな`verify`自身も同じ`verify.seconds`で検査を止め、外側の期限や中断を内側へ転送する。
別sessionへ移った子孫も回収して終了を確認するため、後始末は予算を超えて続くことがある。
native検査の公開PIDだけへの`SIGINT`も`SIGTERM`と同じ取消として扱い、所有する子孫の終了を確認してから非成功の130で返る。
wrapperを通さない実行は終了gateを開かない。
T1は`flake.nix`の`t1Shards`で`source`と`configuration`を別の評価器へ分け、`dotfiles-run-each`が最大2つを同時に走らせる。
`source`はhostやvariantを評価せず、sourceと固定した入力だけを使う検査を実現する。
`configuration`はnative module graphと構成値を使う検査を実現し、全hostとpositive variantのsystem closureを評価する。
各unitの`checks.nix`はnative moduleの入口であり、leafが`source`のpackage集合か`configuration`のcallbackを宣言する。
登録対象はsource内のcheck fileから導き、native module graphでimportとphaseの漏れを拒否するため、手書きの割当て一覧は不要である。
check IDは両phaseとsystem closureを通して一意でなければならない。
評価器のBoehm GCの初期heapは4GiBとし、`GC_INITIAL_HEAP_SIZE`を設定済みの場合は上書きしない。
初期heapの値は実RSSの上限ではなく、評価器を合わせたメモリの必要量は実行条件とともに測る。
最初に失敗したshardの終了statusを返し、動いている評価器を止めて終了を待つ。
契約検査用のvariantは`mkProbeSystem`で構成し、検査対象と独立したNixOSのmanualとHome Managerのmanpageを生成しない。
登録した全hostとgateway portを変えたvariantはmanualを含めて評価し、最小Capabilityと`project-memory`無効のpositive variantもsystem closureを評価する。
基準hostのoption宣言一覧は一度だけ作り、root ownerの確認と宣言位置の確認で共有する。
検査を変更したときは、予算を理由に必須の検査をT3へ移さず、Nixの依存と再利用を見直す。

`verify.seconds`は、必要な検査の範囲と実行環境の実測から決め、強制停止の上限として扱う。
必要な範囲、cache、並列数、実行環境または資源の競合が変わったときは、必要な検査を減らさず再計測して、次の走行前に上限と理由を更新する。
失敗した走行の途中では上限を延ばさない。

未追跡fileはNixのGit sourceに含まれないため、検証前に`git add`または`git add -N`で追跡する。
checkの正本は各unitの検査と`flake.nix`の導出結果であり、件数やcheck名を文書の別一覧へ転記しない。

検査を変えるときは、利用側が依存する振る舞い、境界入力、状態遷移を意図的に壊すと失敗することを確かめる。
件数、文言、既定値、source文字列、forwardingの写しを期待値として固定しない。

文書間とsourceへのlinkは`docs-links`、文書が示すpathは`docs-path-labels`、読み手の明示は`docs-reader`が検査する。
これらの成功を、手順の実行成功や文書の主張の正しさとは扱わない。
ShellCheckはcheckoutと生成済みのshell scriptを静的に検査する。
配備済みprofileやuser managerを必要とするCLIは、build sandboxで`--help`の出力有無を見る検査ではなく、隔離した実行環境で起動と終了を確認する。

静的検査では、契約を介した依存の意味、文書種別の混在、宣言値の転記、fixtureと実装を同じ誤りへ変える変更までは判定できないため、レビューで確かめる。
listenerのbind先、未宣言のlistener、portの空き、container image由来の公開、通信制限の効果は、宣言やunitのactiveだけで成功とせず、実際のprocessとtool呼出しを観測する。
commit hookも日本語の形態素を判定するものではないため、件名の名詞終わりは書き手が確認する。

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
