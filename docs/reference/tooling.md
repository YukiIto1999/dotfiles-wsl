# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールと service を区分ごとに示し、それぞれの正本を指す。roster、version、件数、行番号は転記しない。現在の値は各 command で評価結果から取る。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`host/module.nix`](../../host/module.nix) と各 unit の `environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| 汎用ツール | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.packages` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`host/module.nix`](../../host/module.nix) の `programs` | 同じ unit を参照する |
| language server | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.lsp` | `nix eval --json .#nixosConfigurations.nixos.config.my.toolchain.lsp --apply builtins.attrNames` |
| 保守用 devShell | [`flake.nix`](../../flake.nix) の `devShells` | `nix develop --command echo` の後に `$PATH` を確認する |

`nixfmt` は editor と単一ファイル、`nixfmt-tree` は `nix fmt` と repository 全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 運用 command

利用者向けの入口は `dotfiles-` prefix を持つ生成 command である。定義は [`commands/module.nix`](../../commands/module.nix) と [`sops/module.nix`](../../sops/module.nix)、bootstrap から呼ぶ flake package の公開は [`flake.nix`](../../flake.nix) の `packages` にある。command は `writeShellApplication` で生成し、必要な CLI を runtime closure に含める。

現在の一覧は `nix eval --json .#nixosConfigurations.nixos.config.my.commands --apply builtins.attrNames` で確認する。

## AI CLI と agent

| 区分 | 正本 | 現在の値 |
|---|---|---|
| AI CLI | [`clis/module.nix`](../../clis/module.nix) の `my.clis` | `nix eval --json .#nixosConfigurations.nixos.config.my.clis --apply builtins.attrNames` |
| 静的 agent | [`clis/assets/agents/`](../../clis/assets/agents) | `nix eval --json .#nixosConfigurations.nixos.config.my.doctor.agentFiles` |
| local skill | [`clis/assets/skills/`](../../clis/assets/skills) | `nix eval --json .#nixosConfigurations.nixos.config.my.doctor.skillNames` |
| plugin skill | [`flake.nix`](../../flake.nix) の plugin input と [`flake.lock`](../../flake.lock) | 同上。local skill と合わせて出る |

plugin の追加、更新、削除は [AI tooling](../architecture/ai-tooling.md) の責務境界に従う。

## MCP と service

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `my.mcp.endpoints` | `nix eval --json .#nixosConfigurations.nixos.config.my.contract.mcp.endpoints` |
| MCP target | 各 [`mcp/NAME/module.nix`](../../mcp) の `my.mcp.targets.<name>` | `nix eval --json .#nixosConfigurations.nixos.config.my.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`images/module.nix`](../../images/module.nix) の `my.images` と各 unit の `mkContainerBackend` | `nix eval --json .#nixosConfigurations.nixos.config.my.images --apply builtins.attrNames` |
| MCP front | 各 [`mcp/NAME/module.nix`](../../mcp) の `port` と `serve` | `nix eval --json .#nixosConfigurations.nixos.config.my.contract.mcp.fronts`。稼働は `systemctl status mcp-front-<name>` |
| telemetry | [`telemetry/module.nix`](../../telemetry/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.my.contract.telemetry` |
| 品質 gate | [`toolchain/sonarqube/module.nix`](../../toolchain/sonarqube/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.virtualisation.oci-containers.containers.sonarqube` |

agentgateway は全 target を一つの URL へ公開し、各 front へは loopback の HTTP で接続する。front は常駐するので downstream の session が増えても process は増えない。credential、container、host process の境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に `dotfiles-doctor` で宣言と実状態の収束を確認する。
