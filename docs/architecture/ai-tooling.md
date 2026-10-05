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

[`skills/module.nix`](../../skills/module.nix)はSkill ID、Skill依存、hard Capability依存から、選択したCapabilityで実行できるSkillを導く。[`capabilities/module.nix`](../../capabilities/module.nix)はCapability依存closure、provider owner、backend ownerを検証し、`dotfiles.capabilities.resolved`、`dotfiles.platform.mcp.enabledProviders`、`dotfiles.platform.containers.enabled`を導く。現在のconsumer数はownershipの判断に使わない。

Agent clientへ配るのは有効な`skills/<id>/skill/`だけである。必要なSkillを失ったsubagentとそのhandoffも配備しない。Nix module、依存metadata、fixtureは配備先へ混ぜない。plugin Skillも同じregistryへ入れ、同名IDを評価時に拒否する。

## Client binary

client contractはupstream installerとGitHub releaseの二経路を持つ。`dotfiles-install-agents`はClaude CodeとAntigravityのupstream installer、Codex、OpenCode、OMPのGitHub releaseを更新する。client単位の更新は互いに独立で、一つの失敗は他のclientを止めず、失敗したclient名を集約して非ゼロで終える。

client ごとの install contract は各[`agents/clients/NAME/module.nix`](../../agents/clients)が所有する。release asset、architecture 別 entrypoint、`requiredPaths`、`retainedReleases` もそこに置く。

GitHub release経路はGitHub APIのSHA-256 digestと取得したassetを照合する。`assetFormat`が`tar.gz`のときはmember名、type、件数、論理size、重複、path衝突を展開前に検査する。`raw`のときはassetが単一の実行fileそのものなので、path成分を持たないentrypointとして配置し、以降は同じ検査へ渡す。展開後はowner、mode、link、entrypoint、required path、version probeを通したtreeだけを公開する。`raw`は`single-binary` layout以外と組み合わせられない。

管理releaseは`~/.local/share/dotfiles/agents/<client>/releases/sha256-<digest>`に置く。`current`は同じclient root内の相対symlink、`~/.local/bin/<binary>`は`current`内のentrypointを指す相対symlinkである。lockと固定したdirectory descriptorの下でidentityを照合し、所有を確認できないobjectは削除しない。

Claude Code、Codex、OMP、OpenCodeは、Home Managerが`~/.local/bin`より前へ置く共通runtime wrapperから起動する。wrapperはinstallerが管理する`~/.local/bin`のbinaryを絶対pathで実行する。Antigravityは同じCLI起動境界を持たない。

