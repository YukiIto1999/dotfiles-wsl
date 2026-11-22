# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールとserviceの正本、現在値の取り方、実行入口の制約を示す。
現在値のrosterは評価結果から取り、外部CLIでは固定sourceと実行互換性に必要な版を記す。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`workstation/module.nix`](../../workstation/module.nix)と各ownerの`environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| 汎用ツール | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages`。devenvは[`flake.nix`](../../flake.nix)で固定した公式release inputから選ぶ | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`workstation/home/module.nix`](../../workstation/home/module.nix)の`programs`。Atuinは同期なしのローカル履歴 | 同じunitを参照する |
| language server | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.lspRegistry`が登録を、profileの`dotfiles.toolchain.enabledLsp`が採用を持つ。PATHとclient設定へ配るのは採用した`dotfiles.toolchain.lsp`だけ | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.toolchain.lsp --apply builtins.attrNames` |
| 保守用devShell | [`flake.nix`](../../flake.nix)の`devShells` | `nix develop --command echo`の後に`$PATH`を確認する |
| projectのdevShellへの入口とOrcaへ貼る値 | [`toolchain/execution/`](../../toolchain/execution)の`dotfiles-project-run`と[`agents/orca/module.nix`](../../agents/orca/module.nix)の`dotfiles-orca-config`。手順は[Orcaからのclient起動](../operations/orca-launch.md) | `dotfiles-orca-config` |

`nixfmt`はeditorと単一file、`nixfmt-tree`は`nix fmt`とrepository全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 外部CLI

