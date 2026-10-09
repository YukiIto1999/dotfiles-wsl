# AI tooling

**読み手:** Agent、Skill、Capability、provider、runtimeの境界を変更する人。

AI CLIのbinary、共通資材、Capability実装、MCP接続は別のlifecycleを持つ。upstream installerとGitHub releaseで入れるbinaryは`~/.local/bin`の可変物である。policy、Skill、subagent、managed config、MCP serviceはNixOS generationが宣言する。

## 配備と呼出し

```text
agents/policy/AGENTS.md ───────────────────┐
agents/subagents/*.md ── client変換 ──────────┤
skills/*/skill/ ──────────────────────────┼─► Nix store ─► 各clientの設定領域
Orca / architecture-standard / Matt / Google / .NET / mizchi explainerの固定source ─┘

Agent ─► Skill ─► Capability ─► provider adapter ─► Platform MCP ─► gateway
                         └────► backend / credential / persistent state

Agent ─► harness primitive / managed CLI ─► toolchain runtime

AI CLI ─► LSP ─► language server
       └► OTLP ─► telemetry collector
```

[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)はsubagentからSkillへのroutingとsubagent間handoffだけを持ち、provider名、backend名、直接provider例外は置かない。
Skillの依存は取込ownerのNix moduleが`requiresSkills`と`requiresCapabilities`で宣言し、外部Skillでは[`skills/plugins/module.nix`](../../skills/plugins/module.nix)が所有する。

専門判断が必要なtaskは`Agent → Skill`で方法を選び、配備するproviderは`Capability → provider/runtime`の公開契約を通す。
Agentはtask、権限、委譲、成果物handoffを所有する。
Skillは反復する判断、手順、停止条件を所有し、primitive操作のたびに起動するwrapperにはしない。
Capabilityはconsumerに依存しない機能contractである。
provider adapter、container、database、credential、stateはCapabilityの実装詳細であり、AgentやSkillへ逆依存しない。

Read、Grep、Glob、Edit、Write、Bash、LSP、subagentのようなharness機能と、決定的な操作を担うmanaged CLIはAgentが直接使う。
repositoryに配備するproviderは次のCapabilityを通し、公開契約を確認せず内部processやcontainerへ接続しない。

Capability実装の正本は各`capabilities/<id>/module.nix`にあり、Task入口はlocalまたはpluginの採用moduleにある`requiresCapabilities`が宣言する。
この宣言はSkill配備をゲートし、policyのCapability対応へ記載する。
現在のCapability IDは次で取得できる。

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
共通profileはheap-diagnosticsも選び、provider名の`memlab`ではなく意味上のCapabilityから採用する。

各client adapterは`dotfiles.agents.registry`へ登録し、profileの`enabled`から採用済みの`clients`を導く。
配備、installer、runtime wrapper、health、policyの能力表は採用集合だけを読む。

[`skills/module.nix`](../../skills/module.nix)はSkill ID、Skill依存、hard Capability依存から、選択したCapabilityで実行できるSkillを導く。[`capabilities/module.nix`](../../capabilities/module.nix)はCapability依存closure、provider owner、backend ownerを検証し、`dotfiles.capabilities.resolved`、`dotfiles.platform.mcp.enabledProviders`、`dotfiles.platform.containers.enabled`を導く。現在のconsumer数はownershipの判断に使わない。
hard依存は主要手順の必須条件であり、条件付きbrowserやcloud branchで一般Skill全体をgateしない。

