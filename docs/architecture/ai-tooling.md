# AI tooling

**読み手:** Agent、Skill、Capability、provider、runtimeの境界を変更する人。

AI CLIのbinary、共通資材、Capability実装、MCP接続は別のlifecycleを持つ。upstream installerとGitHub releaseで入れるbinaryは`~/.local/bin`の可変物である。policy、Skill、subagent、managed config、MCP serviceはNixOS generationが宣言する。

## 配備と呼出し

```text
agents/policy/AGENTS.md ───────────────────┐
agents/subagents/*.md ── client変換 ──────────┤
skills/*/skill/ ──────────────────────────┼─► Nix store ─► 各clientの設定領域
flake inputのplugin Skill ─────────────────┘

Agent ─► Skill ─► Capability ─► provider adapter ─► Platform MCP ─► gateway
                         └────► backend / credential / persistent state

AI CLI ─► LSP ─► language server
       └► OTLP ─► telemetry collector
```

[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)はsubagentからSkillへのroutingとsubagent間handoffだけを持つ。provider名、backend名、直接provider例外は置かない。Skillの依存は各[`skills/NAME/module.nix`](../../skills)が`requiresSkills`と`requiresCapabilities`で宣言する。

実行時の原則は`Agent → Skill → Capability → provider/runtime`である。Agentはtask、権限、委譲、成果物handoffを所有する。Skillは反復する判断、手順、停止条件を所有する。Capabilityはconsumerに依存しない機能contractである。provider adapter、container、database、credential、stateはCapabilityの実装詳細であり、AgentやSkillへ逆依存しない。

Read、Grep、Glob、Edit、Write、Bash、LSP、subagentのようなharness機能はAgentが直接使う。repositoryに配備するproviderは次のCapabilityを通す。

Capability実装の正本は各`capabilities/<id>/module.nix`にある。Task入口の正本は各[`skills/<id>/module.nix`](../../skills)にある`requiresCapabilities`であり、Skill配備をゲートし、policyのCapability対応へ記載する。現在のCapability IDは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.registry --apply builtins.attrNames
```

各Skillが宣言するCapabilityは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.registry --apply 'builtins.mapAttrs (_: skill: skill.requiresCapabilities)'
```

Skill-firstはrouting規則であり、MCPやcontainerをSkill directoryへ置く規則ではない。選択したSkill本文はclientへ配備する一方、Capability実装はtransport、service lifecycle、network、credential、永続dataを所有するため、`capabilities/`に置く。

## Profileとregistry

[`profiles/workstation.nix`](../../profiles/workstation.nix)は全host共通のAgent client、Capability、language server、identityを選び、[`profiles/hosts/`](../../profiles/hosts)はhost固有のCapabilityをsemantic IDで加える。MCP providerやcontainer backendはprofileへ直接列挙しない。

各client adapterは`dotfiles.agents.registry`へ登録し、profileの`enabled`から採用済みの`clients`を導く。
配備、installer、runtime wrapper、health、policyの能力表は採用集合だけを読む。

[`skills/module.nix`](../../skills/module.nix)はSkill ID、Skill依存、hard Capability依存から、選択したCapabilityで実行できるSkillを導く。[`capabilities/module.nix`](../../capabilities/module.nix)はCapability依存closure、provider owner、backend ownerを検証し、`dotfiles.capabilities.resolved`、`dotfiles.platform.mcp.enabledProviders`、`dotfiles.platform.containers.enabled`を導く。現在のconsumer数はownershipの判断に使わない。

Agent clientへ配るのは、解決したSkill registryの`source` directoryとその本文、reference、scriptである。
必要なSkillを失ったsubagentとそのhandoffも配備しない。
Nix module、依存metadata、fixtureは配備先へ混ぜず、同じIDのsource差替えはNixの明示的なoverrideだけで行う。

## Client binary

client contractはupstream installerとGitHub releaseの二経路を持つ。
`dotfiles-install-agents`は採用したclientを更新し、一つの失敗で他のclientを止めず、失敗したclient名を集約して非ゼロで終える。
日次更新は`dotfiles.agents.automaticUpdates.clients`で採用集合の部分集合を選び、空ならtimerも配備しない。

client ごとの install contract は各[`agents/clients/NAME/module.nix`](../../agents/clients)が所有する。release asset、architecture 別 entrypoint、`requiredPaths`、`retainedReleases` もそこに置く。

