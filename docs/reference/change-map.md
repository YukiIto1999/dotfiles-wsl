# 変更箇所

**読み手:** 変更する値の正本と検証入口を探す保守者。作業前に読む。

同じ目的に複数の設定経路を作らない。profileは有効な機能を選び、各ownerのmoduleは意味、実装、runtime contractを持つ。変更後の通常適用は`dotfiles-rebuild --plan`、`dotfiles-rebuild`、`dotfiles-doctor`の順で行う。変更がこのrepositoryに属するか、architecture-standard、upstream、対象projectに属するかは`environment-design` Skillで決める。

## Workstationとtoolchain

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| 全hostで有効なidentity、Agent、Capability、language serverを変える | [`profiles/workstation.nix`](../../profiles/workstation.nix) | `verify`、`verify-push`、`dotfiles-rebuild --plan` |
| hostを登録し、WSL資源、登録名、DNS、追加drive、VHD、Nix並列度とreserveを変える | [`profiles/hosts/`](../../profiles/hosts)と、[`workstation/wsl/module.nix`](../../workstation/wsl/module.nix)、[`workstation/storage/module.nix`](../../workstation/storage/module.nix)、[`workstation/nix/module.nix`](../../workstation/nix/module.nix)のowner option | `wsl-host-policy-contract`、`machine-profile-contract`、対象hostのtoplevel、`dotfiles-wsl-config` |
| swap、Windows committed memory、日誌の機械名と自動処理、host固有Capabilityを変える | [`profiles/hosts/`](../../profiles/hosts)と各ownerの型付きoption | `machine-profile-contract`、`agent-journal-behavior`、`container-capability-gating`、対象hostのtoplevel |
| username、home、checkout path、環境系repositoryの置き場所を変える | [`workstation/module.nix`](../../workstation/module.nix)の`dotfiles.workstation` | identity migrationとして扱い、通常rebuildと混ぜない |
| Nix binary cacheを増減する | [`workstation/nix/assets/nix-caches.nix`](../../workstation/nix/assets/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 時刻とlocaleを変える | [`workstation/locale/module.nix`](../../workstation/locale/module.nix) | `host-locale-contract`、`dotfiles-rebuild` |
| PATH上の汎用toolを増減する | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| BashやAtuinなどHome Managerのprogramを変える | [`workstation/home/module.nix`](../../workstation/home/module.nix)の`programs` | 新しいshellでの操作確認、`dotfiles-rebuild` |
| language serverの登録を足す、直す、またはhostの採用集合を変える | 登録は[`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.lspRegistry`、採用は[`profiles/workstation.nix`](../../profiles/workstation.nix)の`dotfiles.toolchain.enabledLsp`。client形式への写像は[`agents/clients/`](../../agents/clients)のadapter | `lsp-command-present`、`lsp-selection`、`lsp-registration`、`dotfiles-rebuild` |
| 検証の段の入口名と宣言の置き場、nativeな検査の取消を変える | [`toolchain/verification/`](../../toolchain/verification)。native programmeの組み立ては[`package.nix`](../../toolchain/verification/package.nix)、段の意味と予算を決める手順はarchitecture-standard | `verification-entry-resolution`、`verification-run-within`、`verification-run-each`、`agent-verification-cache`、`git-pre-push-verification`、`dotfiles-rebuild` |
| T1の評価器の分割、同時に走らせる数、評価器のGC設定を変える | [`flake.nix`](../../flake.nix)の`t1Shards`、`t1Evaluators`、`t1EvaluatorHeapBytes`。同時実行の実装は[`run-each.sh`](../../toolchain/verification/impl/run-each.sh) | `verification-run-each`、`verify`。評価器ごとのCPU時間とRSSを測り、全unitの検査と全host・variantの評価が`verify.seconds`の範囲に残ることを確かめる |
| T1とT2の時間予算を変える | rootの[`verification-budget.json`](../../verification-budget.json)の`verify.seconds`と`verify-push.seconds`。[`flake.nix`](../../flake.nix)、`dotfiles-agent-verify`、pre-pushが同じfileを読む。決定の手順は[開発手順](../operations/development.md) | `verify`、`git-pre-push-verification`。必要な範囲を完走した時間、cache、資源と余裕の理由を記録して値を決める |
| Gitの共通除外を変える | [`toolchain/git/assets/ignore`](../../toolchain/git/assets/ignore)。適用範囲と例外は[Gitの追跡対象](../architecture/security.md#git-の追跡対象) | `git-hook-dispatch`、`git-global-ignore-immutable`、`dotfiles-rebuild`。配備済みのignoreはgenerationのstore複製なので、反映にrebuildが必要で、checkoutだけの編集では変わらない |
| Git hookの種類、dotfilesの検査、repositoryのhookへの連鎖、push前の検証の予算を変える | [`toolchain/git/package.nix`](../../toolchain/git/package.nix)、[`toolchain/git/module.nix`](../../toolchain/git/module.nix)、[`toolchain/git/assets/hooks/`](../../toolchain/git/assets/hooks)。手順は[Git hook](../operations/git-hooks.md) | `git-hook-dispatch`、`git-pre-push-verification`、`git-commit-message-contract`、`git-pre-commit-leak-contract`、`dotfiles-rebuild` |
| 使用量の観測先を変える | [`telemetry/module.nix`](../../telemetry/module.nix) | 対応するtelemetry check、`dotfiles-rebuild` |

## Repository structure

| 変更 | 正本 | 検証・適用 |
|---|---|---|
| top-level responsibilityを追加・削除する | [`docs/architecture/overview.md`](../architecture/overview.md)でownerと依存方向を決め、rootの`module.nix`を入口にする | `structure-responsibility-roots`、`unit-boundary-name-only` |
| Capabilityを追加・削除する | [`capabilities/module.nix`](../../capabilities/module.nix)のregistry、`capabilities/<semantic-id>/module.nix`、[`profiles/workstation.nix`](../../profiles/workstation.nix)または[`profiles/hosts/`](../../profiles/hosts)の選択 | dependency closureとprovider/backend一意性を`verify`で確認する |
| Skillを追加・削除する | localは[`skills/<id>/`](../../skills)のmoduleと`skill/`、外部sourceは[`skills/plugins/module.nix`](../../skills/plugins/module.nix)の採用表。依存metadataとcallerのroutingを同時に変える | Skill renderingとrequired Capabilityのcheck |
| 外部Skillを採用し、同IDの供給元を差し替える | 採用moduleのregistry.sourceと明示的なoverride。source内の任意directoryを直接指し、原名のID、本文、reference、scriptを変換しない | `skill-source-contract`、`skill-frontmatter-contract`、`skill-capability-gating` |
| Orca、Matt、.NET、Modern Web guidanceのsource版を更新する | [`flake.nix`](../../flake.nix)の該当inputと[`flake.lock`](../../flake.lock)でGit revisionを固定する。採用pathと依存、guide資材の公開は[`skills/plugins/module.nix`](../../skills/plugins/module.nix) | 上流の本文、資材、license、依存の差分と`verify`、`verify-push`を確認し、承認後に`dotfiles-rebuild` |
| architecture-standardの運用Skill、checker、設定の実行packageの更新経路を変える | [`workstation/activation/rebuild/impl/rebuild.sh`](../../workstation/activation/rebuild/impl/rebuild.sh)が`dotfiles-rebuild`のたびに`architectureStandard`を最新へ更新して`flake.lock`をcommitする。[`flake.lock`](../../flake.lock)は配備したrevisionの記録であり、[`flake.nix`](../../flake.nix)のURLにはrevを書かない。採用pathと依存は[`skills/plugins/module.nix`](../../skills/plugins/module.nix)。判断は[ADR 0015](../adr/0015-follow-the-latest-standard-package-at-rebuild.md) | `rebuild-entrypoint`と`dotfiles-rebuild --plan`。標準の統合後は同じ作業で`dotfiles-rebuild`まで実行する。lockの更新は現行規範への適合を示さず、規範本文は現行規範rootで確かめる |
| Chrome DevToolsのruntimeと同梱Skillの版を更新する | [`flake.nix`](../../flake.nix)の`chromeDevtoolsMcp` archive URLと[`flake.lock`](../../flake.lock)、[`package-lock.json`](../../capabilities/browser-diagnostics/chrome-devtools/mcp/package/package-lock.json)、[`package.nix`](../../capabilities/browser-diagnostics/chrome-devtools/mcp/package.nix)の`npmDepsHash`。採用Skillのpathは[`skills/plugins/module.nix`](../../skills/plugins/module.nix) | archiveと依存lockを同じ版へ更新し、package buildと採用Skillの契約を確認する。runtimeはCapabilityがflake inputを直接参照し、Skill registryを経由しない |
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
| Web検索とURL取得の入口、subagentのWeb tool許可を変える | [`skills/web-research/skill/`](../../skills/web-research/skill)、subagentの`tools`は[`agents/subagents/`](../../agents/subagents)、client別の変換は各[`agents/clients/<id>/module.nix`](../../agents/clients)、公開状況の表は[AI tooling](../architecture/ai-tooling.md#web調査) | `agent-subagent-rendering`、`skill-capability-gating`、`skill-frontmatter-contract` |
| project memoryのruntime、client integration、engine、MCP、backendを変える | [`capabilities/project-memory/hindsight/`](../../capabilities/project-memory/hindsight/)とgeneric optionを宣言するCapability module | `project-memory-runtime-behavior`、`project-memory-client-integrations`、`hindsight-container`、`hindsight-front` |
| Hindsightの抽出modelまたはretain missionを変える | modelは[`capabilities/project-memory/hindsight/backend/module.nix`](../../capabilities/project-memory/hindsight/backend/module.nix)の`hindsight.env`、retain missionは[`capabilities/project-memory/hindsight/runtime/package/memory.py`](../../capabilities/project-memory/hindsight/runtime/package/memory.py) | 保存済みの代表的な記憶で`memories/dry-run-extract`を比べ、`hindsight-container`、`project-memory-runtime-behavior`、`dotfiles-rebuild` |
| Strixのnative CLI、sandbox image、provider設定、所有runの回収を変える | [`capabilities/security-assessment/strix/runtime/`](../../capabilities/security-assessment/strix/runtime/)と[`security-review`の利用契約](../../skills/security-review/skill/references/strix-runtime.md)。常駐MCPやbackendを作らず、共通CLIと`runtimeImages`から配備する | `strix-runtime-behavior`で取消、所有process group、私有configの回収と正対照を確認する。実際のCLI、資格情報を使わないhelp、所有runだけのinspect/cleanupを観測し、model接続とassessmentの受入は別に記録する |
| SonarQubeのbackend、公式MCP、scanner、取得した証拠の適用条件を変える | [`capabilities/code-quality/`](../../capabilities/code-quality/)と[`code-quality` Skill](../../skills/code-quality/skill/SKILL.md)。通常reviewのcaller側接続は[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)と[`reviewer`](../../agents/subagents/reviewer.md)が所有する | `sonarqube-scan-evidence`、`container-argv-contract`、実scanner→CE完了→公式MCPのissues/gate取得、適用後のdoctor |
| session、build cache、verification reuseを変える | [`agents/impl/runtime/`](../../agents/impl/runtime)と[`agents/module.nix`](../../agents/module.nix) | 対応するruntime focused check |
| 現行規範rootの導出と案内、gateの規範rootと実行packageの検証を変える | `dotfiles.agents.runtime.standardRoot`の宣言は[`agents/module.nix`](../../agents/module.nix)、policyの`@standardRoot@`は[`agents/impl/policy.nix`](../../agents/impl/policy.nix)と[`agents/policy/AGENTS.md`](../../agents/policy/AGENTS.md)、`dotfiles-agent-gate standard-root`と`conformance`は[`agents/impl/runtime/gate.sh`](../../agents/impl/runtime/gate.sh)。規範本文はowner checkoutが所有し、このrepositoryへ複製しない | `agent-runtime-contract`、`agent-skill-read-gate`、`agent-omp-verification-gate-hook`。規範本文だけを変えた状態と実行packageを固定した状態で、receiptの失効とpackageの識別を確かめる |
| session中に作ったlinked worktreeの記録と回収を変える | [`agents/impl/runtime/git.sh`](../../agents/impl/runtime/git.sh)と[`agents/impl/runtime/launcher.sh`](../../agents/impl/runtime/launcher.sh) | `agent-runtime-behavior` |
| agent sessionの資源上限、nixのbuild並列度を変える | [`agents/module.nix`](../../agents/module.nix)の`agents.slice`と`dotfiles.agents.slice`、[`agents/impl/runtime/launcher.sh`](../../agents/impl/runtime/launcher.sh)、[`workstation/nix/module.nix`](../../workstation/nix/module.nix) | `agent-runtime-behavior`、`agent-runtime-contract`、`dotfiles-rebuild` |
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
| upstream OCI imageを更新する | 常駐applicationはCapability実装の`dotfiles.platform.containers.services.<name>.images`、必要時だけ使うsandboxは`dotfiles.platform.containers.runtimeImages`のdigest固定参照 | imageを選択した対象hostで、checkoutから`nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status`または`nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages`を実行し、適用後は同hostの`dotfiles-sync-images`と`dotfiles-rebuild`を使う |
| Capability実装が取得するpackageのhashを更新する | 対応するCapabilityの`package.nix`。flake inputのarchive hashは[`flake.lock`](../../flake.lock) | `nix store prefetch-file --hash-type sha256 --json <url>`、`verify`、`verify-push` |

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
| containerのcgroup配置と上限を変える | [`platform/containers/`](../../platform/containers) | `container-cgroup-placement`、`container-placement-observation-behavior`、rebuild後のdoctorの`container-placement` |
