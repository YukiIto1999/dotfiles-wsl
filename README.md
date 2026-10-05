# dotfiles-wsl

WSL2上のNixOS環境を、別のPCでも構築し、日常運用するための個人用dotfilesである。
OS、Home Manager、開発ツール、AIコーディング環境、暗号化済みsecretsを一つのflakeで管理する。

対象はx86_64のNixOS-WSLで、主ユーザーの既定名は`nixos`である。
ユーザー名、checkoutの場所、Windows側の資源、追加ドライブ、Nixの並列度はhost profileで宣言する。
別のPCで同じ所有者の環境を再現する場合は、[セットアップ手順](docs/operations/getting-started.md)に従い、SOPSの復旧鍵か登録済みhost keyを用意する。
他の所有者が使う場合は、Git identity、アカウント、secretsを自分のものに置き換える。

## 管理対象

- NixOS-WSL、Home Manager、WSLg、font、locale、systemdを管理する。
- compiler、language server、formatter、Gitと、`btop`、`hyperfine`などのCLIを配備する。
- Bashの履歴はAtuinでローカルに保存し、自動同期を有効にしない。
- AI clientはregistryのadapterから選び、採用したclientだけに設定、Skill、subagentを配備する。
- Skillはrepository内の正本と、revisionを固定した外部sourceから採用する。
- MCP server、Docker backend、GitHub PAT、backend credentialを宣言する。

生成済みの設定ファイルは直接編集しない。正本は、この checkout 内の Nix 宣言、asset、暗号化済み secret に置く。

## 操作

初回構築は[セットアップ手順](docs/operations/getting-started.md)、AI clientの採用と更新は[Agent client](docs/operations/agent-clients.md)を参照する。
通常の変更は、sourceを検証してcommitした後、候補generationを確認して適用する。

```bash
dotfiles-rebuild --plan
dotfiles-rebuild
dotfiles-doctor
```

復旧が必要な場合は`dotfiles-rebuild --rollback`で直前のgenerationへ戻す。
containerを有効にしたhostでは、rebuild後に`dotfiles-sync-images --status`で状態を確認し、必要な場合に`dotfiles-sync-images`を実行する。
secretの編集、鍵の追加、中断後の再開は、対応するrunbookに従う。

checkoutから対象hostを明示して実行する場合は、次のhost構成を直接指定する。

```bash
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages -- --status
nix run .#nixosConfigurations.<host>.config.dotfiles.platform.cli.commands.syncImages
```

containerを選ばないhostには `dotfiles-sync-images` を配備しないため、これらのcommandは実行しない。

## 構成

| root | 責務 |
|---|---|
| `profiles/`、`workstation/`、`identity/`、`secrets/` | machine profile、WSL/Nix/Home Manager、identity、secret |
| `agents/`、`skills/`、`capabilities/` | AI clientとrole、手順、consumer非依存の機能contractと実装 |
| `platform/`、`managed-artifacts/`、`health/`、`telemetry/` | MCP/container/CLI基盤、配備物、runtime observation、使用量観測 |
| `toolchain/`、`maintenance/`、`checks/`、`docs/` | 開発ツール、明示的な整理、repository横断制約、文書 |

Nix unit は `module.nix` を marker にし、build がある場合は `package.nix`、検査がある場合は `checks.nix` を持つ。`impl/`、`assets/`、`fixtures/`、`skill/` は必要な unit だけが使う。境界と依存方向は[構成概要](docs/architecture/overview.md)に記載する。

## アーキテクチャ標準

アーキテクチャの標準は `flake.nix` の `architectureStandard` input が指す [architecture-standard](https://github.com/YukiIto1999/architecture-standard) にある。準拠の基準は、配備されている現在の標準本文である。適用は、標準の README の適用の4則と利用の手順に従う。

採用の判断は [ADR 0001](docs/adr/0001-adopt-architecture-standard.md)、標準本文の参照方法と版の固定は [ADR 0002](docs/adr/0002-pin-standard-as-flake-input.md) に記録する。

## ドキュメント

[ドキュメント索引](docs/README.md)から、目的に合う文書を選ぶ。

追跡する`docs/`には、現在の構成と有効な手順を置く。
作業計画、実測ログ、過去の調査は、Gitの追跡対象外である`work/`へ置く。
`work/`はPC間で再現される成果物ではなく、引き継ぐ場合は秘密情報を除いた必要な記録を別途渡す。

- [operations](docs/README.md#手順--operations): セットアップ、rebuild、secrets、doctor、更新手順
- [architecture](docs/README.md#説明--architecture): 責務境界、AI tooling、security
- [reference](docs/README.md#参照--reference): 正本の場所、変更箇所、機械検証

## 開発

保守方針、検証方法、コミット形式は [CONTRIBUTING.md](CONTRIBUTING.md) に従う。CI は `main` への push と pull request で `nix flake check` を実行する。

## セキュリティ

credential を平文で commit しない。host key、recovery key、PAT、loopback service の信頼境界は[セキュリティ設計](docs/architecture/security.md)に記載する。

## License

[MIT License](LICENSE)
