# AI tooling

**読み手:** Agent、Skill、Capability、provider、runtimeの境界を変更する人。

AI CLIのbinary、共通資材、Capability実装、MCP接続は別のlifecycleを持つ。upstream installerとreleaseで入れるbinaryは`~/.local/bin`の可変物、OMPはflake inputに固定したNix packageである。policy、Skill、role、managed config、MCP serviceはNixOS generationが宣言する。

## 配備と呼出し

```text
agents/policy/AGENTS.md ───────────────────┐
agents/roles/*.md ── client変換 ──────────┤
skills/*/skill/ ──────────────────────────┼─► Nix store ─► 各clientの設定領域
flake inputのplugin Skill ─────────────────┘

Agent ─► Skill ─► Capability ─► provider adapter ─► Platform MCP ─► gateway
                         └────► backend / credential / persistent state

AI CLI ─► LSP ─► language server
       └► OTLP ─► telemetry collector
```

[`agents/roles/routing.nix`](../../agents/roles/routing.nix)はroleからSkillへのroutingとrole間handoffだけを持つ。provider名、backend名、直接provider例外は置かない。Skillの依存は各[`skills/NAME/module.nix`](../../skills)が`requiresSkills`と`requiresCapabilities`で宣言する。

実行時の原則は`Agent → Skill → Capability → provider/runtime`である。Agentはtask、権限、委譲、成果物handoffを所有する。Skillは反復する判断、手順、停止条件を所有する。Capabilityはconsumerに依存しない機能contractである。provider adapter、container、database、credential、stateはCapabilityの実装詳細であり、AgentやSkillへ逆依存しない。

Read、Grep、Glob、Edit、Write、Bash、LSP、subagentのようなharness機能はAgentが直接使う。repositoryに配備するproviderは次のCapabilityを通す。

| Capability | Task入口 | 実装 |
|---|---|---|
| `library-documentation`、`web-content`、`web-discovery` | `web-research` | Context7、Crawl4AI、SearXNG |
| `repository-search` | `repository-research` | Zvec-Grep |
| `github-resources` | `github-operations` | GitHub MCP |
| `code-quality` | `code-review` | SonarQube |
| `browser-automation` | `browser-operation` | Playwright |
| `browser-diagnostics` | `performance-analysis` | Chrome DevTools |
| `project-memory` | `memory-management` | AgentMemory |
| `agent-session` | 別clientの独立sessionを起動するAgent | Codex MCP |

Skill-firstはrouting規則であり、MCPやcontainerをSkill directoryへ置く規則ではない。Skill本文は全clientへ配備する一方、Capability実装はtransport、service lifecycle、network、credential、永続dataを所有するため、`capabilities/`に置く。

## Profileとregistry

[`profiles/workstation.nix`](../../profiles/workstation.nix)は有効なAgent client、Skill、Capability、language server、identityを選ぶ。MCP providerやcontainer backendを直接列挙しない。

[`skills/module.nix`](../../skills/module.nix)はSkill ID、source、Skill依存、Capability依存を検証する。[`capabilities/module.nix`](../../capabilities/module.nix)はCapability依存closure、provider owner、backend ownerを検証し、`dotfiles.platform.mcp.enabledProviders`と`dotfiles.platform.containers.enabled`を導く。現在のconsumer数はownershipの判断に使わない。

Agent clientへ配るのは`skills/<id>/skill/`だけである。Nix module、依存metadata、fixtureは配備先へ混ぜない。plugin Skillも同じregistryへ入れ、同名IDを評価時に拒否する。

## Client binary

client contractはupstream installer、GitHub release、Nix packageの三経路を持つ。`dotfiles-install-agents`はClaude CodeとAntigravityのupstream installer、CodexとOpenCodeのGitHub releaseを更新する。OMPはBun/Rust native addonを含むupstream Nix packageを`flake.lock`に固定し、rebuildで更新する。

Codex runtimeのrelease asset、architecture別entrypoint、`requiredPaths`、`retainedReleases`は[`capabilities/agent-session/codex/module.nix`](../../capabilities/agent-session/codex/module.nix)が所有する。Agent client設定とCodex MCP adapterは同じruntime contractを消費する。他clientのinstall contractは各[`agents/clients/NAME/module.nix`](../../agents/clients)が所有する。

GitHub release経路はGitHub APIのSHA-256 digestとarchiveを照合し、member名、type、件数、論理size、重複、path衝突を展開前に検査する。展開後はowner、mode、link、entrypoint、required path、version probeを通したtreeだけを公開する。

管理releaseは`~/.local/share/dotfiles/agents/<client>/releases/sha256-<digest>`に置く。`current`は同じclient root内の相対symlink、`~/.local/bin/<binary>`は`current`内のentrypointを指す相対symlinkである。lockと固定したdirectory descriptorの下でidentityを照合し、所有を確認できないobjectは削除しない。