汎用CLIの採用は[`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages`が所有し、Capabilityの実装であるCLIは各Capabilityのruntimeが所有する。
決定的な操作はCLIを直接使い、候補や証拠の意味判断が必要な場合だけ該当Skillを使うため、一commandのための新しいSkillは置かない。
以下はsourceの構成と利用契約であり、この文書を更新しただけで配備や全用途の実行を確認したことにはならない。

### CIと秘密情報の検査

GitHub Actionsの構文・式は`actionlint`、workflowとローカルactionの安全性は`zizmor --offline .`で調べる。構文検査だけでは権限やcredentialの扱いを判定できない。
コミット前の既存hookは維持する。ステージ済み差分を追加で調べるときは`betterleaks git --staged --validation=false --redact .`で対象を限定する。履歴を調べる場合は調査範囲を別途指定する。
検出値は出力に残さず、credentialをネットワークへ送る検証は有効にしない。
履歴全体の走査、ネットワークを利用するcredential検証、リリースのSBOM・脆弱性検査・署名は共通hookへ追加しない。

### LinuxプロセスとNixの診断

実行を許可された子プロセスのみを対象に、syscallは`strace`、CPUの内訳は`perf`、停止位置とスレッドは`gdb`を使う。`hyperfine`はCLIやビルドの所要時間を反復比較する道具であり、関数やsyscallごとの観測とは分ける。カーネルの制限で計測できない場合は、共通のsysctlを下げずに不足を報告する。

| 調べたいこと | 入口 |
|---|---|
| 評価された設定 | `nix eval` |
| ファイルを提供するパッケージ | `nix-locate`。固定したstable-small索引を用いるため、無結果を不存在とみなさない |
| 世代のパッケージ差分・含まれる理由・derivationの差分 | `nvd diff`、`nix why-depends`、`nix-diff`を順に使い分ける |
| 保存済みビルドログ | `nix log` |

Nixの編集支援は`nixd`、整形は`nixfmt`、静的検査は`statix`と`deadnix`を使う。複数言語で整形の入口を揃えるプロジェクトは`treefmt`でformatterを束ね、lintは混ぜない。

### Windowsの独立した操作画面

通常のWeb操作は端末の入力を奪わないブラウザ経路を使う。Windowsアプリの実画面が必要で利用者の入力と分ける場合は[Anode](https://github.com/skulitom/Anode/tree/v0.11.4)のWindows子セッションを使う。同じ利用者のファイルとネットワークを共有するため、セキュリティ sandbox にはしない。

`nix build --no-link --print-out-paths .#anode-windows`で固定した公式配布物を取得できる。`share/anode/`のアーカイブ・チェックサム・上流インストーラをWindowsの一時ディレクトリにコピーしてから、`install.ps1 -PackagePath <zip> -ChecksumPath <SHA256SUMS> -Client None -NoPath`で利用者の`LocalAppData`に導入する。インストーラはWSLのUNCパスからzipを展開できない。Nixの切替はWindowsへの書込み、RDPの変更、seatの起動を行わない。

`anode doctor --json`がreadyなら`setup`を省く。必要な場合は、RDPとWindows子セッションを有効化し、既存接続を切断し得るため実行前に影響と承認を確認する。
`anode start --hidden --no-background-rendering`でseatを始め、WSLの`anode` CLIで操作する。複数セッションで使う場合はseatのleaseで順番を決める。WSL経由のMCP初期化は成功を確認できていないため、共有Gatewayには登録しない。

### Semgrep

[`toolchain/package/semgrep.nix`](../../toolchain/package/semgrep.nix)がSemgrep `1.180.0`のCLI sourceと同版のpublished wheelから取得するcoreを固定し、nixpkgs全体を更新せずNixOS用に組み立てる。
既存のCLI入口は変えず、package wrapperが上流の環境変数`SEMGREP_SEND_METRICS=off`と`SEMGREP_ENABLE_VERSION_CHECK=0`を既定値にして、metrics送信とversion照会を無効にする。
明示した環境変数は既定値を上書きし、CLI optionの解釈は上流実装に従う。
remote ruleの取得を含む通信を遮断する仕組みではない。
この版ではQL ruleが廃止され、binary targetは既定で走査対象から外れるため、その用途をCLI更新の互換性に含めない。

### Explainer

raw sourceは[`explainerSkills`](../../flake.nix)の[`578defba7249fde5366689424ed6017f76b5598b`](https://github.com/mizchi/explainer/tree/578defba7249fde5366689424ed6017f76b5598b)であり、registryは`skills/explainer`、`skills/explainer-book`、`skills/first-reader`を直接参照する。
runtimeの正本は[`package.nix`](../../toolchain/package/explainer/package.nix)、[`package.json`](../../toolchain/package/explainer/package.json)、[`package-lock.json`](../../toolchain/package/explainer/package-lock.json)である。
upstream scriptは変更せず、runtime用manifestとlockだけを置き換え、Node 24、Playwright `1.61.1`に対応するChrome headless shell `149.0.7827.55`、`@mizchi/vlmkit` `0.22.0`を固定する。
これは既存のbrowser MCPのpageやsessionへ接続する経路ではなく、CLI自身が使うbrowser runtimeである。

| 入口 | 第1引数 | upstream script |
|---|---|---|
| `explainer-build-html` | Markdown fileの絶対path。複数ページは後続引数へ渡す | `skills/explainer/scripts/build-html.mjs` |
| `explainer-verify-doc` | 文書directoryの絶対path | `skills/explainer/scripts/verify-doc.mjs` |
| `explainer-verify-book` | book directoryの絶対path | `skills/explainer-book/scripts/verify-book.mjs` |
| `explainer-figure-check` | 図fileの絶対path | `skills/explainer/scripts/figure-check.mjs` |
| `explainer-vlmkit` | 原版CLIのsubcommand | `node_modules/@mizchi/vlmkit/dist/vlmkit.mjs` |

最初の四wrapperは相対pathをexit 2で拒否し、呼出しごとに`${TMPDIR:-/tmp}/explainer-runtime.XXXXXX`へ書込み可能なCWDを作って、管理下の`package.json`と`node_modules`だけをsymlinkする。
生成されたreportは出力に示された一時directoryのpathから取得し、必要な証拠を保持した後の回収はsession lifecycleまたは実行ownerが行う。
wrapper自身が終了直後にreportを削除するとは扱わない。

[`verify-doc.mjs`](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/explainer/scripts/verify-doc.mjs#L31-L46)は文書directoryから最も近い祖先の`package.json`を探し、見つからない場合だけCWDをdependency rootにする。
管理runtimeを使う文書は、projectのpackage内やその配下ではなく、祖先にprojectの`package.json`がなく、project依存を要求しない専用のstandalone directoryへ置く。
wrapperのCWD変更や`NODE_PATH`だけでは、祖先packageが選ばれる挙動を上書きしない。
記事と`checks.json`を先に読み、任意shellと書込み、外部通信を許可範囲へ照合し、standalone directoryを安全なsandboxとは呼ばない。
図とHTMLは出力を開いて読んだ範囲を証拠にし、checkerの合格だけで実画面受入やa11y全適合としない。

[`checks`のloop](https://github.com/mizchi/explainer/blob/578defba7249fde5366689424ed6017f76b5598b/skills/explainer/scripts/verify-doc.mjs#L46-L75)はsubprocessのexitを捨て、stdoutとstderrを結合した出力を照合する。
既知の非zero subprocessでも`VERIFIED`になるため、wrapperのexit 0と`VERIFIED`だけを実行成功の証明にせず、custom `article-reproduction`がcommandごとのexit、個別stream、到達stateを記事の期待と照合する。
optional D2、TALA、ELK、TLC、Apalacheなどのbackendはこのpackageで供給せず、実行に必要なら別の許可済み前提として扱う。
`first-reader`はraw source内のPython 3 stdlib scriptを使い、模擬readerやrecall-from-logを実command再現や実際の翌日の人間の記憶測定へ置き換えない。

### .NETの実行時診断

[`dotnet-diagnostics.nix`](../../toolchain/package/dotnet-diagnostics.nix)はMicrosoft公式の診断CLIを3本だけ供給する。各CLIは専用の.NETランタイムで動き、プロジェクトの`dotnet`、SDKの選択や`PATH`を変えない。

| 調べたいこと | CLI |
|---|---|
| CPU使用率・GC・例外率の変化 | [`dotnet-counters monitor`](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-counters#dotnet-counters-monitor) |
| 遅い処理の時間経過と内訳 | [`dotnet-trace collect`](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-trace#dotnet-trace-collect)でEventPipeトレースを採取 |
| ハング中に各スレッドがどこで待っているか | [`dotnet-stack report`](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-stack#dotnet-stack-report)でマネージドスタックを表示 |

採取を許可されたローカルプロセスに限り、対象と同じユーザー・`TMPDIR`で、PIDを指定して接続する。
Linuxの[既定診断socket](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/diagnostic-port#default-diagnostic-port)にはpath長の上限があり、管理セッションが割り当てる長い`TMPDIR`では接続できないことがある。
その場合は、再起動してよい検証用プロセスに限り、`mktemp -d "$XDG_RUNTIME_DIR/dn.XXXXXX"`で作った短い私有directoryを、その起動commandと診断commandの`TMPDIR`にだけ指定する。
既存のプロセス、セッション全体の環境変数、明示されたprojectの設定は変えない。
トレース、メトリクス、スタックには内部情報が含まれ得る。保存する場合は作業ツリー外に自分だけがアクセスできるディレクトリ（`0700`）を作り、`umask 077`で新規ファイルへ出力する。トレースには`--output`で保存先を明示し、生データはコミットや共有ログに残さない。

MSBuildの失敗やビルド時間を調べるときは実行時診断と分ける。
[Microsoft Binlog MCP](https://devblogs.microsoft.com/dotnet/msbuild-binlog-mcp-server/)は、利用を許可されたローカルの`.binlog`を通常セッションから解析する。
`msbuild`の手順を入口とし、コマンド実行の終了値とbinlogに記録された結果は区別する。
このfrontには外部接続を許可せず、テレメトリを無効にする。

### Aspire Dashboard

開発中に再現できる問題を、OpenTelemetryのログ・trace・metricで調べるときだけ使う。本番監視や、起動前に起きた障害の遡及調査には使わない。
常駐service、AppHost、containerは持たず、複数のprojectで一つのDashboardを共有する。

[`aspire-cli.nix`](../../toolchain/package/aspire-cli.nix)は、[Aspire `17.0.0`](https://github.com/microsoft/aspire/releases/tag/v17.0.0)の公式release archiveを公開されたsha512で固定し、[上流のNixパッケージ](https://github.com/microsoft/aspire/blob/v17.0.0/eng/nix/package.nix)と同じ手順で`aspire`を組み立てる。
上流flakeのmanifestはreleaseより古い版を指すため、flake inputにはしない。
Dashboard本体はCLIに埋め込まれたbundleで、初回の`dashboard run`が`ASPIRE_HOME`（既定`~/.aspire`）へ展開する。実行時にダウンロードはしない。
展開された実行ファイルはNixOSのnix-ldで動く。
package wrapperは`ASPIRE_CLI_TELEMETRY_OPTOUT`と`ASPIRE_DASHBOARD_TELEMETRY_OPTOUT`を`true`、`features__updateNotificationsEnabled`を`false`の既定値にし、Microsoftへの利用telemetryとNuGetへの更新確認を止める。明示した環境変数はこの既定値を上書きする。

[`aspire-dashboard`](../../toolchain/package/aspire-dashboard.sh)が起動、資格情報、一時データを管理する。

| command | 用途 |
|---|---|
| `aspire-dashboard run [--browser-token-stdin]` | 前景で起動する。Ctrl+Cまたは`stop`で止めるとデータを削除する |
| `aspire-dashboard status` | 今回の起動のbrowser tokenをDashboard自身が受理すれば0、未起動なら1、起動中なら3で終わる |
| `aspire-dashboard otel logs\|spans\|traces [option...]` | 公式の[`aspire otel`](https://aspire.dev/reference/cli/commands/aspire-otel/)で読む。`--format Json`などはそのまま渡す |
| `aspire-dashboard exec [--service NAME] -- COMMAND` | COMMANDのtelemetryだけをDashboardへ送る |
| `aspire-dashboard stop` | 別の端末やセッションから止め、削除の完了まで待つ |

UIは`http://127.0.0.1:18888`、OTLPはgRPCが`18889`、HTTPが`18890`で、いずれもloopbackだけで受ける。任意で有効にできるAI CLIの[telemetry collector](../../telemetry/module.nix)のport `4317`と`4318`とは分ける。
lockで一つのinstanceに限り、二重に起動すると失敗する。
`exec`と`otel`は受付可能になるまで拒否するため、`run`を起動した後は`status`が0になってから送信と読取を始める。エージェントが`run`をbackground jobで起動した場合は、作業の終了時にそのjobか`stop`で止める。

既定では起動のたびにbrowser tokenとOTLP API keyを生成する。いずれも通常のファイルに書かず、起動したCLIとDashboardの環境変数で渡す。telemetry API keyは公式CLIが生成する。
他のsubcommandは、記録したpidの環境に今回のrun IDがあることを確かめてから、同じuserだけが読める`/proc/<pid>/environ`から値を取り出す。引数や端末出力には出さない。
匿名accessは使わない。
`status`はbrowser tokenを`/api/telemetry/validateToken`へ標準入力から送り、200だけを受付とみなす。返されたAPI keyは捨てる。
`otel`は公式CLIの[login URLを渡す方式](https://aspire.dev/reference/cli/commands/aspire-otel/)を使い、CLIがtokenをAPI keyへ交換する。URLはLinuxの匿名メモリファイルを通して渡し、CLIが複数回読み直しても引数やディスクには残らない。
CLIはlogと表示でURLのqueryを消すため、`otel`のlogは既定の`ASPIRE_HOME`の下に残る。
wrapperが強制終了してもCLIはparent death signalで止まり、残った一時directoryは次の`run`か`stop`が消す。

保存は`--persistence None`の一時SQLiteで、起動ごとの`${TMPDIR:-/tmp}/aspire-dashboard.*`に置き、停止時にdirectoryごと削除する。CLIとDashboardのlogも同じdirectoryに置く。
ASP.NET Coreのrequest logはlogin URLのqueryを記録するため、Dashboardの`Microsoft.AspNetCore`のlog levelをWarningに絞る。個々のrequestの記録はこのlogに残らない。
保持数の上限はログ10,000件、trace 10,000件、metricは次元ごとに10,000点とし、属性値は8,192文字、span eventは128件で切り詰める。

ブラウザを使う場合は、`aspire-dashboard run --browser-token-stdin`の非表示プロンプトに、新しく生成した64桁の16進乱数を入力する。`http://127.0.0.1:18888/login`へ同じ値を入力する。値をコマンド引数や保存ファイルへ書かない。ブラウザが不要なら既定の`run`と`otel`で読み取れる。

`exec`は`OTEL_EXPORTER_OTLP_ENDPOINT`、`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`、API keyを含む`OTEL_EXPORTER_OTLP_HEADERS`を設定し、信号別の`OTEL_EXPORTER_OTLP_*_ENDPOINT`・`_HEADERS`・`_PROTOCOL`を外す。
`service.name`は`--service`、既存の`OTEL_SERVICE_NAME`、Gitのtop-level directory名の順で決める。
`OTEL_RESOURCE_ATTRIBUTES`に無い場合だけ、`service.namespace`にproject名、`service.instance.id`に起動ごとの乱数を足す。
OTLPを出力しないアプリや、OTLP設定を環境変数で上書きできないアプリはこの経路で観測できない。


## 運用command

利用者向けの入口は`dotfiles-`prefixを持つ生成commandである。[`platform/cli/module.nix`](../../platform/cli/module.nix)は`dotfiles.platform.cli.commands` optionとsystem package登録を持ち、各owner moduleは[`platform/cli/impl/mk-command.nix`](../../platform/cli/impl/mk-command.nix)を明示的にimportする。`packages`にないhost固有commandをcheckoutから呼ぶときは、対象hostの`nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.<name>`を直接指定する。

containerを有効にしたhostのimage同期は次のpathで実行する。

```bash
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages
```

現在の一覧は`nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.cli.commands --apply builtins.attrNames`で確認する。

管理runtimeの`dotfiles-agent-verify`は`cli.commands`に無く、flakeの`packages`から公開する。まだ配備されていないcheckoutからは`nix run --no-write-lock-file .#dotfiles-agent-verify -- nix run --no-write-lock-file .#verify`でT1を通す。
T1の時間予算は呼び出し側の引数でなく、rootの`tiergate.json`の`verify.seconds`が決める。同じ段の`feedbackTargetSeconds`が持つ目標は、wrapperが超過を報告するだけで、取消にも成否にも使わない。
wrapperは[`dotfiles-verify-entry --snapshot verify`](../../toolchain/verification/impl/entry.sh)で静的な宣言を一度だけ読み、そのsnapshotを`--policy FILE`へ渡して予算と入口を解決する。
snapshotの読取から検査と証跡の確定までを同じ走行の予算に含め、途中の登録変更でcanonicalな呼び出しを無期限のcacheへ切り替えない。
`verify`のappも同じ設定fileから予算を読む。
Nixの入口の有無は同じfileの`frontend: "nix"`と`entries`から解決し、解決時にNixを取得、評価しない。
登録や予算が読めない場合は、登録済みの入口を実行せずに拒否し、追跡済みfileの欠落を入口なしとして通さない。
wrapperは`--candidates`で入口の綴りと局所commandを区別し、後者だけを証跡なしでcacheへ通す。

## Agent、Skill、Capability

[`profiles/workstation.nix`](../../profiles/workstation.nix)が共有するAgent client、Capability、language server、identityを選び、`profiles/hosts/<host-id>.nix`がhost固有の値と選択を持つ。
Skill、provider、backendはCapabilityから導出し、profileに直接列挙しない。

| 区分 | 正本 | 現在の値 |
|---|---|---|
| Agent adapter | [`agents/clients/`](../../agents/clients)が`dotfiles.agents.registry`へ登録し、`enabled`から採用済み`clients`を導く | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply builtins.attrNames` |
| Client supply | 各clientの`supply.package`と[`agents/impl/agent-supply.sh`](../../agents/impl/agent-supply.sh)。baselineは[`flake.lock`](../../flake.lock)の`llm-agents` | `nix run .#dotfiles-agent-supply -- manifest`、`dotfiles-agent-supply status` |
| Agent runtime | [`agents/module.nix`](../../agents/module.nix)、[`agents/impl/runtime/`](../../agents/impl/runtime) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.runtime` |
| 静的subagent | `agents/subagents/` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.file --apply 'f: builtins.filter (n: builtins.match "\\.claude/agents/.*" n != null) (builtins.attrNames f)'` |
| local Skill | [`skills/`](../../skills) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled` |
| Capability | [`capabilities/`](../../capabilities)の`dotfiles.capabilities.registry`とprofileの選択 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.resolved` |
| plugin Skill | [`flake.nix`](../../flake.nix)のplugin inputと[`flake.lock`](../../flake.lock) | clientごとの生成設定を参照する |

専門判断の導線は`Agent -> Skill`、配備するproviderの導線は`Capability -> provider/runtime`であり、harness primitiveとmanaged CLIは直接使う。
Skill-firstはtask routingの規則であり、providerをSkill配下へ置くという意味ではない。

## Runtime observation

| 区分 | 正本 | 現在の値 |
|---|---|---|
| observationの型 | [`health/module.nix`](../../health/module.nix)のclosed union | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply 'xs: builtins.mapAttrs (_: x: x.kind) xs'` |
| 検査対象と値 | 各ownerが`dotfiles.health.observations`へ登録 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply builtins.attrNames` |
| 汎用runner | [`health/module.nix`](../../health/module.nix)、[`health/impl/doctor.sh`](../../health/impl/doctor.sh)、[`health/impl/probe.sh`](../../health/impl/probe.sh) | `dotfiles-doctor --json` |
| MCP protocol | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)とそのobserver | registryの`mcp/protocol/<gateway-id>` |

owner moduleは意味と観測値を持ち、`health`は型、実行、集約だけを持つ。対象を増減するときにdoctor独自のinventoryは更新しない。

## MCPとcontainer

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)の`dotfiles.platform.mcp.gateway` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.gateway --apply 'g: builtins.removeAttrs g [ "source" ]'` |
| MCP target | Capability実装が登録する`dotfiles.platform.mcp.targets` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`platform/containers/module.nix`](../../platform/containers/module.nix)のcontractと各Capability実装 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.containers.services --apply builtins.attrNames` |
| MCP front | [`platform/mcp/module.nix`](../../platform/mcp/module.nix)がtargetから導く`dotfiles.platform.mcp.fronts` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.fronts`。稼働は`systemctl status mcp-front-<name>` |
| telemetry | [`telemetry/module.nix`](../../telemetry/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.telemetry` |

MCP targetはprovider、executable、transport、lifecycle、公開範囲、起動方式、port、backend unit、probeを持つ。
generic Platformはprovider IDとapplication IDを列挙せず、Capability実装から登録値を受ける。
一つのGatewayが通常経路とセッション向けの追加経路を提供するが、front serviceの起動依存は持たない。
credential、container、host processの境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に`dotfiles-doctor`で宣言と実状態の収束を確認する。

### 通常の利用と書込用セッション

Playwright、Chrome DevTools、MemLab、Context7、Microsoft Learn、DeepWiki、Binlog MCPは通常の`/mcp`に含まれる。操作・診断・資料調査を使い分ける入口は各Skillであり、専用の再起動は必要ない。

通常のGitHub起票、PR作成、更新、コメント、レビューは現在のセッションで`dotfiles-github-write`を使う。[GitHub操作の手順](../../skills/github-operations/skill/SKILL.md)に従い、事前読取で確定したアカウントIDと実行loginを対応させる。
共有HTTPは読取専用のまま。merge・削除・履歴変更と、共通commandが持たない操作だけは、利用者の端末から`dotfiles-tool-session list`で対象を選び、OMPまたはCodexで`dotfiles-tool-session <client> github-write-<account> --`を起動する。そのうち不可逆な変更には実行直前の確認が必要である。
