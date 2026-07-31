# AI tooling

AI CLI の binary、共通資材、MCP 接続は別の経路で配備する。binary は upstream から `~/.local/bin` へ更新する可変物であり、rules、skills、agents、managed config と MCP service は NixOS generation が宣言する。対象の追加や変更箇所は[変更箇所](../reference/change-map.md)を参照する。

## 配備の流れ

```text
share/AGENTS.md ───────────────┐
share/agents/*.md ── CLI変換 ─┤
share/skills/* ── live link ──┼─ Home Manager ──► 各 CLI の設定領域
flake input の plugin skills ─┘

AI CLI ── HTTP /mcp ──► agentgateway ── spawn ──► stdio MCP front
                                                   │
                                                   └─► host process または Docker backend
```

[`modules/clis/default.nix`](../../modules/clis/default.nix) の `my.clis` が、binary 名、rules、skills、agents、gateway file、入手方法の roster contract を定義する。個別 module の一覧が正本であり、この文書には version、skill 名、agent 名を転記しない。

`dotfiles-install-clis` は roster から installer を生成し、通常ユーザーの `~/.local/bin` を更新する。systemd timer も同じ command を日次実行する。Nix は入手方法と固定配置先を宣言するが、CLI binary の内容や version を system closure に固定しない。

## 共通 rules、agent、skill

[`share/AGENTS.md`](../../share/AGENTS.md) は全 CLI へ配る共通 rules の正本である。Home Manager が CLI ごとの規定 path に同じ source を配備する。

静的 agent の正本は [`share/agents/`](../../share/agents) に置く。Claude Code は Markdown をそのまま使い、Codex は TOML、OpenCode は frontmatter 付き Markdown へ build 時に変換する。Antigravity は `agentsDir = null` であり、静的 agent を配備しない。CLI ごとの変換は [`modules/clis/default.nix`](../../modules/clis/default.nix) と各 CLI module が所有する。

local skill は [`share/skills/`](../../share/skills) から自動検出し、checkout への out-of-store symlink として各 CLI へ配る。既存 skill の本文変更は rebuild なしで見えるが、追加、削除、名前変更は Nix 評価と rebuild が必要になる。plugin 由来 skill は [`flake.nix`](../../flake.nix) の固定 input から検出し、Nix store path を配備する。local と plugin の同名 skill は評価時に拒否する。この境界は [ADR 0003](../adr/0003-local-skills-live-symlink.md)に記録している。

## CLI ごとの差

| CLI | Nix が管理する設定 | 静的 agent | agentmemory の自動 capture |
|---|---|---:|---:|
| Claude Code | `/etc/claude-code` の managed settings と MCP、初回だけ作る user settings | あり | managed lifecycle hooks |
| Codex | `/etc/codex/config.toml`、checkout 固有 config、初回だけ作る user config | あり | system config の lifecycle hooks |
| OpenCode | Home Manager 配備の config | あり | 自動ロードされる capture plugin |
| Antigravity | Home Manager 配備の MCP config | なし | 宣言なし |

Claude Code の user settings と Codex の user config は CLI が更新し得るため、Home Manager activation は file がない場合か symlink の場合だけ seed を書く。managed settings と checkout 固有 config は Nix が所有し、doctor が immutable source と比較する。OpenCode と Antigravity の gateway config は Home Manager が所有する。

## agentgateway と MCP target

[`modules/mcp/default.nix`](../../modules/mcp/default.nix) は target module を import し、各 module が `my.mcp.targets.<name>.command` を一度だけ宣言する。target 名は gateway が公開する tool prefix の安定 contract であり、package 名とは別である。命名規則は [ADR 0004](../adr/0004-mcp-target-naming.md)を参照する。

