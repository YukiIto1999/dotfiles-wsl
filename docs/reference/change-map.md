# 変更箇所

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

生成済みの設定ファイルを直接編集せず、表に示す正本を変更する。値や対象の全一覧はこの文書に固定せず、Nix 宣言から取得する。

## Host

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| ホスト固有の `dotfiles.*` 値を変える | [`flake.nix`](../../flake.nix) の `nixosConfigurations` と、その option を宣言する unit の `module.nix` | 通常の値は `dotfiles-rebuild --plan` で確認してから `dotfiles-rebuild`。`dotfiles.host.username` と `dotfiles.host.dotfilesDir` は host identity migration なので通常 rebuild では変更しない |
| Nix の binary cache を増減する | [`host/assets/nix-caches.nix`](../../host/assets/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 責務を追加または削除する | repo 直下に unit directory を作り `module.nix` を置く。収集は flake が行う。層は `module.nix` `package.nix` `checks.nix` `impl/` `assets/` `fixtures/` `package/` `checks/` `shared/` の名前だけで表し、option は `dotfiles.<root>` に置く | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| PATH 上の汎用ツールを増減する | [`toolchain/module.nix`](../../toolchain/module.nix) の `dotfiles.toolchain.packages`。nixpkgs に無い汎用ツールは `toolchain/package/NAME.nix` を作り、`dotfiles.toolchain.packages` が callPackage する | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| language server を増減する | [`toolchain/module.nix`](../../toolchain/module.nix) の `dotfiles.toolchain.lsp`。client 形式への写像は [`agents/impl/lsp.nix`](../../agents/impl/lsp.nix)、配備は各 client の module | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 使用量の観測先を変える | [`telemetry/module.nix`](../../telemetry/module.nix)。CLI は `dotfiles.telemetry` を読む | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| VM の空き page、compaction、zram、journal 保持、fstrim、Nix の容量 reserve、Windows drive と committed memory の観測を変える | [`host/module.nix`](../../host/module.nix) の host 安定化 contract | `host-stability-contract`、`dotfiles-rebuild --plan`、`dotfiles-rebuild`。zram、swap priority、標準 timer、Windows の資源閾値は `dotfiles-doctor` でも確認する |
| 品質 gate の server、database、provisioning を変える | [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix)。MCP package と target は [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix)、credential の値は [`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) | 宣言変更後に `dotfiles-rebuild`。admin credential の変更は [SonarQube admin password rotation](../operations/secrets.md#sonarqube-admin-password-rotation) に従う |

## Runtime observation

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| observation kind または共通 field を変える | [`observations/module.nix`](../../observations/module.nix) の closed union、[`commands/doctor/impl/probe.sh`](../../commands/doctor/impl/probe.sh) の kind runner | `observation-contract`、`doctor-runtime`、`dotfiles-rebuild`、`dotfiles-doctor` |
| owner の検査対象、閾値、failure message を変える | 対象を所有する unit の `module.nix`。`agents`、`artifacts`、`containers`、`host`、`mcp`、`sops`、`telemetry` が `dotfiles.observations` へ登録する | owner の `*-runtime-observation-contract` または対応する focused check、`dotfiles-rebuild`、`dotfiles-doctor` |
| observation の実行順、timeout、出力集約を変える | [`commands/doctor/module.nix`](../../commands/doctor/module.nix)、[`commands/doctor/impl/doctor.sh`](../../commands/doctor/impl/doctor.sh) | `doctor-coverage`、`doctor-runtime`、`dotfiles-rebuild`、`dotfiles-doctor` |

## Agent client

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| Agent client を追加する | [`agents/NAME/module.nix`](../../agents) を作り `dotfiles.agents.clients.NAME` を宣言する。通常構成と variant の `dotfiles.agents.enabled`、固定 contract fixture も同じ変更で更新する | 新規ファイルを `git add` する。`installer-script` / `github-release` はcheckoutから`nix run .#dotfiles-install-agents`を実行し、`nix-package`はflake inputを固定してから`dotfiles-rebuild` |
| Agent client を管理対象から外す | 対応する [`agents/NAME/`](../../agents) を削除し、host の必要集合と fixture を更新する | `dotfiles-rebuild`。`dotfiles-install-agents` は残存 binary を削除しないため、upstream が配置したファイルは別途削除する |
| client 固有の managed config を変える | 対応する [`agents/NAME/assets/`](../../agents) の template と `module.nix` の最終 `managedFiles` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| client の upstream 入手方法を変える | 対応する [`agents/NAME/module.nix`](../../agents) の `dotfiles.agents.clients.NAME.install`。GitHub release では layout、architecture ごとの asset と entrypoint、`requiredPaths`、`retainedReleases` を同じ contract で更新する。Nix packageは対応flake inputとlockをownerにする | `installer-script` / `github-release`はcheckoutから`nix run .#dotfiles-install-agents`、`nix-package`はinput更新後に`dotfiles-rebuild` |
| agent 専用の補助 package を増減する | [`agents/module.nix`](../../agents/module.nix) の `dotfiles.agents.packages`。nixpkgs に無い package は [`agents/package/`](../../agents/package) に置く | 対応する agent check、`dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| AgentMemory の lifecycle hook または OpenCode plugin を変える | [`agents/agentmemory/`](../../agents/agentmemory)。upstream package と backend は [`containers/agentmemory/`](../../containers/agentmemory) が所有する | `agentmemory-client-integration`、`agentmemory-container`、`dotfiles-rebuild` |
| agent の session、build cache、検証再利用を変える | [`agents/impl/runtime/`](../../agents/impl/runtime) と [`agents/module.nix`](../../agents/module.nix) | 対応する focused check、`dotfiles-rebuild` |
| agent が作る linked worktree の登録と回収を変える | [`agents/impl/resource/`](../../agents/impl/resource) の resource command と [`agents/module.nix`](../../agents/module.nix) の timer contract | `agent-resource-contract`、`agent-resource-behavior`、`dotfiles-rebuild` |

## Agent と skill

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| 共通ルールを変える | [`agents/shared/AGENTS.md`](../../agents/shared/AGENTS.md) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| local skill を追加または変更する | [`agents/shared/skills/NAME/SKILL.md`](../../agents/shared/skills) と [`agents/module.nix`](../../agents/module.nix) の自動検出、immutable source 配備 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| subagent を追加または変更する | [`agents/shared/definitions/NAME.md`](../../agents/shared/definitions) と各 client module の変換 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| plugin 由来の skill を更新する | [`flake.nix`](../../flake.nix) の plugin inputs と [`flake.lock`](../../flake.lock) | input を更新し、`dotfiles-rebuild --plan`、`dotfiles-rebuild` |

## MCP

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| MCP provider または target を追加、削除する | [`flake.nix`](../../flake.nix) の `dotfiles.mcp.enabledProviders` と各 [`mcp/NAME/module.nix`](../../mcp) の `dotfiles.mcp.targets`。target の固定契約は [`mcp/fixtures/target-contract.json`](../../mcp/fixtures/target-contract.json) | provider roster、target、probe を同じ変更に含め、`dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| MCP front の executable、server lifecycle、port、backend 依存を変える | 対応する [`mcp/NAME/module.nix`](../../mcp) の target。port は 8770-8789 から取り、backend unit は `waitUnits` に置く。front と session policy は [`mcp/module.nix`](../../mcp/module.nix) が導く | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| gateway の port または YAML を変える | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `dotfiles.mcp.gateway` と YAML 生成。gateway は単一 endpoint のまま保つ | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| gateway の MCP protocol 観測を変える | [`mcp/gateway/impl/observer.sh`](../../mcp/gateway/impl/observer.sh)、[`mcp/gateway/impl/observer-package.nix`](../../mcp/gateway/impl/observer-package.nix)、[`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `normalized-protocol` observation | `mcp-gateway-observer`、`mcp-runtime-observation-contract`、`dotfiles-rebuild`、`dotfiles-doctor` |
| Docker backend の構成を変える | 対応する [`containers/NAME/module.nix`](../../containers) と [`containers/impl/container-backend.nix`](../../containers/impl/container-backend.nix)。application の追加と削除では [`flake.nix`](../../flake.nix) の enabled roster と [`containers/checks.nix`](../../containers/checks.nix) の固定 roster も同時に変える。共通 schema と image 同期は [`containers/module.nix`](../../containers/module.nix) | Nix で build する image は `dotfiles-rebuild`。upstream image の宣言変更は checkout から同期してから `dotfiles-rebuild` |
| Docker build artifact の回収対象、BuildKit cache の保持量、GC 間隔を変える | [`containers/module.nix`](../../containers/module.nix) の build artifact GC contract | `docker-build-artifact-gc-contract`、`dotfiles-rebuild` |
| upstream OCI image を更新する | 対応する [`containers/NAME/module.nix`](../../containers) の `dotfiles.containers.services.<name>.images` にある repository、digest、canonical image reference。digest は `dotfiles-image-digest <image>` で取る | 宣言変更後に `nix run .#dotfiles-sync-images -- --status`、`nix run .#dotfiles-sync-images`、`dotfiles-rebuild` |
| 固定した package の hash を更新する | 対応する [`mcp/NAME/package.nix`](../../mcp) の hash。値は `nix store prefetch-file --hash-type sha256 --json <url>` で取る | `dotfiles-rebuild` |

## Secret と identity

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| default Git identity を変える | [`accounts/module.nix`](../../accounts/module.nix) の secret と template、[`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) の暗号化済み値 | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| work identity の対象と値を変える | [`flake.nix`](../../flake.nix) の `dotfiles.toolchain.git.workIdentity`、[`toolchain/git/module.nix`](../../toolchain/git/module.nix) の option と consumer、[`accounts/module.nix`](../../accounts/module.nix) の secret と template、[`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| GitHub account を増減する | [`flake.nix`](../../flake.nix) の `dotfiles.accounts`、[`accounts/module.nix`](../../accounts/module.nix)、[`mcp/github/module.nix`](../../mcp/github/module.nix)、[`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) | account roster と暗号化済み値を同じ変更に含め、`dotfiles-rebuild` |
| backend が使う secret を追加または変更する | 対応する [`containers/NAME/module.nix`](../../containers) の `sops.secrets` と template、[`sops/assets/secrets.yaml`](../../sops/assets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| host recipient を追加する | [`sops/assets/.sops.yaml`](../../sops/assets/.sops.yaml) の `keys` と `creation_rules` | [SOPS の鍵](../operations/sops-enrollment.md)に従って `sops updatekeys` し、新しい鍵で復号できることを確かめてから旧 recipient を外す |

通常の secret 編集 command は次の形に統一する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops --config ~/dotfiles-wsl/sops/assets/.sops.yaml \
  ~/dotfiles-wsl/sops/assets/secrets.yaml
```
