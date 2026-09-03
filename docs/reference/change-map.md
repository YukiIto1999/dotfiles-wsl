# 変更箇所

**読み手:** 変更する値の正本と検証入口を探す保守者。作業前に読む。

同じ目的に複数の設定経路を作らない。profileは有効な機能を選び、各ownerのmoduleは意味、実装、runtime contractを持つ。変更後の通常適用は`dotfiles-rebuild --plan`、`dotfiles-rebuild`、`dotfiles-doctor`の順で行う。

## Workstationとtoolchain

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| 有効なidentity、Agent、Skill、Capability、language serverを変える | [`profiles/workstation.nix`](../../profiles/workstation.nix) | `nix flake check`、`dotfiles-rebuild --plan` |
| username、home、checkout pathを変える | [`workstation/module.nix`](../../workstation/module.nix)の`dotfiles.workstation` | identity migrationとして扱い、通常rebuildと混ぜない |
| Nix binary cacheを増減する | [`workstation/nix/assets/nix-caches.nix`](../../workstation/nix/assets/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| PATH上の汎用toolを増減する | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| language serverを増減する | [`toolchain/module.nix`](../../toolchain/module.nix)のregistryと[`profiles/workstation.nix`](../../profiles/workstation.nix)の選択。client形式への写像は[`agents/impl/lsp.nix`](../../agents/impl/lsp.nix) | `lsp-registration`、`dotfiles-rebuild` |
| 使用量の観測先を変える | [`telemetry/module.nix`](../../telemetry/module.nix) | 対応するtelemetry check、`dotfiles-rebuild` |

## Repository structure

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| top-level responsibilityを追加・削除する | [`docs/architecture/overview.md`](../architecture/overview.md)でownerと依存方向を決め、rootの`module.nix`を入口にする | `structure-responsibility-roots`、`unit-boundary-name-only` |
| Capabilityを追加・削除する | [`capabilities/module.nix`](../../capabilities/module.nix)のregistry、`capabilities/<semantic-id>/module.nix`、[`profiles/workstation.nix`](../../profiles/workstation.nix) | dependency closureとprovider/backend一意性を`nix flake check`で確認する |
| Skillを追加・削除する | [`skills/`](../../skills)の`module.nix`、`skill/`、依存metadata。profileはregistry名から有効化する | Skill renderingとrequired Capabilityのcheck |
| repository横断制約を変える | [`checks/checks/`](../../checks/checks)と[`checks/impl/`](../../checks/impl) | 変更したcheckを意図的に失敗させてから戻す |

## Runtime observationと生成artifact

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| observation kindまたは共通fieldを変える | [`health/module.nix`](../../health/module.nix)のclosed unionと[`health/impl/probe.sh`](../../health/impl/probe.sh) | `observation-contract`、`doctor-runtime`、`dotfiles-doctor` |
| ownerの検査対象、閾値、failure messageを変える | 対象ownerが`dotfiles.health.observations`へ登録する宣言 | ownerのruntime observation check、`dotfiles-doctor` |
| observationの実行順、timeout、出力集約を変える | [`health/module.nix`](../../health/module.nix)、[`health/impl/doctor.sh`](../../health/impl/doctor.sh) | `doctor-coverage`、`doctor-runtime` |
| 生成artifactの配備先、owner、mode、drift観測を変える | [`managed-artifacts/module.nix`](../../managed-artifacts/module.nix)の`dotfiles.managedArtifacts`と登録owner | `managed-artifact-*`、`dotfiles-doctor` |
| 利用者向けcommandを追加する | owner moduleから[`platform/cli/impl/mk-command.nix`](../../platform/cli/impl/mk-command.nix)を使い`dotfiles.platform.cli.commands`へ登録する | command固有check、`dotfiles-rebuild` |

## Agent client

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| Agent clientの設定または配備形式を変える | [`agents/clients/<id>/`](../../agents/clients)と[`agents/module.nix`](../../agents/module.nix) | client固有check、`dotfiles-rebuild` |
| client binaryの供給経路を変える | clientの`install` contract。複数consumerが共有するCodexは[`capabilities/agent-session/codex/`](../../capabilities/agent-session/codex) | `agent-client-roster`、installer checks、`dotfiles-install-agents` |
| roleを追加・変更する | [`agents/roles/`](../../agents/roles)と[`agents/roles/routing.nix`](../../agents/roles/routing.nix) | `agent-definition-rendering` |
| AgentMemoryのclient integration、engine、MCP、backendを変える | [`capabilities/project-memory/agentmemory/`](../../capabilities/project-memory/agentmemory) | `agentmemory-client-integration`とbackend/MCP checks |
| session、build cache、verification reuseを変える | [`agents/impl/runtime/`](../../agents/impl/runtime)と[`agents/module.nix`](../../agents/module.nix) | 対応するruntime focused check |
| linked worktreeの登録と回収を変える | [`agents/impl/resource/`](../../agents/impl/resource)と[`agents/module.nix`](../../agents/module.nix) | `agent-resource-contract`、`agent-resource-behavior` |

## MCP、container、Capability実装

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| MCP providerまたはtargetを追加・削除する | 対応する[`capabilities/<id>/`](../../capabilities)実装が`dotfiles.platform.mcp.targets`へ登録する。Capability registryとprofileを同じ変更に含める | target、probe、Capability closureのcheck |
| MCP frontのtransport、lifecycle、port、backend依存を変える | 対応するCapabilityのMCP adapter。front生成は[`platform/mcp/module.nix`](../../platform/mcp/module.nix) | adapter固有check、`dotfiles-rebuild --plan` |
| gatewayのport、YAML、protocol観測を変える | [`platform/mcp/gateway/`](../../platform/mcp/gateway) | gateway checks、`dotfiles-doctor` |
| container共通schema、network、image同期を変える | [`platform/containers/module.nix`](../../platform/containers/module.nix)と[`platform/containers/impl/container-backend.nix`](../../platform/containers/impl/container-backend.nix) | Platform container checks、`dotfiles-rebuild` |
| application backend、endpoint、volumeを変える | 対応するCapability内のbackend/server/database unit | Capability固有check、`dotfiles-doctor` |
| upstream OCI imageを更新する | Capability実装の`dotfiles.platform.containers.services.<name>.images`にあるrepository、digest、canonical reference | `nix run .#dotfiles-sync-images -- --status`、`nix run .#dotfiles-sync-images`、`dotfiles-rebuild` |
| 固定packageのhashを更新する | 対応するCapabilityの`package.nix` | `nix store prefetch-file --hash-type sha256 --json <url>`、`nix flake check` |
| SonarQube server、database、provisioning、MCPを変える | [`capabilities/code-quality/sonarqube/`](../../capabilities/code-quality/sonarqube)の各unit | 対応するSonarQube check、credential変更時は[Secrets](../operations/secrets.md#sonarqube-admin-password-rotation) |

## Secretとidentity

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| default Git identityを変える | [`identity/module.nix`](../../identity/module.nix)のtemplateと[`secrets/sops/assets/secrets.yaml`](../../secrets/sops/assets/secrets.yaml) | host keyを指定してSOPSで編集し、`dotfiles-rebuild` |
| work identityの対象と値を変える | [`toolchain/git/module.nix`](../../toolchain/git/module.nix)、[`identity/module.nix`](../../identity/module.nix)、暗号化済みsecret | `dotfiles-rebuild` |
| GitHub accountを増減する | [`profiles/workstation.nix`](../../profiles/workstation.nix)の`dotfiles.identity.github.accounts`、[`identity/module.nix`](../../identity/module.nix)、[`capabilities/github-resources/github/`](../../capabilities/github-resources/github)、暗号化済みsecret | rosterと暗号化済み値を同じ変更に含める |
| application credentialを追加・変更する | 対応するCapabilityの`sops.secrets`とtemplate、[`secrets/sops/assets/secrets.yaml`](../../secrets/sops/assets/secrets.yaml) | host keyを指定してSOPSで編集し、`dotfiles-rebuild` |
| host recipientを追加する | [`secrets/sops/assets/.sops.yaml`](../../secrets/sops/assets/.sops.yaml) | [SOPSの鍵](../operations/sops-enrollment.md)に従う |

通常のsecret編集commandは次の形に統一する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config ~/dotfiles-wsl/secrets/sops/assets/.sops.yaml \
  ~/dotfiles-wsl/secrets/sops/assets/secrets.yaml
```

## 運用入口

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| rebuildのpreflight、lock、restart判定を変える | [`workstation/activation/rebuild/`](../../workstation/activation/rebuild) | rebuild focused checks、`dotfiles-rebuild --plan` |
| cleanup対象を変える | [`maintenance/`](../../maintenance) | cleanup contract、対象なしのdry run |
| OCI image同期を変える | [`platform/containers/`](../../platform/containers) | image sync checks、`dotfiles-sync-images --status` |
