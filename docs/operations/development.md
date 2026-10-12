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
fileの欠落と不正な値は、既定値でも無制限でも補わず拒否する。
共有resolverは`frontend`と`entries`から入口を解決し、入口の有無を調べるためにNixを取得、評価しない。
Nix appを自動検出しないため、他projectがNixの検証入口を使うときもこの登録が必要である。
登録済みの入口の予算が読めない場合は、終了gateとpre-pushも拒否する。
追跡済みの登録fileを削除しても入口なしとして通さず、欠落として拒否する。
T1は入口の解決、指紋の取得、検査、証跡の保存を含めて`verify.seconds`以内とし、wrapperが残り時間で停止して非ゼロ終了にする。
成功証跡は検査前のsourceへ固定して走行ごとに仮保存し、cacheの保存と後始末、証跡の公開が時間内に完了した場合だけwrapperが確定するため、公開途中の失敗や中断、sourceの差し替えでは未検査のsourceに対する終了を認めない。
nativeな`verify`自身も同じ`verify.seconds`で検査を止め、外側の期限や中断を内側のprocess groupへ転送して終了を待つが、wrapperを通さない実行は終了gateを開かない。
T1は`flake.nix`の`t1Shards`で検査を`systems`と`units`の二つに分け、`dotfiles-run-each`が評価器を最大2つ同時に走らせる。
`systems`は全hostとvariantのtoplevel評価、それを再び強制する`nixos-system-negative-eval`、sourceの全体を読む静的検査と文書検査を受け持ち、`units`は残りの全unitの検査を受け持つ。
同じsystemの評価を共有する検査は同じshardに置き、別の評価器で同じsystemを評価し直さない。割当てに無い検査は`units`へ入るため、新しい検査は宣言だけでT1に入り、shardの名前を挙げ忘れて検査が抜けることはない。
評価器のBoehm GCの初期heapは4GiBとし、`GC_INITIAL_HEAP_SIZE`を設定済みの場合は上書きしない。
初期heapの値は実RSSの上限ではなく、評価器を合わせたメモリの必要量は実行条件とともに測る。
最初に失敗したshardの終了statusを返し、動いている評価器を止めて終了を待つ。
契約検査用のvariantは`mkProbeSystem`で構成し、検査対象と独立したNixOSのmanualとHome Managerのmanpageを生成しない。
登録した全hostとgateway portを変えた既存variantは、従来どおりmanualを含む構成でtoplevelを評価する。
`project-memory`を無効にするAgentの検査は、同じvariantのconfigを共有する。
基準hostのoption宣言一覧は一度だけ作り、root ownerの確認と宣言位置の確認で共有する。
検査を変更したときは、予算を理由に必須の検査をT3へ移さず、Nixの依存と再利用を見直す。

`verify.seconds`は、必要な検査の範囲と実行環境の実測から決め、強制停止の上限として扱う。
初回計測は600秒を有限の上限として、正規wrapperから全unitと全host・variantのT1を完走した。
計測sourceのNAR hashは`sha256-WOE/qLsoAekfKkTlDlQCmLhFKR3nmujuO/YP9BlarXQ=`である。

| 項目 | 初回の観測値 |
|---|---|
| wrapperの開始から証跡確定まで | 109.478秒 |
| 終了status | 0 |
| 計測scopeのCPU時間 | 109.641612秒 |
| 計測scopeのピークメモリ | 9,981,075,456 bytes、約9.30GiB |

計測は`agents.slice`内の専用scopeで行い、wrapper、最大2つの評価器とその子処理を含むが、Nix daemon側のbuilderは含まない。
評価器の初期GC heapは各4GiBで、共有cacheには既存の成果物と、この走行でbuildした成果物の両方があった。
cacheを消した初回起動、異なるCPU負荷と全体のピークメモリは未計測である。
旧120秒の走行は121.29秒、終了status 124で打ち切られたが、cacheとsourceが異なるため、今回の成功を速度改善の証拠にはしない。

このprojectの上限は300秒とし、今回の完走時間に約2.7倍の余裕を持たせる。
余裕は未計測の初回buildと共有資源の競合に備える判断であり、それらが300秒以内に収まる実測保証ではない。
同じ条件でのフィードバック目標は、今回の完走時間を基準に約110秒とする。
必要な範囲、cache、並列数、実行環境または資源の競合が変わったときは、必要な検査を減らさず再計測して、次の走行前に上限と理由を更新する。
失敗した走行の途中では上限を延ばさない。
T2の900秒は従来のproject設定を引き継いだ値であり、今回のT1計測からT2の完走時間を推定しない。

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
