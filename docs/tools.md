# 道具の使い方

この環境が用意する道具のうち、使い方に条件があるものを書く。何が入っているかは `toolchain/module.nix`（CLI）、`agents/mcp/module.nix`（MCP server）、`agents/skills.nix`（upstream の skill）を読む。

## Browser

- 画面の確認と操作は OMP の標準 browser（Eval の `browser`）を使う。利用者の Chrome を使わない操作では `app: "auto"` か `app: "chromium"` を渡す。
- 標準 browser の managed Chromium は Nix の Chromium である。omp の wrapper が `PUPPETEER_EXECUTABLE_PATH` で渡す。OMP は project の directory ごとに一つ起動し、tab は session と subagent で分け合う。
- performance、Lighthouse、memory の診断には Chrome DevTools MCP を使う（`browser-performance`、`heap-analysis`）。
- Playwright MCP は置かない。OMP は標準 browser がある session で、名前や command が Playwright の MCP server を読み込まない。公式の解除方法は標準 browser を無効にすることだけで、両方は同時に使えない。Playwright の API で書く回帰 test は project の Playwright Test に置く。
- omp の package の `bin/omp` は、本体の library のために `LD_LIBRARY_PATH` を設定し、子 process もそれを継いだ。別の glibc で build された library を読み込んだ Chromium や qemu は、`GLIBC_2.xx not found` で起動できなかった。`omp` の wrapper は package の本体を直接起動するので、新しい session の command には渡らない。代わりに、OMP の音声出力（`say`）と Wayland の画面取得は使えない。この変更より前に起動した session と、それが始めた共有 daemon は値を持ったままなので、標準 browser と Chrome DevTools MCP は Chromium を起動する wrapper でも外している。古い session の bash で同じ error が出たら、`env -u LD_LIBRARY_PATH` を付けて起動する。

## Windows の独立した操作画面（Anode）

