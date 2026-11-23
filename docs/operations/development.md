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

保守 command は `flake.nix` の `devShells` で選ぶ。
ホストの設定を評価できないときも、同じ devShell を起動して修正に使える。

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

`dotfiles-agent-verify`は毎回commandを実行し、同じprojectのT1だけを直列化する。
成果物はNixやCargoの依存に従って再利用する。
agent sessionごとに新しいtarget directoryを作らず、[`toolchain/execution/`](../../toolchain/execution)の実行方針が割り当てるCargoのbuild-dirを使う。
新しいfileはT1の前に`git add`か`git add -N`で追跡する。証跡は作業木の中身に付き、通った後のstage、commit、amendは証跡を保つが、通った時に未追跡だったfileを後で追跡すると別の木になる。

配備済みの`dotfiles-agent-verify`がcheckoutの宣言より古い間は、同じ宣言から組み立てたwrapperをcheckoutから起動する。

```bash
nix run --no-write-lock-file .#dotfiles-agent-verify -- nix run --no-write-lock-file .#verify
```

`nix run .#verify`の直接実行と`dotfiles-agent-gate waive`は、wrapperが確定した証跡の代わりにならない。
`dotfiles-agent-gate waive`の免除は、書いたsession（`DOTFILES_AGENT_SESSION_ID`が同じ呼出し）のcheckと終了だけを、その時点の木に限って通し、別のsessionの終了は通さない。

