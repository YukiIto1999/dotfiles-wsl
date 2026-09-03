# 構成概要

**読み手:** 責務境界と依存方向を理解し、変更先を判断する人。

このリポジトリは、NixOS-WSL、Home Manager、systemd、Docker、SOPS、Agent環境を一つのflakeから組み立てる。正本はcheckout内のNix宣言、asset、暗号化済みsecretである。生成後の`/etc`、Home Manager配備先、Nix storeは編集しない。変更先は[変更箇所](../reference/change-map.md)、適用手順は[Rebuild](../operations/rebuild.md)を参照する。

## System generation

[`flake.nix`](../../flake.nix)は、`module.nix`を持つdirectoryを[`checks/impl/collect-units.nix`](../../checks/impl/collect-units.nix)で収集し、NixOS-WSL、sops-nix、Home Managerと同じNixOS評価へ渡す。machine固有の選択は[`profiles/workstation.nix`](../../profiles/workstation.nix)に集約する。

```text
checkout
   │  flake evaluation、build
   ▼
Nix storeのcandidate system
   │  system profile更新、activation
   ▼
/run/current-system
   ├── /etcとsystem command
   ├── systemd unit
   ├── Home Managerのuser配備
   └── current generationのdoctor command
```

通常の適用入口は`dotfiles-rebuild`だけである。[`workstation/activation/rebuild/module.nix`](../../workstation/activation/rebuild/module.nix)はPATH上の直接の`nixos-rebuild`を拒否し、未commitの変更、candidate build、WSL再起動要否を同じ手順で扱う。世代とrollbackはNixOSが所有する。

`/run/current-system`は実行中のgeneration、`/nix/var/nix/profiles/system`はsystem profile、`/run/booted-system`はWSL起動時のgenerationを表す。`wsl.conf`とactivation interfaceの差分に応じて、live switchとWSL cold startを分ける。

## 責務root

| Root | 所有する責務 |
|---|---|
| `profiles/` | machineが選択するidentity、Agent client、Skill、Capability、language server |
| `workstation/` | user、WSL、Nix、Home Manager、font、storage、安定性、activation |
| `identity/` | Git authorとGitHub account identity |
| `secrets/` | secretの意味的なroot。SOPS実装は`secrets/sops/` |
| `toolchain/` | PATH上の開発ツール、language server、Git設定、dev shell |
| `agents/` | Agent client、role、policy、runtime、delegation、Skill配備 |
| `skills/` | task procedureとSkill間・Capabilityへの依存metadata |
| `capabilities/` | consumer非依存の機能contract、provider adapter、backend、state、credential、lifecycle |
| `platform/` | provider・application非依存のMCP、container、CLI builder |
| `managed-artifacts/` | 生成artifactの型、配備先、drift observationへの投影 |
| `health/` | runtime observation registryと`dotfiles-doctor` |
| `telemetry/` | Agent利用量のOpenTelemetry収集 |
| `maintenance/` | 明示的なcleanup操作 |
| `checks/` | root間の依存、option owner、構造、文書などの横断制約 |
| `docs/` | 利用者向け手順、設計、参照情報 |

unitのmarkerは`module.nix`である。buildは`package.nix`または`package/`、unit固有の検証は`checks.nix`または`checks/`に置く。`impl/`、`assets/`、`fixtures/`、`skill/`は、それぞれ実装、入力資材、検査入力、配備するSkill本文だけを持つ。

## 依存方向

Agentのtask routingはSkillから始める。Skillは必要なCapability IDと、合成する別Skill IDだけを宣言する。Capabilityはprovider名やbackend名を隠す安定した意味境界であり、現在のconsumer数では分割しない。

```text
profiles
   ├── workstation / identity / toolchain
   └── agents ──► skills ──► capabilities ──► platform
                                      ├──────► provider adapter
                                      └──────► backend / credential / state

producer ──► managed-artifacts ──► health
owner    ────────────────────────► health
maintenance ──► platform CLI builder
checks ──► root間contractだけを検証
```

禁止する依存は次の通り。

- CapabilityからAgentまたはSkillへの逆依存
- genericな`platform/mcp/`にprovider IDを列挙すること
- genericな`platform/containers/`にapplication IDを列挙すること
- rootをまたいで別ownerの`impl/`や`assets/`を非公開contractとして読むこと
- profileでMCP providerやcontainer backendを直接選ぶこと

