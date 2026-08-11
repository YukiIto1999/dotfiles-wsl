# dotfiles-wsl

YukiIto1999 が WSL2 上の NixOS を再現し、日常運用するための個人用 dotfiles。
NixOS、Home Manager、開発ツール、AI コーディング環境、暗号化済み secrets を一つの flake で管理する。

このリポジトリは `nixos` ユーザー、`~/dotfiles-wsl` への checkout、所有者が保管する SOPS recovery key を前提とする。一般向けの NixOS distribution や、そのまま利用できる fork ではない。再利用する場合は host、account、secret、固定 path を自分の環境に合わせて置き換える必要がある。

## 管理対象

- NixOS-WSL、Home Manager、WSLg、font、systemd service
- language server、compiler、formatter、Git、日常利用する CLI
- Claude Code、Codex、OpenCode、Antigravity の設定、skills、agents
- agentgateway、MCP server、Docker backend
- Git identity、GitHub PAT、backend credential を含む SOPS 暗号文

生成済みの設定ファイルは直接編集しない。正本は、この checkout 内の Nix 宣言、asset、暗号化済み secret に置く。

## 操作

所有者が新しい host を構築するときは[セットアップ手順](docs/operations/getting-started.md)に従う。通常の変更は、候補 generation を確認してから同じ checkout を適用する。

```bash
cd ~/dotfiles-wsl
dotfiles-rebuild --plan
dotfiles-rebuild
dotfiles-doctor
```

upstream OCI image の確認と同期には `dotfiles-sync-images --status` と `dotfiles-sync-images` を使う。secret の編集、鍵の追加、rebuild の中断や復旧は、対応する runbook に従う。

## 構成

| root | 責務 |
|---|---|
| `host/`、`accounts/`、`sops/` | machine、identity、secret |
| `agents/`、`mcp/`、`containers/` | AI client、MCP interface、application backend |
| `toolchain/`、`artifacts/`、`observations/`、`telemetry/` | 開発ツール、配備物、runtime observation、使用量観測 |
| `commands/`、`gates/`、`docs/` | 運用 command、repository の制約検査、文書 |

Nix unit は `module.nix` を marker にし、build がある場合は `package.nix`、検査がある場合は `checks.nix` を持つ。`impl/`、`assets/`、`fixtures/` は必要な unit だけが使う。境界と依存方向は[構成概要](docs/architecture/overview.md)に記載する。

## ドキュメント

[ドキュメント索引](docs/README.md)から、目的に合う文書を選ぶ。

- [operations](docs/README.md#手順--operations): セットアップ、rebuild、secrets、doctor、更新手順
- [architecture](docs/README.md#説明--architecture): 責務境界、AI tooling、security
- [reference](docs/README.md#参照--reference): 正本の場所、変更箇所、機械検証

## 開発

保守方針、検証方法、コミット形式は [CONTRIBUTING.md](CONTRIBUTING.md) に従う。CI は `main` への push と pull request で `nix flake check` を実行する。

## セキュリティ

credential を平文で commit しない。host key、recovery key、PAT、loopback service の信頼境界は[セキュリティ設計](docs/architecture/security.md)に記載する。

## License

[MIT License](LICENSE)