T1の`verify`は全unitの検査と全hostおよび既存variantのtoplevel評価を行い、T2の`verify-push`はunitの検査とsystem closureを実現する。
`verify-full`は既存の全量flake checkを呼び、CIと明示的な全量確認の経路を保つ。
Nix buildの成功だけでは終了gateの証跡にならず、宣言した入口を既存wrapperで通した同じsourceに限り受理される。
T1とT2の時間は、rootの[`tiergate.json`](../../tiergate.json)の各段（`verify`、`verify-push`）が持つ二つの値を唯一の正本とする。
`seconds`は走行の上限、`feedbackTargetSeconds`は検証が返る目標である。
このfileは`{"version":1,"frontend":"nix","entries":["verify","verify-push","verify-full"],"verify":{"seconds":N,"feedbackTargetSeconds":T,"basis":"..."},"verify-push":{...}}`の形で、Nは1以上2147483647以下の整数である。
Tは省略でき、宣言した場合は1以上N以下の整数でなければならない。`basis`は値の根拠を書く文字列で、resolverは読まない。
`flake.nix`の各入口は評価時に、`dotfiles-agent-verify`とpre-pushは走行の開始時に、同じfileを読む。
wrapperとpre-pushは静的な宣言を一度snapshotへ読み、同じsnapshotから時間予算と入口を解決する。
解決の間に登録を編集しても、canonicalな呼び出しが無制限の実行へ切り替わることはない。
fileの欠落と不正な値は、既定値でも無制限でも補わず拒否する。
共有resolverは`frontend`と`entries`から入口を解決し、入口の有無を調べるためにNixを取得、評価しない。
Nix appを自動検出しないため、他projectがNixの検証入口を使うときもこの登録が必要である。
登録済みの入口の予算が読めない場合は、終了gateとpre-pushも拒否する。
追跡済みの登録fileを削除しても入口なしとして通さず、欠落として拒否する。
T1は入口の解決、sourceの照合、検査、証跡の保存を`verify.seconds`で制限し、wrapperは残り時間を使い切った時点で取消を開始して非ゼロ終了にする。
同じprojectのslotと機全体の資源の空きを待つ時間は予算に数えず、それぞれ予算と同じ秒数の上限で打ち切って、検査を実行せず75で返す。検査の枠は資源に入場して起動した時から数える。slotを待った秒数は、走行の記録の`slotWaitSeconds`に残る（[Doctor](doctor.md#資源不足による開始待ち)）。
T1の検査本体の資源予約は、repositoryの根と入口のcommandごとに残した実測のピークから需要を決め、記録が無い走行はこのhostの他の鍵の実測の中央値で、他の鍵の記録も無い走行だけが未計測の既定値で予約する。仕組みは[Doctor](doctor.md#資源不足による開始待ち)を参照する。
上限は暴走した走行だけを止め、目標は取消にも成否の判定にも使わない。
wrapperとpre-pushは目標を時間予算と同じsnapshotから読み、検査本体の走行のsupervisorへ`--resource-target-seconds`で渡す。不正な目標は不正な上限と同じく、補完も無視もせず拒否する。
supervisorは資源予約を持つ走行の終了時に、走行のscopeのcgroupからCPU時間（`cpuSeconds`）と、CPU、IO、memoryの滞留（`cpuStallSeconds`、`ioStallSeconds`、`memoryStallSeconds`）を読み、`--result`とjournalへ秒で残す。
走行が目標の時点でなお動いていれば、同じ四つの値をその時点で読み、`atTarget`として残す。目標より前に終わった走行の`atTarget`はnullである。
終了時には回収後の再fault・swap入出力・`memory.high`の発火も記録する。祖先の発火は同じ期間の他の走行を含むため、[Doctorの計測項目](doctor.md#資源不足による開始待ち)に従って読み分ける。
上限に達した場合や外から取り消された場合も、読めた値だけを残す。欠測値はnullで、計測は終了statusを変えない。
走行が目標を超えると、wrapperは目標、走行秒数、走行秒数に占める三つの滞留の割合をstderrへ出す。資源のsupervisorが走行の上限に達した場合は、目標の有無によらず終了時のscopeのCPU時間を示す。目標を超えた走行では目標時点のCPU時間も添える。
入口が自分で75や124を返しても同じ番号が呼び出し側へ戻る。資源予約の有無によらず、監督器は走行の期限を単調時計で計り、期限に達して子孫を回収した後に `run deadline reached` と報告する。CPU時間が増えても空転とは区別できず、増えなくてもscope外のNix daemonなどで仕事が進むことがある。上限を見直す前に、検査本体の出力や成果物でどこまで進んだかを確かめる。
成功証跡は検査前のsourceへ固定して走行ごとに仮保存し、検査後のsourceとの一致、後始末、証跡の公開が時間内に確認できた場合だけwrapperが確定する。
公開途中の失敗や中断、sourceの差し替えでは未検査のsourceに対する終了を認めない。
pre-pushは検査前と検査後の`git status`と`git ls-files`の失敗も拒否し、sourceを確認できなかった走行ではremoteのrefを更新しない。
nativeな`verify`自身も同じ`verify.seconds`で検査を止め、外側の期限や中断を内側へ転送する。
別sessionへ移った子孫も回収して終了を確認するため、後始末は予算を超えて続くことがある。
native検査の公開PIDだけへの`SIGINT`も`SIGTERM`と同じ取消として扱い、所有する子孫の終了を確認してから非成功の130で返る。
wrapperを通さない実行は終了gateを開かない。
T1は全unitの検査をまとめた一つのNix derivationをbuildし、依存の並列実行と成果物の再利用をNixへ任せる。
集約時に全check IDの一意性と全host・positive variantのsystem closureを評価し、評価器を分ける独自schedulerは持たない。
`source`と`configuration`は検査が受け取る入力の区分であり、別の走行計画ではない。
各unitの`checks.nix`はnative moduleの入口であり、leafが`source`のpackage集合か`configuration`のcallbackを宣言する。
登録対象はsource内のcheck fileから導き、native module graphでimportとphaseの漏れを拒否するため、手書きの割当て一覧は不要である。
check IDは両phaseとsystem closureを通して一意でなければならない。
workflow の検査は設定を含む `.github/` だけを Nix の source 入力とし、他の原文の変更では成功した derivation を再利用する。
Nix の静的検査と整形検査は全 `.nix` file を入力とし、`statix` だけが追加で `statix.toml` を読むため、文書や他言語の変更では成功した derivation を再利用する。
Git hook の振る舞い検査も対応する hook の file を入力とし、無関係な checkout の変更では再実行しない。
unit境界、option namespace、責務rootの検査は読む範囲の`.nix` fileだけを、unit moduleの検査は`module.nix`だけを、読み手の明示の検査は`docs/`の分類別の文書だけを、SOPSの検査は暗号文とrecipientの宣言だけを入力とする。
Agentの契約検査は読むfileだけを入力とし、旧pathの残存はcheckout全体を読む別の検査が受け持つ。
T1 wrapperの振る舞い検査は、[runtimeの検査定義](../../agents/checks/runtime.nix)で独立したderivationに分ける。
各場面は[共通のfixture](../../agents/fixtures/runtime/verify-common.sh)をsourceし、repositoryとHOMEを個別に作る。
同じ木の前後を照合する走行は一つの場面に保ち、別のderivationが残す状態には依存しない。
各derivationはその場面のscriptと共通fixture、必要なwrapperだけを入力とし、並列実行と完了済みの成果物の再利用をNixへ任せる。
ShellCheckはcheckoutと生成済みwrapperの対象を集めて検査し、最初のfileの指摘だけで止めずに複数fileの診断を返す。
checkoutの対象は一つのprocessで先頭の2 byteを読み取って列挙し、fileごとのshell起動を行わない。
shebangの判定、linkの到達、表示したpathの実在はcheckout全体を読まないと確かめられないため、ShellCheck、`docs-links`、`docs-path-labels`は入力を狭めない。
評価器のBoehm GCの初期heapは4GiBとし、`GC_INITIAL_HEAP_SIZE`を設定済みの場合は上書きしない。
初期heapの値は実RSSの上限ではなく、評価器のメモリの必要量は実行条件とともに測る。
契約検査用のvariantは`mkProbeSystem`で構成し、検査対象と独立したNixOSのmanualとHome Managerのmanpageを生成しない。
登録した全hostとgateway portを変えたvariantはmanualを含めて評価し、最小Capabilityと`project-memory`無効のpositive variantもsystem closureを評価する。
基準hostのoption宣言一覧は一度だけ作り、root ownerの確認と宣言位置の確認で共有する。
検査を変更したときは、予算を理由に必須の検査をT3へ移さず、Nixの依存と再利用を見直す。

上限は暴走した走行だけを止める値で、他の処理が並走する条件で完走した最も遅い走行の実測に、宣言した定数を掛けて決める。
目標は検証がその時間で返るように設計した値で、超えた走行は報告して見直し、取り消さない。
値と、実測の日時と条件、定数は、同じ段の`basis`へ残す。
必要な範囲、cache、並列数、実行環境または資源の競合が変わったときは、必要な検査を減らさず再計測して、次の走行前に上限、目標、理由を更新する。
失敗した走行の途中では上限を延ばさない。

上限で取り消された走行が、その時点でなお進んでいたかは、走行のscopeの`cpuSeconds`が目標の時点の読取（`atTarget`）から終了時の読取へ増えたかで判定する。
増えていた走行は、必要な時間が上限より長い。次の走行の前に上限を見直すときは、その走行の経過秒数を必要な時間の下限として使う。
増えていなかった走行は、進んでいなかった疑いがあり、上限を延ばす前に止まった原因を調べる。
Nixのbuildはnix-daemonのcgroupで動くため、Nixでbuildする入口ではscopeのCPU時間が実際より小さく、滞留の読取もclientの分しか含まない。

未追跡fileはNixのGit sourceに含まれず、証跡の鍵にもpathの一覧として入るため、検証前に`git add`または`git add -N`で追跡する。
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
