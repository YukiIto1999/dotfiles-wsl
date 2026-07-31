# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールと service を区分ごとに示し、それぞれの正本を指す。roster、version、件数、行番号は転記しない。現在の値は各 command で評価結果から取る。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`modules/user/default.nix`](../../modules/user/default.nix) と各 [`modules/clis/`](../../modules/clis) module の `environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| user package | [`modules/user/default.nix`](../../modules/user/default.nix) の `home.packages` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`modules/user/default.nix`](../../modules/user/default.nix) の `programs` | 同上 module を参照する |
| 保守用 devShell | [`flake.nix`](../../flake.nix) の `devShells` | `nix develop --command echo` の後に `$PATH` を確認する |

`nixfmt` は editor と単一ファイル、`nixfmt-tree` は `nix fmt` と repository 全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 運用 command

利用者向けの入口は `dotfiles-` prefix を持つ生成 command である。定義は [`modules/commands.nix`](../../modules/commands.nix) と [`modules/secrets.nix`](../../modules/secrets.nix)、bootstrap から呼ぶ flake package の公開は [`flake.nix`](../../flake.nix) の `packages` にある。command は `writeShellApplication` で生成し、必要な CLI を runtime closure に含める。

現在の一覧は `nix eval --json .#nixosConfigurations.nixos.config.my.commands --apply builtins.attrNames` で確認する。

## AI CLI と agent

| 区分 | 正本 | 現在の値 |
|---|---|---|
| AI CLI | [`modules/clis/default.nix`](../../modules/clis/default.nix) の `my.clis` | `nix eval --json .#nixosConfigurations.nixos.config.my.clis --apply builtins.attrNames` |
| 静的 agent | [`share/agents/`](../../share/agents) | `nix eval --json .#nixosConfigurations.nixos.config.my.doctor.agentFiles` |
| local skill | [`share/skills/`](../../share/skills) | `nix eval --json .#nixosConfigurations.nixos.config.my.doctor.skillNames` |
| plugin skill | [`flake.nix`](../../flake.nix) の plugin input と [`flake.lock`](../../flake.lock) | 同上。local skill と合わせて出る |

plugin の追加、更新、削除は [AI tooling](../architecture/ai-tooling.md) の責務境界に従う。

## MCP と service

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix)、[`pkgs/agentgateway/`](../../pkgs/agentgateway) | `systemctl show agentgateway.service` |
| MCP target | 各 [`modules/mcp/servers/`](../../modules/mcp/servers) module の `my.mcp.targets.<name>` | `nix eval --json .#nixosConfigurations.nixos.config.my.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) の `my.ociImages` と各 server module | `nix eval --json .#nixosConfigurations.nixos.config.my.ociImages --apply builtins.attrNames` |
| host process | 各 server module が宣言する stdio front | gateway の子 process を `systemd-cgls -u agentgateway.service` で見る |

agentgateway は全 target を一つの HTTP endpoint へ公開し、各 AI CLI が同じ target 名を使う。credential、container、host process の境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に `dotfiles-doctor` で宣言と実状態の収束を確認する。