通常の Web 操作は、端末の入力を奪わない上の経路を使う。Windows アプリの実画面が必要で、利用者の入力と分けたい場合は [Anode](https://github.com/skulitom/Anode/tree/v0.11.4) の Windows 子 session を使う。同じ利用者の file と network を共有するので、security sandbox にはしない。
利用者が指定した、自分の desktop で開いている既存の window は別の seat で開き直せない。Orca の `orca computer`（`orca-computer-use`）で背景から扱う。keyboard 入力や実 pointer を要する操作は foreground を必要とするため、利用者の同意を得てから行う。

- 導入: `nix build --no-link --print-out-paths .#anode-windows` で固定した公式配布物を取得する。`share/anode/` の archive、checksum、上流 installer を Windows の一時 directory へ copy し、`install.ps1 -PackagePath <zip> -ChecksumPath <SHA256SUMS> -Client None -NoPath` で利用者の `LocalAppData` に入れる。installer は WSL の UNC path から zip を展開できない。rebuild は Windows への書込み、RDP の変更、seat の起動を行わない。
- `anode doctor --json` が ready なら `setup` を省く。`setup` は RDP と Windows 子 session を有効にし、既存の接続を切り得るので、影響を示して承認を得てから行う。
- `anode start --hidden --no-background-rendering` で seat を始め、WSL の `anode` CLI で操作する。複数 session で使う場合は seat の lease で順番を決める。WSL からの MCP 初期化は成功を確認できていないため、MCP server としては登録していない。

## CI と秘密情報の検査

- GitHub Actions の構文と式は `actionlint`、workflow とローカル action の安全性は `zizmor --offline .` で調べる。構文検査だけでは権限や credential の扱いを判定できない。
- stage した差分の秘密情報は `betterleaks git --staged --validation=false --redact .` で調べる。履歴全体を調べるときは範囲を別に指定する。検出値を出力に残さず、credential を network へ送る検証は有効にしない。

## Linux の process と Nix の診断

syscall は `strace`、CPU の内訳は `perf`、停止位置と thread は `gdb` で見る。対象にできる process と採取の許可は `runtime-observation` skill の「採取の範囲を守る」に従う。`hyperfine` は CLI や build の所要時間を反復して比べる道具で、関数や syscall ごとの観測とは分ける。kernel の制限で計測できないときは、共通の sysctl を下げずに不足を報告する。

| 調べたいこと | 入口 |
|---|---|
| 評価された設定 | `nix eval` |
| file を提供する package | `nix-locate`（固定した索引なので、無結果を不存在とみなさない） |
| 世代の package 差分、含まれる理由、derivation の差分 | `nvd diff`、`nix why-depends`、`nix-diff` |
| 保存された build log | `nix log` |

## Semgrep

`toolchain/package/semgrep.nix` が Semgrep 1.180.0 を NixOS 向けに組み立てる。wrapper は `SEMGREP_SEND_METRICS=off` と `SEMGREP_ENABLE_VERSION_CHECK=0` を既定にし、metrics の送信と版の照会を止める。明示した環境変数はこの既定を上書きする。remote rule の取得を含む通信を遮断する仕組みではない。この版では QL rule が廃止され、binary は既定で走査されない。

## Explainer

`explainer`、`explainer-book`、`first-reader` の skill は原版のまま使い、script の実行環境（Node 24、Playwright 1.61.1 の Chrome headless shell、`@mizchi/vlmkit` 0.22.0）は `toolchain/package/explainer/` が固定する。原版の script を直接 `node` で動かさず、次の wrapper を使う。

| 入口 | 第1引数 | 原版の script |
|---|---|---|
| `explainer-build-html` | Markdown file の絶対 path（複数ページは後続の引数） | `skills/explainer/scripts/build-html.mjs` |
| `explainer-verify-doc` | 文書 directory の絶対 path | `skills/explainer/scripts/verify-doc.mjs` |
| `explainer-verify-book` | book directory の絶対 path | `skills/explainer-book/scripts/verify-book.mjs` |
| `explainer-figure-check` | 図 file の絶対 path | `skills/explainer/scripts/figure-check.mjs` |
| `explainer-vlmkit` | 原版 CLI の subcommand | `@mizchi/vlmkit` の CLI |

- 最初の四つは相対 path を exit 2 で拒否し、呼出しごとに `${TMPDIR:-/tmp}/explainer-runtime.XXXXXX` を作業 directory にする。report は出力に示された path から取り出す。
- `verify-doc.mjs` は文書の祖先にある `package.json` を依存の root にする。文書は project の package の外の専用 directory に置く。
- `verify-doc.mjs` は subprocess の exit を捨てて出力だけを照合するため、`VERIFIED` だけを実行の成功の証明にしない。command ごとの exit と出力は `article-reproduction` で照合する。
- D2、TALA、ELK、TLC、Apalache などの backend はこの package に含まれない。

## 形式検証

`statechart` の原版が使う `TLA2TOOLS` と `JAVA` は、この repo の `statechart` devShell が実行時にだけ渡す。TLA+ の model の directory で次を実行する。`statechart_script` には、読んだ原版 skill に同梱の `scripts/statechart` の絶対 path を指定する。

```sh
nix develop "$HOME/environment/dotfiles-wsl#statechart" --command "$statechart_script" model.tla
```

SVG が必要なら、同じ devShell で `node --input-type=module` を実行し、`const { render } = await import(process.env.PELE_MODULE)` で Pele を読み込んで `render(source, options).svg` を得る。

## .NET の実行時診断

`toolchain/package/dotnet-diagnostics.nix` が Microsoft 公式の診断 CLI を三つ入れる。各 CLI は専用の .NET runtime で動き、project の `dotnet` や SDK の選択を変えない。

| 調べたいこと | CLI |
|---|---|
| CPU 使用率、GC、例外率の変化 | `dotnet-counters monitor` |
| 遅い処理の時間経過と内訳 | `dotnet-trace collect`（EventPipe の trace） |
| hang 中に各 thread が待っている場所 | `dotnet-stack report` |

- 採取を許された local の process に限り、対象と同じ user と `TMPDIR` で PID を指定して接続する。
- trace、metric、stack には内部情報が含まれ得る。保存するなら作業木の外に自分だけが読める directory（`0700`）を作り、`umask 077` で書く。trace は `--output` で保存先を明示し、生データを commit や共有の log に残さない。
- MSBuild の失敗や build の遅さは `msbuild` skill の手順で切り分ける。既存の `.binlog` の記録値、埋め込み source、import は Binlog MCP（server `binlog`）に絶対 path を渡して調べる。概要は `binlog_overview`、source は `binlog_search_files` と `binlog_files`、import は `binlog_imports` から辿る。log の解析に成功したことと、記録された build が成功したことを分けて返す。

## Aspire Dashboard

開発中に再現できる問題を、OpenTelemetry の log、trace、metric で調べるときだけ使う。常駐はせず、必要なときに前景で起動する。`toolchain/package/aspire-cli.nix` が Aspire 17.0.0 を固定し、`aspire-dashboard` が起動、資格情報、一時データを管理する。telemetry と更新確認は既定で止めている。

| command | 用途 |
|---|---|
| `aspire-dashboard run [--browser-token-stdin]` | 前景で起動する。Ctrl+C か `stop` で止めるとデータを消す |
| `aspire-dashboard status` | 受付可能なら 0、未起動なら 1、起動中なら 3 で終わる |
| `aspire-dashboard otel logs\|spans\|traces [option...]` | 公式の `aspire otel` で読む |
| `aspire-dashboard exec [--service NAME] -- COMMAND` | COMMAND の telemetry だけを Dashboard へ送る |
| `aspire-dashboard stop` | 別の端末から止め、削除の完了まで待つ |

- UI は `http://127.0.0.1:18888`、OTLP は gRPC が 18889、HTTP が 18890 で、loopback だけで受ける。lock で一つの instance に限る。
- `exec` と `otel` は受付可能になるまで拒否する。`run` の後は `status` が 0 になってから送信と読取を始める。background で `run` を起動した agent は、作業の終わりに止める。
- browser を使う場合は `--browser-token-stdin` の非表示 prompt に新しく作った 64 桁の16進乱数を入れ、`http://127.0.0.1:18888/login` に同じ値を入れる。値を引数や file に書かない。
- metric は Dashboard の UI の `Metrics` で見る。`aspire otel` は metric を読まない。OTLP を出さない app や、OTLP の設定を環境変数で上書きできない app は観測できない。

## Docker と test の container

- Testcontainers for .NET は Ryuk が後片付けする。Ryuk を無効にしない。
- testcontainers-rs は Ryuk を持たない。SIGINT と SIGTERM で止めた test の container は、crate の `watchdog` feature を有効にすれば消える（0.28.0 は container を一つずつ止めるため、test runner の猶予を超えると止まったまま残ることがある）。SIGKILL、abort、`static` に置いた container、起動の失敗では残る。`dotfiles-doctor` が 6 時間より古いものを示すので、示された command で消す。
- BuildKit の cache は、daemon の GC 設定（`workstation/docker/module.nix`）が上限まで回収する。停止した container と volume は自動では消さない。project のデータを含み得るためである。
