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

[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix)はsubagentからSkillへのroutingとsubagent間handoffだけを持つ。provider名、backend名、直接provider例外は置かない。Skillの依存は各[`skills/NAME/module.nix`](../../skills)が`requiresSkills`、`requiresCapabilities`、`optionalCapabilities`で宣言する。

実行時の原則は`Agent → Skill → Capability → provider/runtime`である。Agentはtask、権限、委譲、成果物handoffを所有する。Skillは反復する判断、手順、停止条件を所有する。Capabilityはconsumerに依存しない機能contractである。provider adapter、container、database、credential、stateはCapabilityの実装詳細であり、AgentやSkillへ逆依存しない。

Read、Grep、Glob、Edit、Write、Bash、LSP、subagentのようなharness機能はAgentが直接使う。repositoryに配備するproviderは次のCapabilityを通す。

Capability実装の正本は各`capabilities/<id>/module.nix`にある。Task入口の正本は各[`skills/<id>/module.nix`](../../skills)にある`requiresCapabilities`と`optionalCapabilities`である。前者だけがSkill配備をゲートし、後者は利用可能なときpolicyのCapability対応へ記載する。現在のCapability IDは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.registry --apply builtins.attrNames
```

各Skillが宣言するCapabilityは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.registry --apply 'builtins.mapAttrs (_: skill: { inherit (skill) requiresCapabilities optionalCapabilities; })'
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

runtimeはsession ID、owner process、boot ID、管理下`TMPDIR`を記録する。resource台帳の開始・終了フックは各5秒で打ち切り、台帳処理の停止をclient本体へ連鎖させない。打ち切った台帳はreaperの回復対象になる。

`CARGO_HOME`と`XDG_CACHE_HOME`が未設定なら共有cacheを使い、利用者が明示した値は空文字列も含めて変えない。Git repositoryではgit common directoryからproject IDを作り、linked worktree間でCargo targetを共有する。project固有のCargo`target-dir`は上書きしない。

`dotfiles-agent-verify`はHEAD、tracked diff、non-ignored untracked content、command、環境からfingerprintを作り、同一fingerprintの成功だけを再利用する。managed worktreeはsession台帳、clean、HEAD不変、利用中processなしを確認できる場合だけ回収する。

## Policy、subagent、Skill

[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)は全clientへ配るpolicyの正本である。静的subagentは`agents/subagents/`に置く。Claude CodeとOMPはfrontmatter Markdown、OpenCodeはSkill toolを許可するfrontmatter Markdown、CodexはTOMLへbuild時に変換する。Antigravityは未対応を明示する。

`native`と`rendered`のsubagentはhome配下へ配備する。Codexの`declared` subagentはhomeへsymlinkせず、`config.toml`の`[agents.<subagent>]`からNix storeの実体を`config_file`で指す。Codexがsubagent fileを`O_NOFOLLOW`で開き、symlinkを拒否するためである。
client別の能力配備の正本は各`agents/clients/<id>/module.nix`のmode宣言である。`projectMemoryMode`は`hooks`、`plugin`、`unsupported`のいずれかで、対応する配備先は`capabilityManagedFiles.projectMemory`が指すmanaged fileである。現在の各clientのmodeは次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply 'builtins.mapAttrs (_: client: { inherit (client) subagentMode skillProjectionMode lspMode telemetryMode projectMemoryMode; })'
```

`projectMemoryMode`はclient固有のcapture入口を表すが、明示的な検索、検証、保存の判断を代替しない。

Claude CodeとCodexのuser configはclientが更新し得るため、Home Managerは配備先が存在しない場合だけseedを作る。seed は runtime drift の対象にしない。OMPの`config.yml`と`agent.db`もclient所有の可変fileとして残す。
OMPのseedはBash interceptorを有効にし、直接の再帰検索を専用検索手段へ誘導する。既存の`config.yml`はOMP自身の設定commandで移行する。

## MCP Platform

各[`capabilities/`](../../capabilities)実装が`dotfiles.platform.mcp.targets`へprovider ID、executable、server transport、server lifecycle、port、通信要件、backend unit、probeを登録する。[`platform/mcp/module.nix`](../../platform/mcp/module.nix)はtargetからfrontを一度だけ導く。

`stdio`の`service` lifecycleは一つのstdio serverをfront serviceの寿命で共有する。`session` lifecycleはagentgatewayがdownstream sessionごとにstdio serverを生成する。`streamable-http`はproviderのforeground serverをfront serviceとして起動する。backendを持つtargetは`waitUnits`をfrontの`requires`と`after`へ設定する。

