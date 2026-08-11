# 構成概要

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

このリポジトリは、NixOS-WSL の system generation を中心に、Home Manager、systemd、Docker、SOPS と運用 command を一つの flake から組み立てる。設定の正本は checkout 内の Nix 宣言と共有ファイルであり、生成後の `/etc`、Home Manager の配備先、Nix store は編集対象ではない。変更箇所は[変更箇所](../reference/change-map.md)、適用手順は [Rebuild](../operations/rebuild.md)を参照する。

## System generation

[`flake.nix`](../../flake.nix) は NixOS-WSL、sops-nix、Home Manager を、収集した unit の `module.nix` と同じ NixOS 評価へ渡す。評価結果は Nix store 上の immutable な system closure になる。

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
   └── current generation の doctor command
```

通常の適用入口は `dotfiles-rebuild` だけである。[`commands/rebuild/module.nix`](../../commands/rebuild/module.nix) は PATH 上の直接の `nixos-rebuild` を拒否する。飛ばされると困るのは、未 commit の変更で古い内容を配備しないことと、WSL の再起動要否の判定である。世代と rollback は NixOS が持つので、その上に層を作らない。

`/run/current-system` は実行中の generation、`/nix/var/nix/profiles/system` は system profile、`/run/booted-system` は WSL 起動時の generation を表す。`wsl.conf` と activation interface の差分に応じて、live switch と WSL cold start を振り分ける。

## Module graph

[`flake.nix`](../../flake.nix) の `collectUnits` がローカル module の入口である。`module.nix` を持つ directory を走査して集めるため、module を足すときに入口を編集しない。

| Unit | 所有する責務 |
|---|---|
| `host/` | host 共通の語彙、NixOS-WSL、Windows interop、Nix daemon と cache、font、login user、Home Manager |
| `mcp/` | 型付き MCP target、target から導く常駐 front、単一 agentgateway、その build |
| `agents/` | Agent client roster、型付き capability、設定、共通 rules、skills、definitions |
| `toolchain/` | PATH 上の汎用ツールと language server、git 設定、project の静的解析 |
| `containers/` | container service contract、OCI image inventory と同期、backend 配備の共通 helper |
| `telemetry/` | OpenTelemetry collector と endpoint 契約 |
| `observations/` | owner が登録する runtime observation の閉じた型と registry |
| `sops/`、`accounts/` | secret file の作り方と検証、account credential、利用者の identity |
| `commands/rebuild/`、`commands/doctor/`、`commands/cleanup/` | 適用と初回構築、診断、整理 |
| `artifacts/` | 生成設定の登録簿と構文検査 |
| `gates/` | devShell、規約と構造の検査 |

unit は責務で分かれ、層は定めた名前だけで表す。`module.nix` が宣言、`package.nix` が build、`checks.nix` が検証を持つ。必要な unit だけが `impl/`、`assets/`、`fixtures/`、`package/`、`shared/` を使う。

repository 固有 option は `dotfiles.<root>` に置き、宣言した root unit と namespace を一致させる。unit 間で共有する値は型付き option を通す。host は account、agent client、container application、MCP provider、language server の必要集合を [`flake.nix`](../../flake.nix) に default なしで宣言し、module の提供集合との過不足を評価時に拒否する。通常構成と gateway port variant は、それぞれ同じ必要集合を固定値で持つ。

Home Manager は独立した設定適用系ではなく、NixOS module として同じ system evaluation に入る。[`host/module.nix`](../../host/module.nix) が user package、shell 環境、Home Manager の配備を宣言し、activation 後の `home-manager-<user>.service` を doctor の検査対象にする。system 全体のファイルと service は NixOS、home 配下の宣言的な file と user package は Home Manager が所有する。

JSON、TOML、YAML の設定は、配備を担当する module が一度だけ生成する。同じ immutable source を `/etc`、Home Manager、SOPS template、OCI volume、artifact registry の必要な consumer へ渡す。`dotfiles.artifacts` は生成設定の構文と配備先を結ぶが、runtime の対象一覧は持たない。

## Runtime services

systemd は generation を runtime へ展開する。長時間動く agentgateway、Docker daemon、OCI container、MCP backend network と、定期実行する agent client updater、BuildKit GC、agent cache GC、worktree reaper を unit として管理する。各 owner は service、timer、配備 path、資源閾値などの実状態を `dotfiles.observations` へ登録する。

[`containers/module.nix`](../../containers/module.nix) は Docker daemon、`dotfiles-backends` network、型付き service contract、OCI image の同期を所有する。[`container-backend.nix`](../../containers/impl/container-backend.nix) は backend container を NixOS の OCI container module へ渡す。全 container は `pull = "never"` で起動する。upstream image は明示的な同期、Nix 生成 image は `imageFile` の load が取得責任を持つ。Agentmemory、Crawl4AI、SearXNG、SonarQube の application 固有宣言は各 `containers/` unit、対応する MCP front は各 `mcp/` unit が所有する。

MCP は `dotfiles.mcp.targets`、`dotfiles.mcp.fronts`、`dotfiles.mcp.gateway` の三つに分ける。target は provider と実行契約を所有し、front は target から導いた常駐 transport と backend 依存を所有する。gateway は全 front を束ねる単一 endpoint であり、front の起動依存を持たない。host が必要とする provider は [`flake.nix`](../../flake.nix) の固定 roster が決める。

SOPS の暗号文は repository に置き、sops-nix が activation 時に host key で復号する。復号済み secret と template は runtime にだけ生成され、consumer の file、環境ファイルへ渡る。鍵と credential の境界は[セキュリティ設計](security.md)、通常の編集は [Secrets](../operations/secrets.md)に分けている。

## 実状態の検証

[`observations/module.nix`](../../observations/module.nix) は 17 種類の observation kind を閉じた union として定義する。検査対象の意味と値は `agents`、`artifacts`、`containers`、`host`、`mcp`、`sops`、`telemetry` の各 owner が宣言し、registry key の先頭 segment も owner と一致させる。

[`commands/doctor/module.nix`](../../commands/doctor/module.nix) は registry 全体を key 順に一つの JSON へ投影する。`dotfiles-doctor` は kind ごとの汎用 probe を timeout と空の環境で実行し、MCP の protocol も owner が登録した `normalized-protocol` command として扱う。doctor 側には owner 名、service roster、MCP の状態機械を置かない。再起動、GC、trim、修復も行わず、観測結果だけを返す。

`nix flake check` は source から artifact を生成できるかを検査し、doctor は activation 後の runtime が宣言に収束したかを検査する。実行と診断は [Doctor](../operations/doctor.md)に記載している。

## 生成 command

[`commands/module.nix`](../../commands/module.nix) は `dotfiles.commands` option と `environment.systemPackages` への登録だけを持つ。[`commands/impl/mk-command.nix`](../../commands/impl/mk-command.nix) が generation 固有の値と shell source を `writeShellApplication` へ渡し、command を所有する unit が明示的に import する。command は system closure に入るため、current generation の command はその generation の設定と manifest に束縛される。一部は flake package としても公開され、current generation より新しい checkout の command を初回配備や更新前に実行できる。

user home に置く secret template の metadata は [`sops/impl/user-secret-file.nix`](../../sops/impl/user-secret-file.nix) が所有する。[`accounts/module.nix`](../../accounts/module.nix) が username を渡して明示的に import し、SOPS module は builder を global module argument に注入しない。

| 境界 | Command の責務 |
|---|---|
| system generation | `dotfiles-rebuild` が build と apply を行う。世代と rollback は NixOS が持つ |
| runtime 観測 | `dotfiles-doctor` が current generation と実状態を比較する |
| 外部の可変 state | `dotfiles-install-agents` が user binary、`dotfiles-sync-images` が Docker cache を更新する |
| 保守 | `dotfiles-cleanup` が候補表示と明示削除、`dotfiles-wsl-restart-required` が cold-start 判定を担当する |
| 鍵の enrollment | `dotfiles-sops-enroll` が repository の recipient と host key の移行を通常 rebuild から分離する |

最初の system generation が存在しない段階では生成 command を参照できないため、`commands/rebuild/impl/bootstrap.sh` だけは手書きの入口として残る。

## データと適用の境界

| 領域 | 正本または所有者 | 変更の反映 |
|---|---|---|
| Nix 宣言、template、共有資材 | Git checkout | flake evaluation と rebuild |
| system closure、生成設定、生成 command | Nix store | build 後は immutable |
| `/run/current-system`、system profile、systemd | NixOS activation | `dotfiles-rebuild` |
| Home Manager の宣言的な home file | system generation 内の Home Manager 設定 | NixOS activation に続く user 配備 |
| AI CLI binary、Docker cache、container data | 各専用 command と runtime service | rebuild とは別の明示操作、または service 実行 |
| Claude Code と Codex の user-owned seed config | seed 作成後は各 client | Home Manager activation は配備先に通常 file、symlink、directory などの既存物がない場合だけ通常 file を作る |
| 暗号文、host key、復号済み secret | Git、root 管理領域、sops-nix runtime | enrollment、SOPS 編集、activation |

mutable な runtime state を Nix 宣言へ逆輸入しない。NixOS または Home Manager が所有する生成先を直接編集しても正本は変わらず、次の activation で上書きされる。配備先を持つ managed artifact は source との不一致を doctor が報告する。Claude Code と Codex の user-owned seed config は artifact の配備観測から除外し、通常 file になった後は seed source を変更しても上書きしない。
