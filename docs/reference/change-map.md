# 変更箇所

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

生成済みの設定ファイルを直接編集せず、表に示す正本を変更する。値や対象の全一覧はこの文書に固定せず、Nix 宣言から取得する。

## Host

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| ホスト固有の `my.*` 値を変える | [`flake.nix`](../../flake.nix) の `nixosConfigurations` と、その option を宣言する unit の `module.nix` | 通常の値は `dotfiles-rebuild --plan` で確認してから `dotfiles-rebuild`。`my.username` と `my.dotfilesDir` は host identity migration なので通常 rebuild では変更しない |
| Nix の binary cache を増減する | [`system/assets/nix-caches.nix`](../../system/assets/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 責務を追加または削除する | repo 直下に unit directory を作り `module.nix` を置く。収集は flake が行う。層は `module.nix` `package.nix` `checks.nix` `impl/` `assets/` `package/` `tests/` `fixtures/` の名前だけで表し、option の接頭辞は unit 名に合わせる | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| PATH 上の汎用ツールを増減する | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.packages`。nixpkgs に無いものは `toolchain/NAME/package.nix` を作る | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| language server を増減する | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.lsp`。登録は各 CLI の module が変換する | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 使用量の観測先を変える | [`telemetry/module.nix`](../../telemetry/module.nix)。CLI は `my.contract.telemetry` を読む | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| 品質 gate の構成を変える | [`sonarqube/module.nix`](../../sonarqube/module.nix)。credential は [`secrets/secrets.yaml`](../../secrets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |

## CLI

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| AI CLI を追加する | [`clis/NAME/module.nix`](../../clis) を作り `my.clis.NAME` を宣言する。収集は flake が行うため roster への転記は要らない | 新規ファイルを `git add` し、checkout から `nix run .#dotfiles-install-clis`、`dotfiles-rebuild` の順に実行する |
| AI CLI を管理対象から外す | 対応する [`clis/NAME/`](../../clis) を削除する | `dotfiles-rebuild`。`dotfiles-install-clis` は残存 binary を削除しないため、upstream が配置したファイルは別途削除する |
| CLI 固有の managed config を変える | 対応する [`clis/NAME/assets/`](../../clis) の template と `module.nix` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| CLI の upstream 入手方法を変える | 対応する [`clis/NAME/module.nix`](../../clis) の `my.clis.NAME.install` | `dotfiles-rebuild`、`dotfiles-install-clis` |

## Agent と skill

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| 共通ルールを変える | [`clis/assets/AGENTS.md`](../../clis/assets/AGENTS.md) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| local skill を追加または変更する | [`clis/assets/skills/NAME/SKILL.md`](../../clis/assets/skills) と [`clis/module.nix`](../../clis/module.nix) の自動検出、配備規則 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| subagent を追加または変更する | [`clis/assets/agents/NAME.md`](../../clis/assets/agents) と [`clis/module.nix`](../../clis/module.nix) の自動検出、CLI 別変換 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| plugin 由来の skill を更新する | [`flake.nix`](../../flake.nix) の plugin inputs と [`flake.lock`](../../flake.lock) | input を更新し、`dotfiles-rebuild --plan`、`dotfiles-rebuild` |

## MCP

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| MCP target を追加または削除する | [`mcp/NAME/`](../../mcp) に `module.nix` と必要なら `package.nix` を置く。収集は flake が行う | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| gateway の endpoint または target の割り当てを変える | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `my.mcp.endpoints` と各 [`mcp/NAME/module.nix`](../../mcp) の `endpoint` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| Docker backend の構成を変える | 対応する [`mcp/NAME/module.nix`](../../mcp) と [`mcp/module.nix`](../../mcp/module.nix) の `mkMcpBackend` | Nix で build する image は `dotfiles-rebuild`。upstream image の宣言変更は checkout から同期してから `dotfiles-rebuild` |
| upstream OCI image を更新する | 対応する [`mcp/NAME/module.nix`](../../mcp) の repository、digest、canonical image reference。digest は `dotfiles-image-digest <image>` で取る | 宣言変更後に `nix run .#dotfiles-sync-images -- --status`、`nix run .#dotfiles-sync-images`、`dotfiles-rebuild` |
| 固定した package の hash を更新する | 対応する [`mcp/NAME/package.nix`](../../mcp) の hash。値は `nix store prefetch-file --hash-type sha256 --json <url>` で取る | `dotfiles-rebuild` |

## Secret と identity

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| default Git identity を変える | [`sops/module.nix`](../../sops/module.nix) の consumer 宣言と [`secrets/secrets.yaml`](../../secrets/secrets.yaml) の暗号化済み値 | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| work identity の対象と値を変える | [`flake.nix`](../../flake.nix) の `my.git.workIdentity`、[`sops/module.nix`](../../sops/module.nix)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| GitHub account を増減する | [`flake.nix`](../../flake.nix) の `my.accounts`、[`accounts/module.nix`](../../accounts/module.nix)、[`mcp/github/module.nix`](../../mcp/github/module.nix)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | account roster と暗号化済み値を同じ変更に含め、`dotfiles-rebuild` |
| backend が使う secret を追加または変更する | 消費する unit の `sops.secrets` と template、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| host recipient を追加する | [`secrets/.sops.yaml`](../../secrets/.sops.yaml)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml)、[`sops/impl/sops-enroll.sh`](../../sops/impl/sops-enroll.sh) の transaction contract | [SOPS enrollment](../operations/sops-enrollment.md)に従い、tracked file を手作業で `sops updatekeys` しない |

通常の secret 編集 command は次の形に統一する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops ~/dotfiles-wsl/secrets/secrets.yaml
```