[`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)は単一endpointのID、port、URL、service、runtime directory、YAML source、target名を公開する。gatewayは全frontへloopback HTTPで接続するが、front serviceを起動依存に持たず、子processも作らない。各AI CLIが知る接続先はこのURLだけである。

browser automationとbrowser diagnosticsは異なる観測contractを持つが、[`capabilities/browser-runtime/chromium/module.nix`](../../capabilities/browser-runtime/chromium/module.nix)のChromium packageを共有する。tab、page、browser processはdownstream session間で共有しない。

現在のtarget名は次で取得できる。

```bash
nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames
```

## Container Platform

[`platform/containers/module.nix`](../../platform/containers/module.nix)は型付きservice contract、Docker daemon、`dotfiles-backends` network、OCI image inventory、image同期を所有する。[`platform/containers/impl/container-backend.nix`](../../platform/containers/impl/container-backend.nix)はCapability実装が使うpure builderである。

application固有のcontainer、endpoint、credential、volume、provisioningは対応するCapabilityが所有する。Hindsight、Crawl4AI、SearXNG、SonarQubeをgeneric Platformへ列挙しない。SonarQubeは[`server`](../../capabilities/code-quality/sonarqube/server)、[`database`](../../capabilities/code-quality/sonarqube/database)、[`provisioning`](../../capabilities/code-quality/sonarqube/provisioning)、[`mcp`](../../capabilities/code-quality/sonarqube/mcp)へ分ける。

Capability実装はregistry metadataを常に宣言し、backend、MCP target、credential、永続data、health observation、client integrationを`dotfiles.capabilities.resolved`で条件化する。container backendが一件もなければ、Container PlatformはDocker daemon、共通network、image同期command、GC timerを配備しない。

全containerは暗黙pullを無効にする。upstream imageはdigest固定の宣言と、containerを有効にしたhostへ配備する`dotfiles-sync-images`が取得を担当し、Nix生成imageは`imageFile`が取得を担当する。Docker build artifact GCはdangling imageとBuildKit cacheだけを扱い、tagged image、container、volumeは削除しない。

## Project memory

現行のproject memory実装は[`capabilities/project-memory/hindsight/`](../../capabilities/project-memory/hindsight/)が所有する。`backend`はHindsight、`runtime`は`bin/dotfiles-memory`を含むpackage、`mcp`はmemory providerのfront、`client-integrations`は共通hook packageとOpenCode pluginをそれぞれ持つ。Capabilityが公開するgeneric optionは`dotfiles.capabilities.project-memory.runtime`と`dotfiles.capabilities.project-memory.clientIntegrations.{hooks,opencodePlugin}`であり、client moduleはprovider名やbackend pathを直接参照しない。移行元のexportはrepository外のbackupに保全する。

```text
Claude Code / Codex / OMP hooks ─┐
OpenCode capture plugin ─────────┼─► dotfiles-memory ─► 127.0.0.1:3111 Hindsight
                                 │                         │
AI CLI ─► gateway ─► memory MCP ┘                         └─► hindsight-data volume
```

memory MCPのendpointは`front`のport `8774`、Hindsight APIは`localhost:3111`である。MCPの入口は`memory_health`、`memory_recall`、`memory_save`、`memory_status`、`memory_verify`で、project/global/legacyのscopeを明示する。healthはHindsightのdatabaseとmodel readinessだけを確認し、LLMが利用できることやretainが成功したことは証明しない。

project scopeのidentityは、`dotfiles-memory`が絶対`cwd`からGit common directoryを解決して導く。同じrepositoryのlinked worktreeは共有し、basenameが同じ別repositoryは分離する。legacy scopeはAgentMemoryの未検証履歴をread-onlyで検索する領域で、自動recallには混ぜず、current sourceで確認した知識をprojectまたはglobalへ明示的に保存する。

Hindsightの原文書類はnamed volume `hindsight-data:/home/hindsight/.pg0`に保持する。宣言で固定したmultilingual embeddingとrerankerのmodel mountはNix storeからread-onlyで渡し、retain時のextraction inputはSOPSから展開したcredentialで設定する外部LLMへ送られる。native legacy importは指定snapshotの全recordを元IDとcanonical raw record documentで保持し、local re-embeddingだけを行い、LLMによる再抽出とlegacy consolidationを行わない。

client連携は直近の完結したuser/assistant turnを自動captureし、対応するsession開始とprompt送信でproject/globalのrecall結果をreinjectionする。native adapterはassistantの正常終了を示す情報を保持し、runtimeは最新のassistantが正常終了したturnだけを採用する。失敗、途中終了、終了状態不明のturnを過去の応答で補わない。OMPは末尾から最大128entryを辿り、OpenCodeは最新128messageだけを取得する。両clientはcapture対象のtextと区切り分を12000文字以内に制限し、上限内にuser側の境界が見つからない場合は部分保存せず警告する。

ClaudeとCodexのStopでは、利用者メッセージの由来を確認してnativeの最終応答を優先する。Codexではhookのturn IDもtranscriptに照合する。CodexはStop後に`task_complete`を記録するため、Stop処理中にはその記録を要求しない。PreCompactとSessionEndではtranscriptの正常終了を確認する。

OpenCodeのrecall結果は同じturnのmodel呼出しで共有し、次のpromptで置き換え、idleで破棄する。title生成などの補助呼出しで消費しない。idle eventのcaptureはpluginが追跡し、`dispose`で開始済み処理の完了または失敗通知を待つ。履歴取得とhook実行には29秒、警告通知には1秒のabort期限を設定する。event loopやhostが停止している時間を含めた実時間の上限は保証しない。

既知のmemory/injection blockは決定的に除外するが、secretやPIIをすべて検出できる保証ではない。失敗時に別のmemory backendへfallbackしない。saveが`pending`または`indeterminate`なら保存済みと扱わず、返されたoperationとdocumentのIDを同じscopeの`memory_status`へ渡して確認する。`indeterminate`は送信後の通信断や期限切れで結果を確認できない状態で、runtimeはsaveを自動再送しない。

LLM処理は外部endpointを使う。API keyはSOPS templateからroot所有のruntime environment fileを経てcontainerへ渡し、client hookやMCP frontへは配らない。sessionのretain入力が外部providerへ送られる信頼境界を持つ。

## 作業日誌

[`agents/journal/`](../../agents/journal)は、omp の session 記録から日次の作業日誌を作る。project memory が判断を想起のために蓄えるのに対し、作業日誌は全 project の作業を日付順に読める記録として残す。入力は`~/.omp/agent/sessions/`直下の project ごとの session file で、親 session の隣に置かれる subagent の記録は親と内容が重なるため読まない。各 entry の時刻で 06:00 から翌日の 06:00 までを切り出し、利用者の指示、エージェントの応答、tool の名前と意図だけを model へ渡す。thinking、tool の結果、tool の引数は渡さない。project ごとの commit 一覧は Git から読む。

要約は omp の print mode で二段に行い、session ごとの要約を project ごとにまとめる。起動時は session file、rules、Skill、自動検出する extension、tool を読み込まない。project memory の hook は extension とは別に読み込まれ得るため、要約は Git の work tree ではない一時 directory で実行し、一時 directory が work tree の中にあれば model を呼ばずにその日を失敗にする。project scope の保存先は cwd の Git common directory から決まるので、この cwd では決まらず、日誌の入力は project memory に保存されない。model は omp の`tiny`役割と同じ`opencode-go/deepseek-v4.1-flash`で、認証は omp が保持するものを使う。session の本文には secret や個人情報が混ざり得る。prompt は秘密に見えるものを書かないよう指示するが、検出を保証しない。日誌の repository への commit は全 repository 共通の Git hook を通るが、pre-commit hook が拒否するのは GitHub token の形だけである。

日誌の repository は`dotfiles.workstation.environmentDir`の下に置き、flake の入力にはしない。dotfiles が配備した timer が書き込む出力だからである。

## LSPと観測

language serverのbinaryとrosterは`toolchain/`が所有する。client形式への写像は[`agents/impl/lsp.nix`](../../agents/impl/lsp.nix)が持つ。Claude Codeはplugin、OMPは`lsp.json`、OpenCodeはconfigの`lsp` blockへ投影し、未対応clientには配らない。

managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。

telemetry collectorはOTLPをloopbackで受け、生recordを残す。CLIはendpointを`dotfiles.telemetry`から読むため、port変更をclient側へ重複して書かない。配備後の調査は[Doctor](../operations/doctor.md)、適用は[Rebuild](../operations/rebuild.md)に従う。