CapabilityがPlatformのpure builderを使う場合は、正本pathを明示してimportする。実行時の値は型付きoptionを介す。

## Option contract

repository固有optionはownerに対応するnamespaceへ置く。

- `dotfiles.workstation`
- `dotfiles.identity.github.accounts`
- `dotfiles.agents`
- `dotfiles.skills`
- `dotfiles.capabilities`
- `dotfiles.platform.mcp`
- `dotfiles.platform.containers`
- `dotfiles.platform.cli.commands`
- `dotfiles.managedArtifacts`
- `dotfiles.health.observations`
- `dotfiles.telemetry`
- `dotfiles.toolchain`

`profiles/workstation.nix`が`dotfiles.capabilities.enabled`をsemantic IDで選ぶ。[`capabilities/module.nix`](../../capabilities/module.nix)は依存closureを求め、MCP provider rosterとcontainer backend rosterを導出する。providerとbackendの一覧をprofileへ重複して書かない。

`dotfiles.skills.registry`は各[`skills/`](../../skills) unitが登録する`source`、`requiresSkills`、`requiresCapabilities`を持つ。Agent clientはregistryから有効なSkillだけを配備し、Skill本文以外のmodule metadataをclientのSkill directoryへ写さない。

## Capability実装

| Capability | 現在の実装 |
|---|---|
| `browser-runtime` | Chromium |
| `browser-automation` | Playwright MCP |
| `browser-diagnostics` | Chrome DevTools MCP |
| `repository-search` | Zvec-Grep MCP |
| `web-discovery` | SearXNG MCPとbackend |
| `web-content` | Crawl4AI MCPとbackend |
| `library-documentation` | Context7 MCP |
| `github-resources` | GitHub MCPとaccount credential |
| `project-memory` | AgentMemory MCP、backend、client integration |
| `code-quality` | SonarQube MCP、server、database、provisioning |
| `agent-session` | Codex runtime contractとMCP adapter |

MCP targetの型、front生成、gatewayは[`platform/mcp/`](../../platform/mcp)が所有する。container service contract、OCI image inventory、Docker network、image同期は[`platform/containers/`](../../platform/containers)が所有する。application固有のserver、database、credential、volume、health endpointは対応するCapability内に置く。

Chromium packageは`browser-runtime`が一度だけ決め、PlaywrightとChrome DevToolsが共有する。SonarQubeはserver、database、provisioning、MCPを別unitにし、server endpoint、DB lifecycle、admin操作、MCP adapterの変更理由を混ぜない。

## Artifact、health、command

JSON、TOML、YAMLの設定は、配備を担当するmoduleが一度だけ生成する。同じimmutable sourceを`/etc`、Home Manager、SOPS template、OCI volume、`dotfiles.managedArtifacts`へ渡す。配備先を持つartifactはsourceとのdriftを`dotfiles.health.observations`へ投影する。

[`health/impl/observation-registry.nix`](../../health/impl/observation-registry.nix)はobservation kindを閉じた型として定義する。各ownerが実状態の意味と期待値を登録し、[`health/module.nix`](../../health/module.nix)がregistry全体を`dotfiles-doctor`へ投影する。doctorは観測だけを行い、再起動、GC、trim、修復は行わない。

[`platform/cli/module.nix`](../../platform/cli/module.nix)は生成commandのregistryを持つ。commandを所有するunitは[`platform/cli/impl/mk-command.nix`](../../platform/cli/impl/mk-command.nix)を明示的にimportする。適用は`workstation/activation/`、診断は`health/`、cleanupは`maintenance/`、container image同期は`platform/containers/`が所有する。

## Secretとruntime state

SOPS暗号文は[`secrets/sops/assets/secrets.yaml`](../../secrets/sops/assets/secrets.yaml)に置く。sops-nixがactivation時にhost keyで復号し、復号済みsecretとtemplateはruntimeにだけ生成する。GitHub account identityは`identity/`、application credentialは対応するCapabilityが所有する。

mutableなruntime stateをNix宣言へ逆輸入しない。NixOSまたはHome Managerの生成先を直接編集しても正本は変わらず、次のactivationで上書きされる。Claude CodeとCodexのuser-owned seed config、OMPの`config.yml`と`agent.db`は利用者またはclientが所有し、artifact drift観測から除外する。
