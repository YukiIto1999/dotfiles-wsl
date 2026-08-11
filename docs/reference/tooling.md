# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールと service を区分ごとに示し、それぞれの正本を指す。roster、version、件数、行番号は転記しない。現在の値は各 command で評価結果から取る。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`host/module.nix`](../../host/module.nix) と各 unit の `environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| 汎用ツール | [`toolchain/module.nix`](../../toolchain/module.nix) の `dotfiles.toolchain.packages` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`host/module.nix`](../../host/module.nix) の `programs` | 同じ unit を参照する |
| language server | [`toolchain/module.nix`](../../toolchain/module.nix) の `dotfiles.toolchain.lsp` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.toolchain.lsp --apply builtins.attrNames` |
| 保守用 devShell | [`flake.nix`](../../flake.nix) の `devShells` | `nix develop --command echo` の後に `$PATH` を確認する |

`nixfmt` は editor と単一ファイル、`nixfmt-tree` は `nix fmt` と repository 全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 運用 command

利用者向けの入口は `dotfiles-` prefix を持つ生成 command である。`commands/module.nix` は `dotfiles.commands` option と system package 登録を持ち、各 owner module は [`commands/impl/mk-command.nix`](../../commands/impl/mk-command.nix) を明示的に import する。bootstrap から呼ぶ flake package の公開は [`flake.nix`](../../flake.nix) の `packages` にある。command は `writeShellApplication` で生成し、必要な CLI を runtime closure に含める。

現在の一覧は `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.commands --apply builtins.attrNames` で確認する。

## AI CLI と agent

| 区分 | 正本 | 現在の値 |
|---|---|---|
| Agent client | [`agents/module.nix`](../../agents/module.nix) の `dotfiles.agents` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply builtins.attrNames` |
| Client installer | 各 [`agents/NAME/module.nix`](../../agents) の `install` と [`agents/impl/install-agents.sh`](../../agents/impl/install-agents.sh) | `nix run .#dotfiles-install-agents -- --print-manifest` |
| Agent runtime と worktree 台帳 | [`agents/module.nix`](../../agents/module.nix)、[`agents/impl/runtime/`](../../agents/impl/runtime)、[`agents/impl/resource/`](../../agents/impl/resource) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.runtime` |
| 静的 agent | [`agents/shared/definitions/`](../../agents/shared/definitions) | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.file --apply 'f: builtins.filter (n: builtins.match "\\.claude/agents/.*" n != null) (builtins.attrNames f)'` |
| local skill | [`agents/shared/skills/`](../../agents/shared/skills) | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.file --apply 'f: builtins.filter (n: builtins.match "\\.claude/skills/.*" n != null) (builtins.attrNames f)'` |
| plugin skill | [`flake.nix`](../../flake.nix) の plugin input と [`flake.lock`](../../flake.lock) | 同上。local skill と合わせて出る |

plugin の追加、更新、削除は [AI tooling](../architecture/ai-tooling.md) の責務境界に従う。

## Runtime observation

| 区分 | 正本 | 現在の値 |
|---|---|---|
| observation の型 | [`observations/module.nix`](../../observations/module.nix) の 17 種類の observation kind | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.observations --apply 'xs: builtins.mapAttrs (_: x: x.kind) xs'` |
| 検査対象と値 | `agents`、`artifacts`、`containers`、`host`、`mcp`、`sops`、`telemetry` の各 owner module | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.observations --apply builtins.attrNames` |
| 汎用 runner | [`commands/doctor/module.nix`](../../commands/doctor/module.nix)、[`commands/doctor/impl/doctor.sh`](../../commands/doctor/impl/doctor.sh)、[`commands/doctor/impl/probe.sh`](../../commands/doctor/impl/probe.sh) | `dotfiles-doctor --json` |
| MCP protocol | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix)、[`mcp/gateway/impl/observer.sh`](../../mcp/gateway/impl/observer.sh) | registry の `mcp/protocol/<gateway-id>` |

owner module は意味と観測値を持ち、`observations` は型、`commands/doctor` は実行と集約だけを持つ。対象を増減するときに doctor 独自の inventory は更新しない。

## MCP と service

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `dotfiles.mcp.gateway` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.mcp.gateway --apply 'g: builtins.removeAttrs g [ "source" ]'` |
| MCP target | 各 [`mcp/NAME/module.nix`](../../mcp) の `dotfiles.mcp.targets` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`containers/module.nix`](../../containers/module.nix) の `dotfiles.containers` contract、[`container-backend.nix`](../../containers/impl/container-backend.nix)、各 [`containers/NAME/module.nix`](../../containers) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.containers.services --apply builtins.attrNames` |
| MCP front | [`mcp/module.nix`](../../mcp/module.nix) が target から導く `dotfiles.mcp.fronts` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.mcp.fronts`。稼働は `systemctl status mcp-front-<name>` |
| telemetry | [`telemetry/module.nix`](../../telemetry/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.telemetry` |
| 品質 gate | server、database、provisioning は [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix)、MCP package と target は [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.virtualisation.oci-containers.containers.sonarqube` |

target は provider、port、起動関数、backend unit、probe を持つ。front は target から一度だけ導かれ、backend unit を `requires` と `after` に持つ。agentgateway は全 front を一つの URL へ公開するが、front service の依存は持たない。credential、container、host process の境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に `dotfiles-doctor` で宣言と実状態の収束を確認する。
