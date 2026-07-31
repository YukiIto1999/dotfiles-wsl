# 変更箇所

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

生成済みの設定ファイルを直接編集せず、表に示す正本を変更する。値や対象の全一覧はこの文書に固定せず、Nix 宣言から取得する。

## Host

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| ホスト固有の `my.*` 値を変える | [`flake.nix`](../../flake.nix) の `nixosConfigurations` と [`modules/options.nix`](../../modules/options.nix) の option contract | 通常の値は `dotfiles-rebuild --plan` で確認してから `dotfiles-rebuild`。`my.username` と `my.dotfilesDir` は host identity migration なので通常 rebuild では変更しない |
| Nix の binary cache を増減する | [`modules/nix-caches.nix`](../../modules/nix-caches.nix) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| NixOS module を追加または削除する | 対象の [`modules/`](../../modules) 配下のファイルと [`modules/default.nix`](../../modules/default.nix) の `imports` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |

## CLI

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| AI CLI を追加する | [`modules/clis/NAME/`](../../modules/clis) の module と [`modules/clis/default.nix`](../../modules/clis/default.nix) の `imports`、`my.clis` roster | 新規ファイルを `git add` し、checkout から `nix run .#dotfiles-install-clis`、`dotfiles-rebuild` の順に実行する |
| AI CLI を管理対象から外す | 対応する [`modules/clis/NAME/`](../../modules/clis) の module と [`modules/clis/default.nix`](../../modules/clis/default.nix) の `imports` | `dotfiles-rebuild`。`dotfiles-install-clis` は残存 binary を削除しないため、upstream が配置したファイルは別途削除する |
| CLI 固有の managed config を変える | 対応する [`modules/clis/NAME/`](../../modules/clis) の template と module | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| CLI の upstream 入手方法を変える | 対応する [`modules/clis/NAME/default.nix`](../../modules/clis) の `my.clis.NAME.install` | `dotfiles-rebuild`、`dotfiles-install-clis` |

## Agent と skill

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| 共通ルールを変える | [`share/AGENTS.md`](../../share/AGENTS.md) | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| local skill を追加または変更する | [`share/skills/NAME/SKILL.md`](../../share/skills) と [`modules/clis/default.nix`](../../modules/clis/default.nix) の自動検出、配備規則 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| subagent を追加または変更する | [`share/agents/NAME.md`](../../share/agents) と [`modules/clis/default.nix`](../../modules/clis/default.nix) の自動検出、CLI 別変換 | 新規ファイルは `git add` で flake source に含めてから `dotfiles-rebuild` |
| plugin 由来の skill を更新する | [`flake.nix`](../../flake.nix) の plugin inputs と [`flake.lock`](../../flake.lock) | input を更新し、`dotfiles-rebuild --plan`、`dotfiles-rebuild` |

## MCP

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| MCP target を追加または削除する | 必要な [`pkgs/NAME/`](../../pkgs) の build 定義、[`modules/mcp/servers/NAME.nix`](../../modules/mcp/servers)、[`modules/mcp/default.nix`](../../modules/mcp/default.nix) の `imports` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| gateway の listener または target 集約を変える | [`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix) と各 server module の `my.mcp.targets` | `dotfiles-rebuild --plan`、`dotfiles-rebuild` |
| Docker backend の構成を変える | 対応する [`modules/mcp/servers/NAME.nix`](../../modules/mcp/servers) と [`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) の contract | Nix で build する image は `dotfiles-rebuild`。upstream image の宣言変更は checkout から同期してから `dotfiles-rebuild` |
| upstream OCI image を更新する | 対応する [`modules/mcp/servers/NAME.nix`](../../modules/mcp/servers) の repository、digest、canonical image reference | 宣言変更後に `nix run .#dotfiles-sync-images -- --status`、`nix run .#dotfiles-sync-images`、`dotfiles-rebuild` |

## Secret と identity

| 変更目的 | 正本 | 適用方法 |
|---|---|---|
| default Git identity を変える | [`sops/module.nix`](../../sops/module.nix) の consumer 宣言と [`secrets/secrets.yaml`](../../secrets/secrets.yaml) の暗号化済み値 | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| work identity の対象と値を変える | [`flake.nix`](../../flake.nix) の `my.workIdentity`、[`sops/module.nix`](../../sops/module.nix)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| GitHub account を増減する | [`flake.nix`](../../flake.nix) の `my.accounts`、[`accounts/module.nix`](../../accounts/module.nix)、[`modules/mcp/servers/github.nix`](../../modules/mcp/servers/github.nix)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | account roster と暗号化済み値を同じ変更に含め、`dotfiles-rebuild` |
| backend が使う secret を追加または変更する | 消費する [`modules/`](../../modules) 内の `sops.secrets` と template、[`secrets/secrets.yaml`](../../secrets/secrets.yaml) | host key を指定して `sops` で編集し、`dotfiles-rebuild` |
| host recipient を追加する | [`secrets/.sops.yaml`](../../secrets/.sops.yaml)、[`secrets/secrets.yaml`](../../secrets/secrets.yaml)、[`sops/impl/sops-enroll.sh`](../../sops/impl/sops-enroll.sh) の transaction contract | [SOPS enrollment](../operations/sops-enrollment.md)に従い、tracked file を手作業で `sops updatekeys` しない |

通常の secret 編集 command は次の形に統一する。

```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  sops ~/dotfiles-wsl/secrets/secrets.yaml
```
