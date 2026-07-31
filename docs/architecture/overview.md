# 構成概要

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

このリポジトリは、NixOS-WSL の system generation を中心に、Home Manager、systemd、Docker、SOPS と運用 command を一つの flake から組み立てる。設定の正本は checkout 内の Nix 宣言と共有ファイルであり、生成後の `/etc`、Home Manager の配備先、Nix store は編集対象ではない。変更箇所は[変更箇所](../reference/change-map.md)、適用手順は [Rebuild](../operations/rebuild.md)を参照する。

## System generation

[`flake.nix`](../../flake.nix) は NixOS-WSL、sops-nix、Home Manager を [`modules/default.nix`](../../modules/default.nix) と同じ NixOS 評価へ渡す。評価結果は Nix store 上の immutable な system closure になる。

```text
checkout
   │  source snapshot、flake check、build
   ▼
Nix store の candidate system
   │  system profile 更新、activation
   ▼
/run/current-system
   ├── /etc と system command
   ├── systemd unit
   ├── Home Manager の user 配備
   └── current generation の doctor manifest
```

通常の適用入口は `dotfiles-rebuild` だけである。[`modules/commands.nix`](../../modules/commands.nix) は PATH 上の直接の `nixos-rebuild` を拒否し、評価済み `config.system.build.nixos-rebuild` を transaction 内から使う。source snapshot、flake check、candidate build は通常ユーザーで実行し、system profile の更新と activation だけを昇格する。

`/run/current-system` は実行中の generation、`/nix/var/nix/profiles/system` は system profile、`/run/booted-system` は WSL 起動時の generation を表す。`wsl.conf` と activation interface の差分に応じて、live switch と WSL cold start を振り分ける。

## Module graph

[`modules/default.nix`](../../modules/default.nix) の `imports` がローカル module の入口である。

| Module | 所有する責務 |
|---|---|
| `options.nix` | ホスト共通の `my.*` contract と導出値 |
| `wsl.nix` | NixOS-WSL、systemd boot、Windows interop、`wslview` |
| `nix.nix`、`fonts.nix` | Nix daemon、cache、GC と system font |
| `secrets.nix`、`accounts/` | SOPS consumer、Git identity、account credential の配備 |
| `mcp/` | agentgateway、MCP target、Docker backend |
| `clis/` | AI CLI roster、設定、rules、skills、agents |
| `user/` | login user、Home Manager、Git と user package |
| `commands.nix` | generation 固有の `dotfiles-*` command と manifest |

Home Manager は独立した設定適用系ではなく、NixOS module として同じ system evaluation に入る。[`modules/user/default.nix`](../../modules/user/default.nix) が user package、shell 環境、Home Manager の配備を宣言し、activation 後の `home-manager-<user>.service` を doctor の検査対象にする。system 全体のファイルと service は NixOS、home 配下の宣言的な file と user package は Home Manager が所有する。

JSON、TOML、YAML の設定は、配備を担当する module が一度だけ生成する。同じ immutable source を `/etc`、Home Manager、SOPS template、OCI volume、doctor の必要な consumer へ渡す。`my.configArtifacts` は構文検査用の参照であり、別の設定 inventory ではない。

## Runtime services

systemd は generation を runtime へ展開する。長時間動く agentgateway、Docker daemon、OCI container、MCP backend network と、定期実行する AI CLI updater を unit として管理する。unit の期待状態は各所有 module が `my.doctor.units` へ隣接して宣言する。

[`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) は Docker daemon と `mcp-backends` network を用意し、backend container を NixOS の OCI container module へ渡す。全 container は `pull = "never"` で起動する。upstream image は明示的な同期、Nix 生成 image は `imageFile` の load が取得責任を持つ。

SOPS の暗号文は repository に置き、sops-nix が activation 時に host key で復号する。復号済み secret と template は runtime にだけ生成され、consumer の file、環境ファイルへ渡る。鍵と credential の境界は[セキュリティ設計](security.md)、通常の編集は [Secrets](../operations/secrets.md)に分けている。

## Current generation の doctor manifest

[`modules/commands.nix`](../../modules/commands.nix) は評価済み設定から versioned JSON を生成し、system closure の `etc/dotfiles/doctor.json` に収録する。manifest は generation の論理 path、user、systemd unit、managed file、CLI の配備 contract、MCP、OCI、SOPS metadata、WSL interop と probe 上限を、各 module の宣言から導出する。検査専用の一覧を手書きしない。

`dotfiles-doctor` は開始時に `/run/current-system/etc/dotfiles/doctor.json` を解決し、その immutable な store path だけを期待値として使う。実行中の doctor、manifest、system profile が同じ current generation に属することも検査する。doctor は service の再起動、image pull、file 修復を行わず、観測結果だけを返す。

`nix flake check` は source から artifact を生成できるかを検査し、doctor は activation 後の runtime が current generation に収束したかを検査する。実行と診断は [Doctor](../operations/doctor.md)に記載している。

## 生成 command

[`modules/commands.nix`](../../modules/commands.nix) は `config.my` と shell source を `writeShellApplication` へ渡し、generation 固有の command を作る。command は system closure に入るため、current generation の command はその generation の設定と manifest に束縛される。一部は flake package としても公開され、current generation より新しい checkout の command を初回配備や更新前に実行できる。

| 境界 | Command の責務 |
|---|---|
| system generation | `dotfiles-rebuild` が snapshot、build、apply、doctor と中断後の回復を transaction 化する |
| runtime 観測 | `dotfiles-doctor` が current generation と実状態を比較する |
| 外部の可変 state | `dotfiles-install-clis` が user binary、`dotfiles-sync-images` が Docker cache と同期 receipt を更新する |
| 保守 | `dotfiles-cleanup` が候補表示と明示削除、`dotfiles-wsl-restart-required` が cold-start 判定を担当する |
| 鍵の enrollment | `dotfiles-sops-enroll` が repository の recipient と host key の移行を通常 rebuild から分離する |

最初の system generation が存在しない段階では生成 command を参照できないため、`bootstrap/impl/bootstrap.sh` だけは手書きの入口として残る。

## データと適用の境界

| 領域 | 正本または所有者 | 変更の反映 |
|---|---|---|
| Nix 宣言、template、共有資材 | Git checkout | flake evaluation と rebuild |
| system closure、生成設定、生成 command | Nix store | build 後は immutable |
| `/run/current-system`、system profile、systemd | NixOS activation | `dotfiles-rebuild` |
| Home Manager の宣言的な home file | system generation 内の Home Manager 設定 | NixOS activation に続く user 配備 |
| AI CLI binary、Docker cache、container data、運用 receipt | 各専用 command と runtime service | rebuild とは別の明示操作、または service 実行 |
| Claude Code と Codex の user-owned seed config | seed 作成後は各 CLI | Home Manager activation は file がない場合か symlink の場合だけ通常 file を作り、既存の通常 file は保持する |
| 暗号文、host key、復号済み secret | Git、root 管理領域、sops-nix runtime | enrollment、SOPS 編集、activation |

mutable な runtime state を Nix 宣言へ逆輸入しない。NixOS または Home Manager が所有する生成先を直接編集しても正本は変わらず、次の activation で上書きまたは drift として検出される。Claude Code と Codex の user-owned seed config は例外であり、通常 file になった後は seed source を変更しても上書きされない。
