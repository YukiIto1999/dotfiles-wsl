# 変更箇所

**読み手:** 変更する値の正本と検証入口を探す保守者。作業前に読む。

同じ目的に複数の設定経路を作らない。profileは有効な機能を選び、各ownerのmoduleは意味、実装、runtime contractを持つ。変更後の通常適用は`dotfiles-rebuild --plan`、`dotfiles-rebuild`、`dotfiles-doctor`の順で行う。変更がこのrepositoryに属するか、architecture-standard、upstream、対象projectに属するかは`environment-design` Skillで決める。

## Workstationとtoolchain

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| 全hostで有効なidentity、Agent、Capability、language serverを変える | [`profiles/workstation.nix`](../../profiles/workstation.nix) | `nix flake check`、`dotfiles-rebuild --plan` |
| hostを登録し、swap、Windows committed memory、host固有Capabilityを変える | [`profiles/hosts/`](../../profiles/hosts)のhost名と同じNix file。optionの意味と既定値は[`workstation/stability/module.nix`](../../workstation/stability/module.nix)、[`capabilities/module.nix`](../../capabilities/module.nix) | `machine-profile-contract`、`container-capability-gating`、対象hostのtoplevel check、`dotfiles-rebuild --plan` |
| username、home、checkout path、環境系repositoryの置き場所を変える | [`workstation/module.nix`](../../workstation/module.nix)の`dotfiles.workstation` | identity migrationとして扱い、通常rebuildと混ぜない |
| Nix binary cacheを増減する | [`workstation/nix/assets/nix-caches.nix`](../../workstation/nix/assets/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 時刻とlocaleを変える | [`workstation/locale/module.nix`](../../workstation/locale/module.nix) | `host-locale-contract`、`dotfiles-rebuild` |
| PATH上の汎用toolを増減する | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| language serverを増減する | [`toolchain/module.nix`](../../toolchain/module.nix)のregistryと[`profiles/workstation.nix`](../../profiles/workstation.nix)の選択。client形式への写像は[`agents/impl/lsp.nix`](../../agents/impl/lsp.nix) | `lsp-registration`、`dotfiles-rebuild` |
| 使用量の観測先を変える | [`telemetry/module.nix`](../../telemetry/module.nix) | 対応するtelemetry check、`dotfiles-rebuild` |

## Repository structure

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| top-level responsibilityを追加・削除する | [`docs/architecture/overview.md`](../architecture/overview.md)でownerと依存方向を決め、rootの`module.nix`を入口にする | `structure-responsibility-roots`、`unit-boundary-name-only` |
| Capabilityを追加・削除する | [`capabilities/module.nix`](../../capabilities/module.nix)のregistry、`capabilities/<semantic-id>/module.nix`、[`profiles/workstation.nix`](../../profiles/workstation.nix)または[`profiles/hosts/`](../../profiles/hosts)の選択 | dependency closureとprovider/backend一意性を`nix flake check`で確認する |
| Skillを追加・削除する | [`skills/`](../../skills)の`module.nix`、`skill/`、依存metadata。配備対象は有効なCapabilityから導く | Skill renderingとrequired Capabilityのcheck |
| plugin Skill sourceとarchitecture-standardの版を更新する | [`flake.nix`](../../flake.nix)の該当inputのrevと[`flake.lock`](../../flake.lock)。採用するSkillは[`skills/plugins/module.nix`](../../skills/plugins/module.nix) | 固定していた版からの差分を確認し、`nix flake check`、`dotfiles-rebuild` |
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
| clientの`projectMemoryMode`または`capabilityManagedFiles.projectMemory`を変える | [`agents/impl/contract.nix`](../../agents/impl/contract.nix)と各[`agents/clients/<id>/module.nix`](../../agents/clients)のmode・managed file宣言 | `project-memory-client-integrations`、`agent-artifact-contract` |
| client binaryの供給経路を変える | clientの`install` contract | `agent-client-roster`、installer checks、`dotfiles-install-agents` |
| subagentを追加・変更する | `agents/subagents/`と[`agents/subagents/routing.nix`](../../agents/subagents/routing.nix) | `agent-subagent-rendering` |
| project memoryのruntime、client integration、engine、MCP、backendを変える | [`capabilities/project-memory/hindsight/`](../../capabilities/project-memory/hindsight/)とgeneric optionを宣言するCapability module | `project-memory-runtime-behavior`、`project-memory-client-integrations`、`hindsight-container`、`hindsight-front` |
| Hindsightの抽出modelまたはretain missionを変える | modelは[`capabilities/project-memory/hindsight/backend/module.nix`](../../capabilities/project-memory/hindsight/backend/module.nix)の`hindsight.env`、retain missionは[`capabilities/project-memory/hindsight/runtime/package/memory.py`](../../capabilities/project-memory/hindsight/runtime/package/memory.py) | 保存済みの代表的な記憶で`memories/dry-run-extract`を比べ、`hindsight-container`、`project-memory-runtime-behavior`、`dotfiles-rebuild` |
| session、build cache、verification reuseを変える | [`agents/impl/runtime/`](../../agents/impl/runtime)と[`agents/module.nix`](../../agents/module.nix) | 対応するruntime focused check |
| linked worktreeの登録と回収を変える | [`agents/impl/resource/`](../../agents/impl/resource)と[`agents/module.nix`](../../agents/module.nix) | `agent-resource-contract`、`agent-resource-behavior` |
| 作業日誌の時間帯、model、入力、出力先を変える | [`agents/journal/`](../../agents/journal) | `agent-journal-behavior`、session記録の読み方とmodelの呼び方を変えた場合は`agent-memory-harvest-behavior`、`dotfiles-rebuild` |
| 記憶の収穫の対象、判定の梯子、model、時刻、state fileを変える | [`agents/memory-harvest/`](../../agents/memory-harvest)。保存と一覧の契約は[`capabilities/project-memory/hindsight/runtime/`](../../capabilities/project-memory/hindsight/runtime/) | `agent-memory-harvest-behavior`、`project-memory-runtime-behavior`、`dotfiles-rebuild` |

## MCP、container、Capability実装

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| MCP providerまたはtargetを追加・削除する | 対応する[`capabilities/<id>/`](../../capabilities)実装が`dotfiles.platform.mcp.targets`へ登録する。Capability registryとprofileを同じ変更に含める | target、probe、Capability closureのcheck |
| MCP frontのtransport、lifecycle、port、backend依存を変える | 対応するCapabilityのMCP adapter。front生成は[`platform/mcp/module.nix`](../../platform/mcp/module.nix) | adapter固有check、`dotfiles-rebuild --plan` |
| gatewayのport、YAML、protocol観測を変える | [`platform/mcp/gateway/`](../../platform/mcp/gateway) | gateway checks、`dotfiles-doctor` |
| container共通schema、network、image同期を変える | [`platform/containers/module.nix`](../../platform/containers/module.nix)と[`platform/containers/impl/container-backend.nix`](../../platform/containers/impl/container-backend.nix) | Platform container checks、`dotfiles-rebuild` |
| application backend、endpoint、volumeを変える | 対応するCapability内のbackend/server/database unit | Capability固有check、`dotfiles-doctor` |
| hostでcontainer applicationを有効化・無効化する | [`profiles/hosts/`](../../profiles/hosts)の`dotfiles.capabilities.enabled`。container名ではなく所有するCapability IDを選ぶ | `container-capability-gating`、対象hostのtoplevel check、`dotfiles-rebuild --plan` |
| upstream OCI imageを更新する | Capability実装の`dotfiles.platform.containers.services.<name>.images`にあるrepository、digest、canonical reference | containerを有効にした対象hostで、checkoutから`nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status`または`nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages`を実行し、適用後は同hostの`dotfiles-sync-images`と`dotfiles-rebuild`を使う |
| 固定packageのhashを更新する | 対応するCapabilityの`package.nix` | `nix store prefetch-file --hash-type sha256 --json <url>`、`nix flake check` |

## Secretとidentity

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| default Git identityを変える | [`identity/module.nix`](../../identity/module.nix)のtemplateと[`secrets/sops/assets/secrets.json`](../../secrets/sops/assets/secrets.json) | host keyを指定してSOPSで編集し、`dotfiles-rebuild` |
| work identityの対象と値を変える | [`toolchain/git/module.nix`](../../toolchain/git/module.nix)、[`identity/module.nix`](../../identity/module.nix)、暗号化済みsecret | `dotfiles-rebuild` |
| GitHub accountを増減する | 暗号化済み[`secrets/sops/assets/secrets.json`](../../secrets/sops/assets/secrets.json)の`accounts` | host keyを指定してSOPSで編集し、`dotfiles-rebuild`。宣言側は変えない |
| primary以外のaccountでだけ読めるGitHub ownerの接続先を変える | 暗号化済み[`secrets/sops/assets/secrets.json`](../../secrets/sops/assets/secrets.json)の`accounts/<id>/owners/<owner>`。Git設定の構文は[`toolchain/git/module.nix`](../../toolchain/git/module.nix) | host keyを指定してSOPSで編集し、`account-deployment-contract`、`git-credential-routing`、`dotfiles-rebuild`。宣言側は変えない |
| application credentialを追加・変更する | 対応するCapabilityの`sops.secrets`とtemplate、[`secrets/sops/assets/secrets.json`](../../secrets/sops/assets/secrets.json) | host keyを指定してSOPSで編集し、`dotfiles-rebuild` |
| host recipientを追加する | [`secrets/sops/assets/.sops.yaml`](../../secrets/sops/assets/.sops.yaml) | [SOPSの鍵](../operations/sops-enrollment.md)に従う |

通常のsecret編集commandは、checkoutのrootで実行する次の形に統一する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
```

## 運用入口

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| rebuildのpreflight、lock、restart判定を変える | [`workstation/activation/rebuild/`](../../workstation/activation/rebuild) | rebuild focused checks、`dotfiles-rebuild --plan` |
| cleanup対象を変える | [`maintenance/`](../../maintenance) | cleanup contract、対象なしのdry run |
| OCI image同期を変える | [`platform/containers/`](../../platform/containers) | image sync checks、containerを有効にしたhostの`dotfiles-sync-images --status` |
