# ツール構成

**読み手:** 正本の場所と現在値の取り方を調べたい人。作業中に読む。

この文書は、導入しているツールとserviceを区分ごとに示し、それぞれの正本を指す。roster、version、件数、行番号は転記しない。現在の値は各commandで評価結果から取る。

## CLI

| 区分 | 正本 | 現在の値 |
|---|---|---|
| system package | [`workstation/module.nix`](../../workstation/module.nix)と各ownerの`environment.systemPackages` | `nix eval --json .#nixosConfigurations.nixos.config.environment.systemPackages --apply 'map (p: p.name)'` |
| 汎用ツール | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.packages` | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.packages --apply 'map (p: p.name)'` |
| Home Manager program | [`workstation/module.nix`](../../workstation/module.nix)の`programs` | 同じunitを参照する |
| language server | [`toolchain/module.nix`](../../toolchain/module.nix)の`dotfiles.toolchain.lsp` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.toolchain.lsp --apply builtins.attrNames` |
| 保守用devShell | [`flake.nix`](../../flake.nix)の`devShells` | `nix develop --command echo`の後に`$PATH`を確認する |

`nixfmt`はeditorと単一file、`nixfmt-tree`は`nix fmt`とrepository全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 運用command

利用者向けの入口は`dotfiles-`prefixを持つ生成commandである。[`platform/cli/module.nix`](../../platform/cli/module.nix)は`dotfiles.platform.cli.commands` optionとsystem package登録を持ち、各owner moduleは[`platform/cli/impl/mk-command.nix`](../../platform/cli/impl/mk-command.nix)を明示的にimportする。bootstrapから呼ぶflake packageの公開は[`flake.nix`](../../flake.nix)の`packages`にある。

現在の一覧は`nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.cli.commands --apply builtins.attrNames`で確認する。

## Agent、Skill、Capability

[`profiles/workstation.nix`](../../profiles/workstation.nix)が有効なAgent client、Skill、Capability、language server、identity accountを選ぶ。providerとbackendはCapabilityから導出し、profileに直接列挙しない。

| 区分 | 正本 | 現在の値 |
|---|---|---|
| Agent client | [`agents/clients/`](../../agents/clients)と`dotfiles.agents.clients` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.clients --apply builtins.attrNames` |
| Client installer | 各clientの`install` contractと[`agents/impl/install-agents.sh`](../../agents/impl/install-agents.sh) | `nix run .#dotfiles-install-agents -- --print-manifest` |
| Agent runtimeとworktree台帳 | [`agents/module.nix`](../../agents/module.nix)、[`agents/impl/runtime/`](../../agents/impl/runtime)、[`agents/impl/resource/`](../../agents/impl/resource) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.agents.runtime` |
| 静的role | [`agents/roles/`](../../agents/roles) | `nix eval --json .#nixosConfigurations.nixos.config.home-manager.users.nixos.home.file --apply 'f: builtins.filter (n: builtins.match "\\.claude/agents/.*" n != null) (builtins.attrNames f)'` |
| local Skill | [`skills/`](../../skills) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.skills.enabled` |
| Capability | [`capabilities/`](../../capabilities)の`dotfiles.capabilities.registry` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.capabilities.enabled` |
| plugin Skill | [`flake.nix`](../../flake.nix)のplugin inputと[`flake.lock`](../../flake.lock) | clientごとの生成設定を参照する |

依存方向は`Agent -> Skill -> Capability -> provider/runtime`である。Skill-firstはtask routingの規則であり、providerをSkill配下へ置くという意味ではない。

## Runtime observation

| 区分 | 正本 | 現在の値 |
|---|---|---|
| observationの型 | [`health/module.nix`](../../health/module.nix)のclosed union | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply 'xs: builtins.mapAttrs (_: x: x.kind) xs'` |
| 検査対象と値 | 各ownerが`dotfiles.health.observations`へ登録 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.health.observations --apply builtins.attrNames` |
| 汎用runner | [`health/module.nix`](../../health/module.nix)、[`health/impl/doctor.sh`](../../health/impl/doctor.sh)、[`health/impl/probe.sh`](../../health/impl/probe.sh) | `dotfiles-doctor --json` |
| MCP protocol | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)とそのobserver | registryの`mcp/protocol/<gateway-id>` |

owner moduleは意味と観測値を持ち、`health`は型、実行、集約だけを持つ。対象を増減するときにdoctor独自のinventoryは更新しない。

## MCPとcontainer

| 区分 | 正本 | 現在の値 |
|---|---|---|
| gateway | [`platform/mcp/gateway/module.nix`](../../platform/mcp/gateway/module.nix)の`dotfiles.platform.mcp.gateway` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.gateway --apply 'g: builtins.removeAttrs g [ "source" ]'` |
| MCP target | Capability実装が登録する`dotfiles.platform.mcp.targets` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.targets --apply builtins.attrNames` |
| Docker backend | [`platform/containers/module.nix`](../../platform/containers/module.nix)のcontractと各Capability実装 | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.containers.services --apply builtins.attrNames` |
| MCP front | [`platform/mcp/module.nix`](../../platform/mcp/module.nix)がtargetから導く`dotfiles.platform.mcp.fronts` | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.platform.mcp.fronts`。稼働は`systemctl status mcp-front-<name>` |
| telemetry | [`telemetry/module.nix`](../../telemetry/module.nix) | `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.telemetry` |
| code quality | [`capabilities/code-quality/sonarqube/`](../../capabilities/code-quality/sonarqube) | `nix eval --json .#nixosConfigurations.nixos.config.virtualisation.oci-containers.containers.sonarqube` |

MCP targetはprovider、executable、transport、lifecycle、port、backend unit、probeを持つ。generic Platformはprovider IDとapplication IDを列挙せず、Capability実装から登録値を受ける。公開agentgatewayは全frontを一つのURLへ束ねるが、front serviceの起動依存は持たない。credential、container、host processの境界は[セキュリティ設計](../architecture/security.md)を参照する。

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に`dotfiles-doctor`で宣言と実状態の収束を確認する。
