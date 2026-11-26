# dotfiles-wsl

WSL2 上の NixOS で、AI agent と一緒に開発するための個人用の開発機を、一つの flake で宣言する。
対象は x86_64 の NixOS-WSL で、主ユーザーの既定名は `nixos`。他の所有者が使う場合は、Git の身元、アカウント、secret を自分のものに置き換える。

## 持つもの

| 場所 | 内容 |
|---|---|
| `hosts/` | host ごとの事実（WSLの資源、drive、nixの並列度、memoryの上限） |
| `workstation/` | NixOS-WSL、nix、user、locale、font、storage、memoryの保護、Docker、`dotfiles-rebuild`、`dotfiles-doctor` |
| `secrets/`、`identity/` | sops で暗号化した secret、GitHub account と Git の身元 |
| `toolchain/` | CLI、language server、Git の設定と global hook |
| `agents/` | OMP と起動 wrapper、OMP の設定、MCP server、方針（`AGENTS.md`、`RULES.md`）、skill、`dotfiles-agent-brief` |
| `knowledge/` | Hindsight（記憶）、記憶の MCP、日誌、訂正の収穫 |
| `docs/` | [設計](docs/design.md)と[運用](docs/operations.md) |

`agents/` の方針と local skill はcheckoutへのlinkで配備し、編集すれば次の読込から効く。
生成された設定（`~/.omp/agent/*.json` など）は直接編集しない。

## よく使う操作

```bash
nix flake check            # 変更の検査
dotfiles-rebuild           # commit 済みの HEAD を build して切り替える
dotfiles-rebuild rollback  # 直前の世代へ戻す
dotfiles-doctor            # 状態の点検と対処の案内
```

新しいPCへの導入、更新、不調の調べ方は[運用](docs/operations.md)にある。

## セキュリティ

credential を平文で commit しない。secret は `secrets/sops/assets/secrets.json` に sops で暗号化して置く。手順は [secrets](docs/secrets.md) と [SOPSの鍵](docs/sops-enrollment.md)。

## License

[MIT License](LICENSE)