Agent clientへ配るのは、解決したSkill registryの`source` directoryとその本文、reference、scriptである。
必要なSkillを失ったsubagentとそのhandoffも配備しない。
Nix module、依存metadata、fixtureは配備先へ混ぜず、同じIDのsource差替えはNixの明示的なoverrideだけで行う。
Orca、architecture-standard、Matt Pocock、Chrome DevTools MCP、.NET skills、mizchi explainerは固定source内の任意のSkill directoryを直接参照し、本文や資材を変換、複製しない。
原版の起動flagも保持し、policy rosterがtask一致、明示command、consumerから読むreference-onlyを区別する。
`user-invocable: false`と`disable-model-invocation: true`が両方あるhelperは、enabled registryに残して依存を満たすが、shared discovery source、clientのnamed Skill directory、subagent routeへは投影しない。
consumerはpolicy rosterのraw source絶対pathを`Read`で開き、固定source実体のsibling referenceを利用する。
片方だけを持つ明示commandなどのnative投影は変えず、原版の起動flagを保持する。
Modern Web Guidanceは外部source全体のhome assetとして保持し、対象guideを原文で読むが、全frontendへ起動するwrapperはSkill registryに採らない。
外部Skillのraw directoryを配ることと、同梱scriptの実行依存を供給することは別の契約である。
explainerのraw sourceとsibling配置はそのまま保持し、別ownerの[`toolchain/package/explainer/package.nix`](../../toolchain/package/explainer/package.nix)が固定したmanifestとlock、browser、絶対pathを要求する実行wrapperを供給する。
package作成時に置き換えるのはruntime用manifestとlockだけであり、upstreamのSkill本文やscriptは変更しない。
wrapperは書込み可能な一時CWDへ管理下のpackageと依存を参照させるが、upstreamが記事側の祖先packageを優先する条件やcheckerの限界を消さないため、対象directoryと証拠の制約は[外部CLI](../reference/tooling.md#外部cli)へ集約する。
任意shell、外部送信、model課金の許可や、optional D2とformal backendの供給をraw採用から推定しない。
`description-writing`とcustom `article-reproduction`は単独で成立する判断を持ち、raw `explainer`、`first-reader`、browserや.NET実行への引渡しを該当branchだけで行う。
これらを一般の執筆やcodingのhard依存へ広げず、返却証拠から同じownerの仕事を再開し、writer側の再現性loopやreader試行を重ねない。
採用IDとpath、revision、licenseの関係は[Skill portfolio](skills.md#直接採用)、登録と差替の契約は[外部リポジトリ所有Skillの構成](repository-skills.md)を参照する。

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
fileごとのprocess起動を避けるため、tracked fileのmetadataと内容hashはコマンド行長の上限内でまとめて取得する。
読み取り前後のmetadataを照合し、gitlinkはその内容まで再帰的に検証する。
宣言されたT1をrepositoryの根で呼ぶ場合は、入口解決から成功証跡の保存までを120秒で制限し、予算超過時は検証processの子孫を止めて成功として扱わない。
検証の証跡は走行tokenごとに、metadataの読み取り前後を照合した検査前のsourceへ固定し、時間内の保存と後始末を見届けたwrapperが完了を記す。
T1の走行中のmetadata変化はcache keyとは別に照合し、検査後に編集されたsourceへ証跡を結び直さない。
公開途中の証跡やまだ動いているwrapperの証跡は終了gateを開かず、期限超過や中断では同じ走行tokenの証跡と一時fileだけを回収するため、別の完了済み走行の証跡は巻き込まない。
wrapperの生存はPID、boot ID、processの開始時刻で照合するため、PIDの再利用や再起動で別のprocessが現れても完了済みの証跡を失効させない。
完了markerは末尾の改行まで揃った場合だけ受理し、file size制限による部分書込の失敗でも終了を認めない。
古い証跡の整理はT1へ含めず、終了gateが同じ木の完了済み証跡を受理するときに行う。

[`dotfiles-agent-gate`](../../agents/impl/runtime/gate.sh)は、Claude CodeとOMPの編集hookでfile pathに対応する配備済みSkillの読取記録を要求する。
OMP hook は write の本文と read の全文を JSON に含めたまま gate の stdin へ送り、read の証明を照合する Node process へも pipe で渡す。
argv に本文を載せないため、1 引数や argv 全体の容量制限で検証前に失敗しない。
20 秒の期限または中断では gate の process group 全体を停止し、編集や終了を拒否する。
編集対象はsymlinkと`..`を解決したpathで判定する。
agent runtimeが割り当てた`~/.cache/dotfiles-wsl/sessions/<session>/tmp`の内側にあり、祖先にGit metadataを持たない一時fileは対象から外す。
割当ての確認には、canonical pathの`<session>`と`DOTFILES_AGENT_SESSION_ID`の一致に加え、同じsession directoryの`metadata.json`が実fileであり、`version`が1、`session_id`が`<session>`と一致することを要求する。
metadataを持たない手作りのdirectory、別sessionの識別情報、不正なmetadataでは除外しない。
空であると確認できる実directoryの`.git`はmetadataに数えないが、空でないdirectory、file、symlinkは除外を認めない。
任意の`TMPDIR`、Git checkout内の一時file、checkoutへ向くsymlinkは対象から外さない。
記録するのは、成功した読取後のeventで観測した`skill://NAME`、`skill://NAME/SKILL.md`、設定済みSkill rootの`NAME/SKILL.md`の本文読取だけであり、呼出し前、失敗、reference、部分読取、編集操作は証拠にしない。
記録の前に、OMPの実resultが示すsourceと表示本文、Claudeの成功したtext resultが示すfile pathと本文を現在のcanonical本文へ照合し、省略、要約、token cap、途中のpage、本文を持たない結果は証拠にしない。
記録には配備先のsymlinkを解決した本文のSHA-256を保存し、編集時に現在の本文と照合するため、配備内容が変わったら読み直す。
`learned --session ID --path NAME`は、既存の配備済み本文を管理者が明示的に承認するための信頼された操作として残し、通常の読取hookの代わりには使わない。

`standard-conformance`のcanonical本文を成功した読取eventで読んだsessionは、監査完了の確認が済むまで終了できない。
`standard-apply`だけの読取や管理者の`learned`操作から、この監査義務を推定しない。
`dotfiles-agent-gate conformance --session ID --repo PROJECT --standard-root ROOT --report REPORT`は、成功read時に記録したcanonical `SKILL.md`の物理pathの三段上を正本rootとし、現在の配備先と指定ROOTの物理pathとの一致を要求する。
同じ物理rootを指すsymlinkは受理するが、同じSkill本文をコピーした別の正本束は受理しない。
現在のSkill本文hashも照合してから、この正本束に含まれる実際のcoverage checkerをNodeで実行する。
報告は対象Git checkoutの外に置き、baselineの正本は対象projectのrootを表す`PROJECT`の下の`PROJECT/docs/conformance-baseline.json`とする。
checkerがexit 0で`PASS`か`WARN`を返した場合だけ、観測した標準とprojectのdigest、報告とcheckerのhash、各pathをsessionのreceiptへ保存する。
終了時は現在のinventoryとこれらのhashを照合し、同じ木の`check`を重複実行せずに、確認の欠落や後の変更を拒否する。
旧配備のSkillにcheckerがなければ確認済みとして通さず、source updateと実session IDを含む実行commandを案内する。

OMPのgate起動例外は説明付きの非ゼロ結果となり、編集前とsession終了時の判定はgateが起動しない場合も処理を止める。
読取後の記録、編集後のrepository登録、shell実行後の変更観測は実行済みのtoolを取り消せず、後段hook自体が失敗すると記録が残らないこともある。
終了時の検証gateが要求するのは、編集を記録したrepository自身が宣言するT1の`verify`入口だけであり、入口を持たないrepositoryには要求しない。
このgateは通常のhook経路でtoolが返した全文とその鮮度、成功readした配備正本束との一致、文書単位の監査完了を確認するもので、悪意あるagentからの防御、注意や理解、後続compactionでの本文保持、正しい監査対象の選択、証拠やcheckの意味と真偽、標準全体への意味的な適合を保証しない。

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
`browser-diagnostics`のSkill入口はcustom `browser-performance`、LCP専門の`debug-optimize-lcp`、実画面監査の`a11y-debugging`であり、Playwright操作の入口は`browser-operation`である。
一般の`diagnosing-bugs`はbrowser Capabilityを要求せず、必要なbranchだけ専門入口へ渡す。
heap-diagnosticsのregistryは[`capabilities/heap-diagnostics/module.nix`](../../capabilities/heap-diagnostics/module.nix)が所有し、providerは`memlab`だけ、backendとCapability依存は空である。
入口の`heap-analysis`はheap-diagnosticsだけを要求し、heap artifactをproject-memoryへ送らず、ChromeまたはNode.jsのlocal snapshotと比較条件を扱う。
native .NET/Rustのdump、RSSだけの増加、歴史的memoryの検索や保存は所有しない。

providerの[`module.nix`](../../capabilities/heap-diagnostics/memlab/mcp/module.nix)はport `8777`、stdioのsession lifecycle、`needsNetwork = false`を宣言し、downstream sessionごとにresident snapshotとhandleを分離する。
共通frontの`MemoryMax = \"2G\"`とは別に、[`package.nix`](../../capabilities/heap-diagnostics/memlab/mcp/package.nix)がNode old-spaceを`1024` MiB、解析timeoutを`45000` msへ制限する。
fileを載せる前にheaderと現在のresident stateを調べ、重いwalkや複数loadを並行させず、不要なsnapshotをunloadする。

配備するのは固定archive hashとpackage-lockを持つpublished `@memlab/mcp-server` `2.86.0`であり、調査用Git sourceの`915` prefixの版と同一視しない。
published packageが持つsnapshot headerとmulti-snapshot APIを基準に、現在のschemaを確認する。
原版のtool bodyは変更せず、localの[`readonly-server.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/readonly-server.mjs)を追加し、33の解析・session登録だけを公開する。
`eval`、`for_each`、`eval_across`、`batch`と任意codeを実行するcomposite経路は登録しない。
この入口制限をVMによる安全なsandboxやheap内の秘密情報の無害化と呼ばず、取得許可、絶対path、localでの保持、報告時の秘匿化を別に守る。

[`admission.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/admission.mjs)はlocalの絶対pathだけをloadに許可し、`force`によるadmissionの回避を拒否する。
比較はguard付きでload済みのresident snapshotだけを受け付け、fresh fileから比較APIへ直接入る経路を拒否する。
[`supervised-server.mjs`](../../capabilities/heap-diagnostics/memlab/mcp/package/supervised-server.mjs)はsession専用workerのstdioをpipeにし、同期処理にも独立したdeadlineを適用する。
deadlineを超えたworkerだけを終了し、未完了の解析を空の結果として返さず、他sessionのgraphには触れない。
これはNode old-spaceの上限であり、processのRSSを1 GiB以下に保証するものではない。

Chromeのfile exportの保存先制限は、clientのtool harnessやgatewayではなく、固定したChrome MCP packageのcanonical path検査が所有する。
[`package.nix`](../../capabilities/browser-diagnostics/chrome-devtools/mcp/package.nix)は既存frontの`runtimeDirectoryPath`を`mk-server`の`env.TMPDIR`とCLIの`--filesystemRoot`へ渡し、systemdがmode `0700`で所有するprivateな領域だけを既定の保存先にする。
providerはcallerごとに割り当てた`TMPDIR`を起動時には知らないため、callerのsession cacheやworkspace全体をfilesystem rootへ追加しない。
[`browser-performance`](../../skills/browser-performance/skill/SKILL.md)はtrace、screenshot、heapに共通のprovider-owned private stagingを作り、capture後のfileをmode `0600`でcallerの`TMPDIR`へ移動して自分のstagingを回収する。
[`heap-analysis`](../../skills/heap-analysis/skill/SKILL.md)は転送後のlocal fileを公開MemLab toolへ渡し、不要なresident graphと自分のfileを回収する。
privateなruntime保存先が拒否された場合はcapture不能を報告し、repository、symlink、共有`/tmp`への保存や無制限path設定で回避しない。
外部のtool例があっても、実tool schema、gateway接続、account選択、権限、副作用の安全境界を取込側の契約で確認する。

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
promptから既知の注入blockを除いた残りが空なら想起せず、残った利用者発言にだけprivacyと長さの検査を行う。
通信失敗は接続、読取り、書込み、pool、protocolの固定した分類で報告し、query、接続先、応答本文、例外の表示は報告へ含めない。
分類を詳しくしてもerror codeは`unavailable`のままであり、送信済みのsaveを確認できない場合の`indeterminate`は変えない。
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
modelを呼ぶ前に`dotfiles-memory validate`へ発言の全文、保存済みの記憶のkindと本文、projectのpathを渡し、保存時と同じ既知の資格情報や個人情報の指標で検査する。
日本語の文に直接続く既知形式のAPI keyも不許可とし、URLの資格情報検査は本文を切り詰めずに行う。
このcommandはbackendへ接続せず、検査対象の本文を返さない。
発言と保存済みの記憶は不許可のrecord全体を除き、projectのpathが不許可なら見出しへ含めない。
長い本文をclipするのは検査を通した後であり、不正な応答や検査失敗ではmodelを呼ばず、読み終えた位置も進めない。
指標に合わないsecretや個人情報まで検出できる保証はなく、作業日誌の送信前検査には使っていない。

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