runtimeはsession ID、sessionを始めたproject、owner process、boot ID、管理下`TMPDIR`を記録し、clientを`agents.slice`のscopeで起動する（[資源の上限](#資源の上限)）。projectはGit repositoryではgit common directory、それ以外では作業directoryから決めるので、linked worktreeは元のcheckoutと同じprojectになる。session中に`git worktree add`で作られたworktreeは、runtimeのgit shimがpathと作成時のHEADをsession directoryへ記録する。runtimeは終了時に、HEADが作成時のままのworktreeだけを`git worktree remove`へ渡す。`git worktree remove`は変更、untracked file、lockを持つworktreeを拒むので、それらとsessionの外で作られたworktreeは残る。削除の失敗はclientの終了statusを変えない。同時に走った別の`git worktree add`と区別できないworktreeは記録せず、SIGKILLで終わったsessionのworktreeは回収しない。

`CARGO_HOME`と`XDG_CACHE_HOME`が未設定なら共有cacheを使い、利用者が明示した値は空文字列も含めて変えない。Cargoの中間成果物は`CARGO_BUILD_BUILD_DIR`で全sessionが共有する一つのrootの下に置き、`{workspace-path-hash}`でcheckoutごとに分けるので、どのsessionからbuildしても同じcheckoutは同じbuild-dirを使う。最終成果物は各checkoutの`target`に残る。同じworkspaceのcheckoutどうしで中間成果物を共有すると、Cargoが別checkoutのbuildをfreshと判定するため、linked worktreeとも共有しない。利用者が明示した`CARGO_TARGET_DIR`と`CARGO_BUILD_BUILD_DIR`、project固有のCargo`target-dir`と`build-dir`は上書きしない。一時的な写しでbuildするtoolは、写しごとに中間成果物がbuild-dirのrootへ残るため、`CARGO_BUILD_BUILD_DIR`を外して起動する。

`dotfiles-agent-verify`はHEAD、tracked diff、non-ignored untracked content、command、環境からfingerprintを作り、同一fingerprintの成功だけを再利用する。

## 資源の上限

wrapperから起動したclientは、launcherが`systemd-run --user --scope`で作るsession単位のscopeの中で動き、そのscopeはsystemd userの`agents.slice`に属する。scope名は`dotfiles-agent-<client>.<pid>.<suffix>.scope`で、session directoryの名前から導く。clientが起動したbuild、test、browser、VMもscopeに入るため、slice全体で次の上限を共有する。値は`dotfiles.agents.slice`のoptionで変えられる。

| 設定 | 既定 | 根拠 |
|---|---|---|
| `MemoryHigh` | 24G | VMは40GB（MemTotal 39.2 GiB）である。超えた分はslice内のreclaimとthrottleで抑え、`MemoryMax`までの4 GiBを緩衝に使う。 |
| `MemoryMax` | 28G | 残る約11 GiBをsystem.slice、container、MCP front、kernelに残す。2026-10-03の実測はsystem.sliceが1.5 GiB、宣言containerの常駐が合計0.3 GiB、MCP frontが各19〜51 MiB、slabが1.9 GiBだった。containerの`--memory`の合計8.5 GiBとMCPの`MemoryMax`の合計22.5 GiBは個別の天井で、同時に使い切ることは想定しない。 |
| `MemorySwapMax` | 8G | swapは16 GiBのdisk swapとzramである。agentだけでswapを使い切り、基盤のswap-inを止めないようにする。 |
| `CPUWeight` | 50 | 同じuser managerの`app.slice`や`session.slice`（既定100）に対してagentを後に回す。system.sliceとの配分は上位の`user.slice`と`system.slice`の重み（共に100）で決まる。 |

I/Oの制御は入れない。
要件は、agentのbuildやtestのI/Oが、journald、udevd、MCP、containerのbackend、Interop、新しいWSL sessionの応答を止めないことである。
障害時に40〜60%あったio fullは、page cacheの読み直しとswapから来ており、そこへ作用するのはmemoryの上限である。

このkernelはblk-iocostを持たないため`io.weight`が無く、cgroup単位でI/Oを分ける手段はBFQ、`io.max`、`io.latency`に限られる。
root VHDはhostのSATA SSD上のVHDXで、guestには12個のqueueを持つ回転型の仮想diskに見え、2026-10-02のVM起動以来、読み込み1回に平均44.6 msかかっている。
BFQは、二つ以上のcgroupに未完了のrequestがあると、処理中のqueueが空いても次のrequestを短時間待ってdeviceを遊ばせる。
全processがcgroupに分かれたこの系では負荷の下でこの待ちがほぼ常に入り、既に飽和したdiskのthroughputをさらに下げる。
BFQの重みは兄弟のcgroupの間でしか効かず、`agents.slice`に`IOWeight`を付けても、rootの直下でsystem.sliceやinit.scopeとuser.sliceが同じ重みで分け合うことは変わらない。
`io.max`はdeviceに空きがあっても上限を超えさせず、値の根拠になるdeviceの能力はhostのSSDの状態で変わる。
`io.latency`はsystem.sliceに目標を付けると目標を持たない兄弟のcgroupを絞るため、Interopと新しいsessionが動くinit.scopeも絞られ、目標の値にも実測が要る。

判断は、全agent sessionが`agents.slice`に入った後のPSIで見直す。
doctorの`resource/wsl-memory/io-pressure`が`warn`になった時間帯に、`/sys/fs/cgroup/system.slice/systemd-journald.service/`と`/sys/fs/cgroup/init.scope/`の`io.pressure`と`memory.pressure`の`some`の60秒平均を読む。
`io.pressure`が10%以上で`memory.pressure`が10%未満なら、agentのI/Oが基盤を止めているので、BFQとの比較に進む。
両方が10%以上なら基盤のpageが追い出されているので、I/Oの制御ではなく基盤のmemoryの保護で直す。

launcherはscopeを作れないとclientを起動せずに失敗する。user managerに届かない状況で上限のないsessionを起こさないためである。scopeの外で動くclientのprocessはdoctorの`agent/slice-placement`が報告する。

Cargoの並列度は既定のままにする。2026-10-03の実測ではcargo 7個に対しrustcとclippy-driverが合わせて10個で、memoryを押し上げていたのは一つのbuildの`-j`ではなく同時に走るsessionの数だった。slice全体の上限はcargo以外のtoolchainにも同じく効き、`CARGO_BUILD_JOBS`はprojectの`build.jobs`より優先されて上書きしてしまう。

agentが起動する`nix build`のbuilderはnix-daemonの子としてsystem.sliceで動き、`agents.slice`の上限を受けない。[`workstation/nix/module.nix`](../../workstation/nix/module.nix)は`max-jobs`を4、`cores`を3に固定し、1回のnix呼出しの並列度を12 vCPUに収める。`max-jobs`は呼出しごとの上限なので、同時に走る呼出しの数は抑えない。nix-daemonの`CPUWeight`は50にし、同じsystem.sliceのjournald、udevd、宣言済みbackend、MCP frontより後に回す。
Docker daemonが起こすcontainerも`agents.slice`の外にあり、宣言外のcontainerには[containerの配置と上限](#containerの配置と上限)の`containers.slice`が別の上限を置く。

Chromiumはuser busへ届くと自ら`app.slice`にscopeを作って移るため、agentのtestが起動したbrowserも`agents.slice`を抜ける。2026-10-03時点の`app.slice`の`memory.peak`は19.3 GiBだった。そこでuser manager（`user@.service`）全体にも`MemoryHigh` 27G、`MemoryMax` 30Gを置き、`agents.slice`と`app.slice`の合計を抑える。値は`dotfiles.agents.slice.userManager`で変えられ、`agents.slice`の`MemoryMax`より大きくなければ評価が失敗する。
VMの40 GiBから30 GiBを引いた残りは、system.sliceの基盤、`containers.slice`、WSLの`/init`配下、kernelの高次pageの余地で分ける。

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

| 設定 | 値 | 根拠 |
|---|---|---|
| `MemoryMax` | 4G | VMのMemTotal 39.2 GiBからuser managerの`MemoryMax` 30Gを引いた残り9.2 GiBを、このsliceと基盤で分ける。2026-10-04の実測では、runningの宣言外container 12個の`memory.peak`の合計が1.1 GiBで、最大はPGroonga 1個の146 MiBだった。4Gはその3倍余りで、基盤には5.2 GiBが残る。基盤の見積りは、system.sliceのanon 1.3 GiB、Hindsightが`memory.peak` 3.4 GiBまで戻る増分2.9 GiB、kernelの回収できないslab 0.5 GiBの合計4.6 GiBである。 |
| `MemoryHigh` | 3G | 超えた分はslice内のreclaimとthrottleで抑え、`MemoryMax`までの1 GiBを緩衝に使う。 |
| `MemorySwapMax` | 4G | [Docker](https://docs.docker.com/engine/containers/resource_constraints/#--memory-swap-details)は`--memory`だけを指定したcontainerに同じ量のswapを許す。sliceも同じ比にし、残ったcontainerのpageでswapを埋めない。 |
| `CPUWeight` | 50 | root直下の`system.slice`と`user.slice`（共に100）より後に回す。nix-daemonと同じく、agentが起こした処理を基盤より後にする。 |

containerを`agents.slice`の下に置く案は採らない。
system managerのdockerdはuser managerへ委譲したsubtreeにscopeを作れず、rootless Dockerへ移すと宣言済みbackendを含むdaemon全体の移行になるためである。
sliceをsystem.sliceの下に置く案も採らない。
system.sliceの使用量に宣言外のcontainerが混ざり、基盤の実測と分けられなくなるためである。
containerごとの`--memory`に頼る案も採らない。
testcontainersのcontainerは他のprojectのtest codeが作り、2026-10-04の時点でPGroongaのcontainerは上限を持っていなかった。

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

project scopeのidentityは、`dotfiles-memory`が絶対`cwd`からGit common directoryを解決して導く。同じrepositoryのlinked worktreeは共有し、basenameが同じ別repositoryは分離する。projectを特定できないAgentMemory由来の未検証履歴を読むlegacy scopeは、検証済みの知識だけを残すため廃止した。

Hindsightの原文書類はnamed volume `hindsight-data:/home/hindsight/.pg0`に保持する。宣言で固定したmultilingual embeddingとrerankerのmodel mountはNix storeからread-onlyで渡し、retain時のextraction inputはSOPSから展開したcredentialで設定する外部LLMへ送られる。

抽出modelは定額のOpenCode Goで呼べる`minimax-m3`である。保存が明示的な保存と記憶の収穫だけになり件数が少ないため、2026-09-30に`memories/dry-run-extract`で5 modelを比べ、日本語と利用者の制約を保ち、応答が最も速く出力tokenが最も少ないものを選んだ。抽出すべきでない一回限りの許可を事実にしなかったのは`qwen3.8-max`だけだったが、同じ入力で出力tokenが4倍から19倍多く、定額枠を圧迫する。`minimax-m3`はその許可を事実にしたため、何を保存するかは抽出modelに頼らず、保存する前に決める。

client連携は、対応するsession開始とprompt送信でproject/globalのrecall結果をreinjectionするだけで、会話のturnをHindsightへ送らない。runtimeの`hook`も`session-start`と`prompt-submit`以外のeventを拒否する。以前は完結したturnを自動captureしていたが、抽出modelがretain missionに反して進捗やprocess IDのような一時的な状態まで事実として残し、自動recallがそれを毎turnへ注入し、抽出が定額枠を消費したため廃止した。保存は明示的な`memory_save`と、次の[記憶の収穫](#記憶の収穫)だけが行う。

OpenCodeのrecall結果は同じturnのmodel呼出しで共有し、次のpromptで置き換え、idleで破棄する。title生成などの補助呼出しで消費しない。hook実行には30秒、警告通知には1秒のabort期限を設定する。event loopやhostが停止している時間を含めた実時間の上限は保証しない。

既知のmemory/injection blockは決定的に除外するが、secretやPIIをすべて検出できる保証ではない。失敗時に別のmemory backendへfallbackしない。saveが`pending`または`indeterminate`なら保存済みと扱わず、返されたoperationとdocumentのIDを同じscopeの`memory_status`へ渡して確認する。`indeterminate`は送信後の通信断や期限切れで結果を確認できない状態で、runtimeはsaveを自動再送しない。

LLM処理は外部endpointを使う。API keyはSOPS templateからroot所有のruntime environment fileを経てcontainerへ渡し、client hookやMCP frontへは配らない。明示的な保存と記憶の収穫のretain入力が外部providerへ送られる信頼境界を持つ。

## 作業日誌

[`agents/journal/`](../../agents/journal)は、omp の session 記録から日次の作業日誌を作る。project memory が判断を想起のために蓄えるのに対し、作業日誌は全 project の作業を日付順に読める記録として残す。入力は`~/.omp/agent/sessions/`直下の project ごとの session file で、親 session の隣に置かれる subagent の記録は親と内容が重なるため読まない。各 entry の時刻で 06:00 から翌日の 06:00 までを切り出し、利用者の指示、エージェントの応答、tool の名前と意図だけを model へ渡す。thinking、tool の結果、tool の引数は渡さない。project ごとの commit 一覧は Git から読む。

要約は omp の print mode で二段に行い、session ごとの要約を project ごとにまとめる。起動時は session file、rules、Skill、自動検出する extension、tool を読み込まない。project memory の hook は extension とは別に読み込まれることがあり、prompt ごとに cwd の Git common directory から決まる project の記憶を想起して注入する。このため要約は Git の work tree ではない一時 directory で実行し、一時 directory が work tree の中にあれば model を呼ばずにその日を失敗にする。この cwd では project が決まらず、記憶は model の入力に混ざらない。model は omp の`tiny`役割と同じ`opencode-go/deepseek-v4.1-flash`で、認証は omp が保持するものを使う。session の本文には secret や個人情報が混ざり得る。prompt は秘密に見えるものを書かないよう指示するが、検出を保証しない。日誌の repository への commit は全 repository 共通の Git hook を通るが、pre-commit hook が拒否するのは GitHub token の形だけである。

日誌の repository は`dotfiles.workstation.environmentDir`の下に置き、flake の入力にはしない。dotfiles が配備した timer が書き込む出力だからである。

## 記憶の収穫

[`agents/memory-harvest/`](../../agents/memory-harvest)は、omp の session 記録から利用者の訂正、決定、好みを取り出し、project memory へ保存する。session 記録の読み方と omp の呼び出しは作業日誌の package を読み込んで共有し、model も作業日誌と同じ定額の`opencode-go/deepseek-v4.1-flash`と thinking `low`を使う。作業の大半は omp で行うため、Claude Code、Codex、OpenCode の session 記録は読まない。

入力は`~/.omp/agent/sessions/`直下の session file のうち、前回成功した実行から今回の開始までの entry である。attribution が`user`の発言だけを読み、`<project_memory>`と`<system-reminder>`の block を除く。エージェントの応答、tool の結果、注入した文脈、subagent の記録は model へ渡さない。cwd から Git project を決められない session は読まずに報告する。

model には project ごとに、明示的に保存した記憶（`dotfiles-memory curated`）と利用者の発言を渡し、将来の別 session の判断を変える発言だけを候補にさせる。次の発言は候補にしない。今回の作業への依頼、計画、進捗の確認、質問、同意だけの返事、その場だけの許可や禁止、状況に依存する優先度や締切、人の名前を含むもの、利用者が標準、AGENTS、Skill、文書、hook、code へ入れるよう求めた規律、製品の仕様、現在の状態から分かること、保存済みの記憶と同じ内容、secret や個人情報を含むものである。正本に入るものを記憶に重ねないためである。

model は候補ごとに、将来の別 session で同じ判断を迫られる場面を一行で書き、書けない発言は候補にしない。場面を返さなかった候補は保存せず、場面を保存する本文にも含めない。初回の収穫で、その場の禁止や一回限りの許可が好みとして保存されたため、判定を場面に結び付けた。model の判定とは別に、source が保存済みの記憶にある発言は model へ渡さず、保存済みの記憶と文字列が一致する候補は保存しない。失敗した実行を繰り返しても、同じ発言から記憶を二つ作らないためである。

候補は一件ずつ`dotfiles-memory save`へ、scope `project`、session の cwd、kind、source `<session file>#<entry id>`で渡す。`pending`または`indeterminate`の receipt は保存済みと報告せず、state file に残して次の実行で`dotfiles-memory status`へ渡す。state file の読み終えた位置は、全 project の取り出しが成功した実行だけが進める。runtime が資格情報や個人情報に見える候補を拒んだ場合は、その候補だけを捨てて失敗にしない。発言は model の provider へ、保存した内容は Hindsight の抽出 model へ送られる。運用は[記憶の収穫](../operations/memory-harvest.md)に従う。

## LSPと観測

language serverのbinaryとrosterは`toolchain/`が所有する。client形式への写像は[`agents/impl/lsp.nix`](../../agents/impl/lsp.nix)が持つ。Claude Codeはplugin、OMPは`lsp.json`、OpenCodeはconfigの`lsp` blockへ投影し、未対応clientには配らない。

managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。

telemetry collectorはOTLPをloopbackで受け、生recordを残す。CLIはendpointを`dotfiles.telemetry`から読むため、port変更をclient側へ重複して書かない。配備後の調査は[Doctor](../operations/doctor.md)、適用は[Rebuild](../operations/rebuild.md)に従う。