GitHub release経路はGitHub APIのSHA-256 digestと取得したassetを照合する。`assetFormat`が`tar.gz`のときはmember名、type、件数、論理size、重複、path衝突を展開前に検査する。`raw`のときはassetが単一の実行fileそのものなので、path成分を持たないentrypointとして配置し、以降は同じ検査へ渡す。展開後はowner、mode、link、entrypoint、required path、version probeを通したtreeだけを公開する。`raw`は`single-binary` layout以外と組み合わせられない。

管理releaseは`~/.local/share/dotfiles/agents/<client>/releases/sha256-<digest>`に置く。`current`は同じclient root内の相対symlink、`~/.local/bin/<binary>`は`current`内のentrypointを指す相対symlinkである。lockと固定したdirectory descriptorの下でidentityを照合し、所有を確認できないobjectは削除しない。

Claude Code、Codex、OMP、OpenCodeは、Home Managerが`~/.local/bin`より前へ置く共通runtime wrapperから起動する。wrapperはinstallerが管理する`~/.local/bin`のbinaryを絶対pathで実行する。Antigravityは同じCLI起動境界を持たない。

runtimeはsession ID、sessionを始めたproject、owner process、boot ID、管理下`TMPDIR`を記録し、clientを`agents.slice`のscopeで起動する（[資源の上限](#資源の上限)）。projectはGit repositoryではgit common directory、それ以外では作業directoryから決めるので、linked worktreeは元のcheckoutと同じprojectになる。session中に`git worktree add`で作られたworktreeは、runtimeのgit shimがpathと作成時のHEADをsession directoryへ記録する。runtimeは終了時に、HEADが作成時のままのworktreeだけを`git worktree remove`へ渡す。`git worktree remove`は変更、untracked file、lockを持つworktreeを拒むので、それらとsessionの外で作られたworktreeは残る。削除の失敗はclientの終了statusを変えない。同時に走った別の`git worktree add`と区別できないworktreeは記録せず、SIGKILLで終わったsessionのworktreeは回収しない。

`CARGO_HOME`と`XDG_CACHE_HOME`が未設定なら共有cacheを使い、利用者が明示した値は空文字列も含めて変えない。Cargoの中間成果物は`CARGO_BUILD_BUILD_DIR`で全sessionが共有する一つのrootの下に置き、`{workspace-path-hash}`でcheckoutごとに分けるので、どのsessionからbuildしても同じcheckoutは同じbuild-dirを使う。最終成果物は各checkoutの`target`に残る。同じworkspaceのcheckoutどうしで中間成果物を共有すると、Cargoが別checkoutのbuildをfreshと判定するため、linked worktreeとも共有しない。利用者が明示した`CARGO_TARGET_DIR`と`CARGO_BUILD_BUILD_DIR`、project固有のCargo`target-dir`と`build-dir`は上書きしない。一時的な写しでbuildするtoolは、写しごとに中間成果物がbuild-dirのrootへ残るため、`CARGO_BUILD_BUILD_DIR`を外して起動する。

`dotfiles-agent-verify`はHEAD、tracked diff、non-ignored untracked content、command、環境からfingerprintを作り、同一fingerprintの成功だけを再利用する。

## 資源の上限

wrapperから起動したclientは、launcherが`systemd-run --user --scope`で作るsession単位のscopeの中で動き、そのscopeはsystemd userの`agents.slice`に属する。scope名は`dotfiles-agent-<client>.<pid>.<suffix>.scope`で、session directoryの名前から導く。clientが起動したbuild、test、browser、VMもscopeに入るため、slice全体で次の上限を共有する。値は`dotfiles.agents.slice`のoptionで変えられる。

上限は物理RAMの割合で指定し、systemdが起動時のmemory容量から解決する。
`agents.slice`の`MemoryHigh`は60%、`MemoryMax`は70%、`MemorySwapMax`はRAMの20%を既定とし、CPUWeightは50にする。
swapの百分率はswap総量ではなく物理RAMに対する割合である。
値の正本は`dotfiles.agents.slice`であり、highよりmaxを大きくする。

Chromiumはuser busから`app.slice`へscopeを作るため、agent scopeから抜ける場合がある。
user manager全体にも`MemoryHigh` 67%、`MemoryMax` 75%を置き、agentとbrowserの合計を抑える。
user managerのmaxはagent sliceのmaxより大きくし、基盤とkernelへRAMを残す。
launcherはscopeを作れないとclientを起動せず、scope外のclientはdoctorの`agent/slice-placement`が報告する。

I/O上限やprojectの`CARGO_BUILD_JOBS`の上書きは加えず、memory上限でpage cacheとswapの圧迫を抑える。
agentが起動したNix builderはnix-daemonの子としてsystem.sliceで動くため、`agents.slice`の上限を受けない。
[`workstation/nix/module.nix`](../../workstation/nix/module.nix)がhostのjobs、cores、空き容量reserveを持ち、nix-daemonのCPUWeightを50にする。
Dockerが起こす宣言外のcontainerは[containerの配置と上限](#containerの配置と上限)で別に抑える。

## Policy、subagent、Skill

[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)は全clientへ配るpolicyの正本である。静的subagentは`agents/subagents/`に置く。Claude CodeとOMPはfrontmatter Markdown、OpenCodeはSkill toolを許可するfrontmatter Markdown、CodexはTOMLへbuild時に変換する。Antigravityは未対応を明示する。

`native`と`rendered`のsubagentはhome配下へ配備する。Codexの`declared` subagentはhomeへsymlinkせず、`config.toml`の`[agents.<subagent>]`からNix storeの実体を`config_file`で指す。Codexがsubagent fileを`O_NOFOLLOW`で開き、symlinkを拒否するためである。
OMPのhookは`~/.omp/agent/hooks/pre`をdirectoryごとhomeへ配備し、その中をNix storeの実fileにする。OMPはhook directory内のsymlinkを読み込まず、Home Managerがfileごとに張るsymlinkでは全hookが無視されるためである。
client別の能力配備の正本は各`agents/clients/<id>/module.nix`のmode宣言である。`projectMemoryMode`は`hooks`、`plugin`、`unsupported`のいずれかで、対応する配備先は`capabilityManagedFiles.projectMemory`が指すmanaged fileである。現在の各clientのmodeは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply 'builtins.mapAttrs (_: client: { inherit (client) subagentMode skillProjectionMode lspMode telemetryMode projectMemoryMode; })'
```

`projectMemoryMode`はclient固有の想起注入の入口を表すが、明示的な検索、検証、保存の判断を代替しない。

Claude CodeとCodexのuser configはclientが更新し得るため、Home Managerは配備先が存在しない場合だけseedを作る。seed は runtime drift の対象にしない。OMPの`config.yml`と`agent.db`もclient所有の可変fileとして残す。
OMPのseedはBash interceptorを有効にし、直接の再帰検索を専用検索手段へ誘導する。既存の`config.yml`はOMP自身の設定commandで移行する。

OMPのcompactionで利用者のmessageを要約と別に原文で残すのは、OpenAI ResponsesのV2 streaming compactionだけである。
それ以外の方法は直近の範囲より前を要約かarchiveだけで渡すため、要約が利用者の常設の指示を落とすと、agentは指示があったこと自体を知る手段を失う。
AGENTSにある、過去の利用者指示を会話の原文で確かめる規律も、存在を知らない指示には適用されない。
この欠落はupstreamのOMPで直す対象であり、seedの設定やpolicyの文では補わない。

## MCP Platform

各[`capabilities/`](../../capabilities)実装が`dotfiles.platform.mcp.targets`へprovider ID、executable、server transport、server lifecycle、port、通信要件、backend unit、probeを登録する。[`platform/mcp/module.nix`](../../platform/mcp/module.nix)はtargetからfrontを一度だけ導く。

`stdio`の`service` lifecycleは一つのstdio serverをfront serviceの寿命で共有する。`session` lifecycleはagentgatewayがdownstream sessionごとにstdio serverを生成する。`streamable-http`はproviderのforeground serverをfront serviceとして起動する。backendを持つtargetは`waitUnits`をfrontの`requires`と`after`へ設定する。

SearXNGのstdio providerはprocess単位でtool呼出しのrateと同時実行数を制限するため、共有frontに接続するsessionも同じ上限を使う。
呼出しrateは[`package.nix`](../../capabilities/web-discovery/searxng/mcp/package.nix)の`MCP_TOOL_RATE_MAX`で指定し、同時実行数は固定したupstream packageの既定値を使う。
HTTP専用のsession作成rateをstdioの呼出し制限として設定しない。

[`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)は単一endpointのID、port、URL、service、runtime directory、YAML source、target名を公開する。gatewayは全frontへloopback HTTPで接続するが、front serviceを起動依存に持たず、子processも作らない。各AI CLIが知る接続先はこのURLだけである。

browser automationとbrowser diagnosticsは異なる観測contractを持つが、[`capabilities/browser-runtime/chromium/module.nix`](../../capabilities/browser-runtime/chromium/module.nix)のChromium packageを共有する。tab、page、browser processはdownstream session間で共有しない。

現在のtarget名は次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames
```

## Container Platform

[`platform/containers/module.nix`](../../platform/containers/module.nix)は型付きservice contract、Docker daemon、`dotfiles-backends` network、OCI image inventory、image同期を所有する。[`platform/containers/impl/container-backend.nix`](../../platform/containers/impl/container-backend.nix)はCapability実装が使うpure builderである。

application固有のcontainer、endpoint、credential、volume、provisioningは対応するCapabilityが所有する。Hindsight、Crawl4AI、SearXNGをgeneric Platformへ列挙しない。

Capability実装はregistry metadataを常に宣言し、backend、MCP target、credential、永続data、health observation、client integrationを`dotfiles.capabilities.resolved`で条件化する。container backendが一件もなければ、Container PlatformはDocker daemon、共通network、image同期command、GC timerを配備しない。

全containerは暗黙pullを無効にする。upstream imageはdigest固定の宣言と、containerを有効にしたhostへ配備する`dotfiles-sync-images`が取得を担当し、Nix生成imageは`imageFile`が取得を担当する。
Docker build artifact GCは停止済みのtestcontainersのcontainer、dangling image、BuildKit cacheを扱い、tagged image、named volume、それ以外のcontainerは削除しない。

### containerの配置と上限

Docker daemonの`cgroup-parent`は`containers.slice`であり、`--cgroup-parent`を持たないcontainerはすべてこのsliceの`docker-<id>.scope`に入る。
agentのtestがtestcontainersで起こすcontainer、compose、手で起こしたcontainerがこれに当たる。
宣言済みbackendは[`container-backend.nix`](../../platform/containers/impl/container-backend.nix)が`--cgroup-parent=system.slice`を付けるので、基盤のserviceと同じsystem.sliceに残り、このsliceの上限を受けない。
[dockerd reference](https://docs.docker.com/reference/cli/dockerd/#default-cgroup-parent)によれば、containerごとの`--cgroup-parent`はdaemonの値より優先され、systemd driverではslice名がcgroup treeの位置を表すので、`containers.slice`はroot直下に作られる。
[systemd.slice(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html)によれば、sliceに置いた資源の上限はslice内の全unitのprocessに効く。
[Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)によれば、`memory.current`と`memory.swap.current`は子孫のcgroupを含めて数えられ、`memory.max`に達して回収できなければそのcgroupの中でOOM killerが動く。

宣言外のcontainerの上限は物理RAMの割合であり、`MemoryHigh` 7.5%、`MemoryMax` 10%、`MemorySwapMax` 10%、CPUWeight 50を使う。
user managerとcontainerの上限を分け、system.sliceの基盤とkernelにRAMを残す。
system managerのdockerdはuser managerへ委譲したsubtreeにscopeを作れないため、containerを`agents.slice`へ入れない。
testcontainersなどの呼出し元が個別の`--memory`を指定しない場合も、daemonのsliceで合計を抑える。

doctorの`container-placement`は、runningのcontainerごとにscopeのsliceをsystemdに問い合わせ、宣言済みbackendがsystem.slice、それ以外が`containers.slice`にいなければfailにする。

### 停止済みのtestcontainersの回収

Rust版のtestcontainersはRyukを持たず、containerの破棄をtestのprocessに任せる。
processがSIGKILLされるか、docker APIの要求がclientの期限を超えると、containerは所有者のないまま残る。
`docker-build-artifact-gc`は6時間ごとに、label `org.testcontainers.managed-by=testcontainers`を持ち、状態が`created`、`exited`、`dead`のいずれかで、作成から6時間を過ぎたcontainerを匿名volumeとともに削除する。
6時間はtimerの周期と同じ値で、作成からstartまでの途中にあるcontainerを消さないための下限である。
session単位で判定しないのは、`org.testcontainers.session-id`のlabelが`reusable-containers` featureを有効にしたときにしか付かないためである。
`running`のcontainerは所有者の生死を判定できないので削除せず、`containers.slice`の上限の内に置いたまま、作ったprojectの破棄処理で直す。
`docker rm`は`--force`なしではrunningのcontainerを拒むので、一覧を取った後にstartされたcontainerも削除されない。
回収は`docker image prune`より前に走り、削除したcontainerだけが参照していたtagのないimageを同じ実行で回収する。

## Project memory

現行のproject memory実装は[`capabilities/project-memory/hindsight/`](../../capabilities/project-memory/hindsight/)が所有する。`backend`はHindsight、`runtime`は`bin/dotfiles-memory`を含むpackage、`mcp`はmemory providerのfront、`client-integrations`は共通hook packageとOpenCode pluginをそれぞれ持つ。Capabilityが公開するgeneric optionは`dotfiles.capabilities.project-memory.runtime`と`dotfiles.capabilities.project-memory.clientIntegrations.{hooks,opencodePlugin}`であり、client moduleはprovider名やbackend pathを直接参照しない。

```text
Claude Code / Codex / OMP hooks ─┐
OpenCode recall plugin ──────────┤
agent memory harvest ────────────┼─► dotfiles-memory ─► 127.0.0.1:3111 Hindsight
                                 │                         │
AI CLI ─► gateway ─► memory MCP ┘                         └─► hindsight-data volume
```

memory MCPのendpointは`front`のport `8774`、Hindsight APIは`localhost:3111`である。MCPの入口は`memory_health`、`memory_recall`、`memory_save`、`memory_status`、`memory_verify`で、project/globalのscopeを明示する。healthはHindsightのdatabaseとmodel readinessだけを確認し、LLMが利用できることやretainが成功したことは証明しない。

project scopeのidentityは、`dotfiles-memory`が絶対cwdからGit common directoryを解決して導く。
同じrepositoryのlinked worktreeは共有し、basenameが同じ別repositoryは分離する。

Hindsightの原文書類はnamed volume `hindsight-data:/home/hindsight/.pg0`に保持する。宣言で固定したmultilingual embeddingとrerankerのmodel mountはNix storeからread-onlyで渡し、retain時のextraction inputはSOPSから展開したcredentialで設定する外部LLMへ送られる。

抽出modelは定額のOpenCode Goで呼べる`minimax-m3`であり、保存すべき内容の判断を抽出modelへ委ねない。
client連携はsession開始とprompt送信で想起結果を注入し、会話turnをHindsightへ保存しない。
保存は明示的な`memory_save`と、有効にした[記憶の収穫](#記憶の収穫)が行う。

OpenCodeのrecall結果は同じturnのmodel呼出しで共有し、次のpromptで置き換え、idleで破棄する。title生成などの補助呼出しで消費しない。hook実行には30秒、警告通知には1秒のabort期限を設定する。event loopやhostが停止している時間を含めた実時間の上限は保証しない。

既知のmemory/injection blockは決定的に除外するが、secretやPIIをすべて検出できる保証ではない。失敗時に別のmemory backendへfallbackしない。saveが`pending`または`indeterminate`なら保存済みと扱わず、返されたoperationとdocumentのIDを同じscopeの`memory_status`へ渡して確認する。`indeterminate`は送信後の通信断や期限切れで結果を確認できない状態で、runtimeはsaveを自動再送しない。

LLM処理は外部endpointを使う。API keyはSOPS templateからroot所有のruntime environment fileを経てcontainerへ渡し、client hookやMCP frontへは配らない。明示的な保存と記憶の収穫のretain入力が外部providerへ送られる信頼境界を持つ。

## 作業日誌

`dotfiles.agents.journal.enable`で明示的に採用したOMP hostだけに配備する。

[`agents/journal/`](../../agents/journal)は、omp の session 記録から日次の作業日誌を作る。project memory が判断を想起のために蓄えるのに対し、作業日誌は全 project の作業を日付順に読める記録として残す。入力は`~/.omp/agent/sessions/`直下の project ごとの session file で、親 session の隣に置かれる subagent の記録は親と内容が重なるため読まない。各 entry の時刻で 06:00 から翌日の 06:00 までを切り出し、利用者の指示、エージェントの応答、tool の名前と意図だけを model へ渡す。thinking、tool の結果、tool の引数は渡さない。project ごとの commit 一覧は Git から読む。

要約は omp の print mode で二段に行い、session ごとの要約を project ごとにまとめる。起動時は session file、rules、Skill、自動検出する extension、tool を読み込まない。project memory の hook は extension とは別に読み込まれることがあり、prompt ごとに cwd の Git common directory から決まる project の記憶を想起して注入する。このため要約は Git の work tree ではない一時 directory で実行し、一時 directory が work tree の中にあれば model を呼ばずにその日を失敗にする。この cwd では project が決まらず、記憶は model の入力に混ざらない。model は omp の`tiny`役割と同じ`opencode-go/deepseek-v4.1-flash`で、認証は omp が保持するものを使う。session の本文には secret や個人情報が混ざり得る。prompt は秘密に見えるものを書かないよう指示するが、検出を保証しない。日誌の repository への commit は全 repository 共通の Git hook を通るが、pre-commit hook が拒否するのは GitHub token の形だけである。

日誌の repository は`dotfiles.workstation.environmentDir`の下に置き、flake の入力にはしない。dotfiles が配備した timer が書き込む出力だからである。

## 記憶の収穫

`dotfiles.agents.memoryHarvest.enable`を明示的に採用し、OMPとproject-memoryが有効なhostだけに配備する。

[`agents/memory-harvest/`](../../agents/memory-harvest)は、omp の session 記録から利用者の訂正、決定、好みを取り出し、project memory へ保存する。session 記録の読み方と omp の呼び出しは作業日誌の package を読み込んで共有し、model も作業日誌と同じ定額の`opencode-go/deepseek-v4.1-flash`と thinking `low`を使う。作業の大半は omp で行うため、Claude Code、Codex、OpenCode の session 記録は読まない。

入力は`~/.omp/agent/sessions/`直下の session file のうち、前回成功した実行から今回の開始までの entry である。attribution が`user`の発言だけを読み、`<project_memory>`と`<system-reminder>`の block を除く。エージェントの応答、tool の結果、注入した文脈、subagent の記録は model へ渡さない。cwd から Git project を決められない session は読まずに報告する。

model には project ごとに、明示的に保存した記憶（`dotfiles-memory curated`）と利用者の発言を渡し、将来の別 session の判断を変える発言だけを候補にさせる。次の発言は候補にしない。今回の作業への依頼、計画、進捗の確認、質問、同意だけの返事、その場だけの許可や禁止、状況に依存する優先度や締切、人の名前を含むもの、利用者が標準、AGENTS、Skill、文書、hook、code へ入れるよう求めた規律、製品の仕様、現在の状態から分かること、保存済みの記憶と同じ内容、secret や個人情報を含むものである。正本に入るものを記憶に重ねないためである。

modelは候補ごとに、将来の別sessionで同じ判断を迫られる場面を一行で書き、書けない発言は候補にしない。
場面を保存する本文には含めず、保存済みのsourceと同じ発言はmodelへ渡さない。
保存済みの記憶と文字列が一致する候補も保存しない。

候補は一件ずつ`dotfiles-memory save`へ、scope `project`、session の cwd、kind、source `<session file>#<entry id>`で渡す。`pending`または`indeterminate`の receipt は保存済みと報告せず、state file に残して次の実行で`dotfiles-memory status`へ渡す。state file の読み終えた位置は、全 project の取り出しが成功した実行だけが進める。runtime が資格情報や個人情報に見える候補を拒んだ場合は、その候補だけを捨てて失敗にしない。発言は model の provider へ、保存した内容は Hindsight の抽出 model へ送られる。運用は[記憶の収穫](../operations/memory-harvest.md)に従う。

## LSPと観測

language serverのbinaryとrosterは`toolchain/`が所有し、client形式への写像は各[`agents/clients/`](../../agents/clients)のadapterが持つ。
Claude Codeはplugin、OMPは`lsp.json`、OpenCodeはconfigの`lsp` blockへ投影し、非採用または未対応clientには配らない。

managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。

telemetry collectorは対応するclientの採用時に有効となり、`dotfiles.telemetry.enable`で無効にできる。
OMP-onlyなどtelemetry未対応の採用集合では、collector、配備物、health観測を配備しない。
有効なcollectorはOTLPをloopbackで受け、生recordを残す。
CLIはendpointを`dotfiles.telemetry`から読み、portを重複して宣言しない。