[`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix) は target 宣言を agentgateway の YAML へ畳み込み、systemd service を設定ユーザーで起動する。各 AI CLI は一つの gateway URL だけを持ち、個別 MCP server の command や backend port を知らない。gateway は request の target prefix に応じて Nix store 上の stdio front を子 process として起動する。

MCP target の実装は、host process だけで完結するものと常駐 backend を使うものに分かれる。完全な target 一覧は [`modules/mcp/default.nix`](../../modules/mcp/default.nix) の imports と各 [`modules/mcp/servers/`](../../modules/mcp/servers) の `my.mcp.targets` を参照する。

session の生存は downstream が response body を保持しているかで決まる。pending の SSE stream は 15 秒ごとに comment frame を返し、body が生きている GET stream は idle TTL を超えても reap されない。idle の 30 分は body の終了時刻から数え、明示 DELETE は即座に session を削除する。判断は [ADR 0015](../adr/0015-mcp-session-lifecycle.md)、実装は [`pkgs/agentgateway/mcp-downstream-lifecycle.patch`](../../pkgs/agentgateway/mcp-downstream-lifecycle.patch) にある。

## Docker backend

[`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) の `mkMcpBackend` は、container、systemd 依存、`mcp-backends` network、host port の publish と doctor 宣言をまとめる。backend 同士は Docker network で接続し、host 側へ必要な port だけを `127.0.0.1` に publish する。stdio front は host loopback の backend endpoint に接続する。

全 container は暗黙 pull を無効にしている。upstream image は digest 固定の manifest と `dotfiles-sync-images`、Nix 生成 image は `imageFile` が取得を担当する。Docker cache、同期 receipt、稼働 container の収束は current generation の doctor が別々に観測する。操作手順は [OCI images](../operations/oci-images.md)を参照する。

## agentmemory

[`modules/mcp/servers/memory.nix`](../../modules/mcp/servers/memory.nix) は agentmemory engine を Docker container、MCP front を host process、lifecycle hook を system command として配備する。保存先は host の `/var/lib/agentmemory/data` を container の `/data` へ mount した領域であり、Nix store には保存しない。

```text
Claude Code / Codex hooks ─┐
OpenCode capture plugin ───┼─► 127.0.0.1 の engine API ─► /var/lib/agentmemory/data
                           │
AI CLI ─► gateway ─► memory MCP front ──────────────────┘

session start ─► recall と context 注入
session event ─► 観測、要約、reflect、consolidation
```

Claude Code と Codex は `/run/current-system/sw/bin/agentmemory-hook-*` を呼ぶ。OpenCode は Home Manager が配備した capture plugin を自動ロードする。Antigravity は gateway 経由の memory target を使えるが、自動 capture の設定はない。現在の差異は個別 CLI module と managed config が正本である。

agentmemory の LLM 処理は外部の OpenAI 互換 endpoint を使う。API key は SOPS template が runtime の環境ファイルへ展開し、Docker が container 環境へ渡す。session の prompt や code が外部 provider へ送られる境界を持つ。hook 配備は [ADR 0005](../adr/0005-agentmemory-lifecycle-hooks.md)、provider と secret の経路は [ADR 0006](../adr/0006-agentmemory-llm-provider.md)を参照する。

## 正本

| 変更対象 | 正本 |
|---|---|
| CLI roster と配備差 | [`modules/clis/default.nix`](../../modules/clis/default.nix) と各 CLI module |
| 共通 rules | [`share/AGENTS.md`](../../share/AGENTS.md) |
| local agent と skill | [`share/agents/`](../../share/agents)、[`share/skills/`](../../share/skills) |
| plugin skill source | [`flake.nix`](../../flake.nix) と `flake.lock` |
| MCP target | [`modules/mcp/default.nix`](../../modules/mcp/default.nix) と各 server module |
| gateway と Docker backend | [`modules/mcp/gateway.nix`](../../modules/mcp/gateway.nix)、[`modules/mcp/docker.nix`](../../modules/mcp/docker.nix) |
| agentmemory | [`modules/mcp/servers/memory.nix`](../../modules/mcp/servers/memory.nix) と [`pkgs/agentmemory/`](../../pkgs/agentmemory) |

配備後の調査は [Doctor](../operations/doctor.md)、構成変更の適用は [Rebuild](../operations/rebuild.md)に従う。