Claude Code、Codex、OMP、OpenCodeは、Home Managerが`~/.local/bin`より前へ置く共通runtime wrapperから起動する。wrapperはupstream binaryまたはNix store executableを絶対pathで実行する。Antigravityは同じCLI起動境界を持たない。

runtimeはsession ID、owner process、boot ID、管理下`TMPDIR`を記録する。`CARGO_HOME`と`XDG_CACHE_HOME`が未設定なら共有cacheを使い、利用者が明示した値は空文字列も含めて変えない。Git repositoryではgit common directoryからproject IDを作り、linked worktree間でCargo targetを共有する。project固有のCargo`target-dir`は上書きしない。

`dotfiles-agent-verify`はHEAD、tracked diff、non-ignored untracked content、command、環境からfingerprintを作り、同一fingerprintの成功だけを再利用する。managed worktreeはsession台帳、clean、HEAD不変、利用中processなしを確認できる場合だけ回収する。

## Policy、role、Skill

[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)は全clientへ配るpolicyの正本である。静的roleは[`agents/roles/`](../../agents/roles)に置く。Claude CodeとOMPはfrontmatter Markdown、OpenCodeはSkill toolを許可するfrontmatter Markdown、CodexはTOMLへbuild時に変換する。Antigravityは未対応を明示する。

`native`と`rendered`のroleはhome配下へ配備する。Codexの`declared` roleはhomeへsymlinkせず、`config.toml`の`[agents.<role>]`からNix storeの実体を`config_file`で指す。Codexがrole fileを`O_NOFOLLOW`で開き、symlinkを拒否するためである。

| Client | Role | Skill投影 | LSP | Telemetry | AgentMemory |
|---|---|---|---|---|---|
| Claude Code | rendered Markdown | required Skillをpreload | plugin | managed settings | lifecycle hooks |
| Codex | rendered TOML | bodyからdynamic routing | unsupported | unsupported | lifecycle hooks |
| OMP | rendered Markdown | required Skillをautoload | native config | unsupported | native hooks |
| OpenCode | rendered Markdown | Skill toolでdynamic routing | config | unsupported | capture plugin |
| Antigravity | unsupported | unsupported | unsupported | unsupported | unsupported |

Claude CodeとCodexのuser configはclientが更新し得るため、Home Managerは配備先が存在しない場合だけseedを作る。seed は runtime drift の対象にしない。OMPの`config.yml`と`agent.db`もclient所有の可変fileとして残す。

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

application固有のcontainer、endpoint、credential、volume、provisioningは対応するCapabilityが所有する。AgentMemory、Crawl4AI、SearXNG、SonarQubeをgeneric Platformへ列挙しない。SonarQubeは[`server`](../../capabilities/code-quality/sonarqube/server)、[`database`](../../capabilities/code-quality/sonarqube/database)、[`provisioning`](../../capabilities/code-quality/sonarqube/provisioning)、[`mcp`](../../capabilities/code-quality/sonarqube/mcp)へ分ける。

全containerは暗黙pullを無効にする。upstream imageはdigest固定の宣言と`dotfiles-sync-images`、Nix生成imageは`imageFile`が取得を担当する。Docker build artifact GCはdangling imageとBuildKit cacheだけを扱い、tagged image、container、volumeは削除しない。

## AgentMemory

[`capabilities/project-memory/agentmemory/`](../../capabilities/project-memory/agentmemory)がupstream version、engine backend、MCP adapter、client integrationを所有する。保存先はhostの`/var/lib/agentmemory/data`をcontainerの`/data`へmountした領域であり、Nix storeには保存しない。

```text
Claude Code / Codex / OMP hooks ─┐
OpenCode capture plugin ─────────┼─► 127.0.0.1のengine API ─► /var/lib/agentmemory/data
                                 │
AI CLI ─► gateway ─► memory MCP ┘
```

LLM処理は外部のOpenAI互換endpointを使う。API keyはSOPS templateがruntime環境ファイルへ展開し、Dockerがcontainerへ渡す。sessionのpromptやcodeが外部providerへ送られる信頼境界を持つ。

## LSPと観測

language serverのbinaryとrosterは`toolchain/`が所有する。client形式への写像は[`agents/impl/lsp.nix`](../../agents/impl/lsp.nix)が持つ。Claude Codeはplugin、OMPは`lsp.json`、OpenCodeはconfigの`lsp` blockへ投影し、未対応clientには配らない。

managed file は artifact owner が observation を登録し、doctor が current source との不一致を検査する。

telemetry collectorはOTLPをloopbackで受け、生recordを残す。CLIはendpointを`dotfiles.telemetry`から読むため、port変更をclient側へ重複して書かない。配備後の調査は[Doctor](../operations/doctor.md)、適用は[Rebuild](../operations/rebuild.md)に従う。
