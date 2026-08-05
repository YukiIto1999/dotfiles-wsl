# AI tooling

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

AI CLI の binary、共通資材、MCP 接続は別の経路で配備する。binary は upstream から `~/.local/bin` へ更新する可変物であり、rules、skills、agents、managed config と MCP service は NixOS generation が宣言する。対象の追加や変更箇所は[変更箇所](../reference/change-map.md)を参照する。

## 配備の流れ

```text
clis/assets/AGENTS.md ───────────────┐
clis/assets/agents/*.md ── CLI変換 ─┤
clis/assets/skills/* ── live link ──┼─ Home Manager ──► 各 CLI の設定領域
flake input の plugin skills ─┘

AI CLI ── HTTP /mcp ──► agentgateway ── HTTP ──► 常駐 MCP front (target ごと)
      │                                              │
      │                                              └─► host process または Docker backend
      ├── LSP ──► language server (PATH 上の binary)
      └── OTLP ──► telemetry collector
```

[`clis/module.nix`](../../clis/module.nix) の `my.clis` が、binary 名、rules、skills、agents、gateway file、入手方法の roster contract を定義する。個別 module の一覧が正本であり、この文書には version、skill 名、agent 名を転記しない。

`dotfiles-install-clis` は roster から installer を生成し、通常ユーザーの `~/.local/bin` を更新する。systemd timer も同じ command を日次実行する。Nix は入手方法と固定配置先を宣言するが、CLI binary の内容や version を system closure に固定しない。

## 共通 rules、agent、skill

[`clis/assets/AGENTS.md`](../../clis/assets/AGENTS.md) は全 CLI へ配る共通 rules の正本である。Home Manager が CLI ごとの規定 path に同じ source を配備する。

静的 agent の正本は [`clis/assets/agents/`](../../clis/assets/agents) に置く。Claude Code は Markdown をそのまま使い、Codex は TOML、OpenCode は frontmatter 付き Markdown へ build 時に変換する。Antigravity は `agentsDir = null` であり、静的 agent を配備しない。CLI ごとの変換は [`clis/module.nix`](../../clis/module.nix) と各 CLI module が所有する。

local skill は [`clis/assets/skills/`](../../clis/assets/skills) から自動検出し、checkout への out-of-store symlink として各 CLI へ配る。既存 skill の本文変更は rebuild なしで見えるが、追加、削除、名前変更は Nix 評価と rebuild が必要になる。plugin 由来 skill は [`flake.nix`](../../flake.nix) の固定 input から検出し、Nix store path を配備する。local と plugin の同名 skill は評価時に拒否する。

## CLI ごとの差

| CLI | Nix が管理する設定 | 静的 agent | agentmemory の自動 capture |
|---|---|---:|---:|
| Claude Code | `/etc/claude-code` の managed settings と MCP、初回だけ作る user settings | あり | managed lifecycle hooks |
| Codex | `/etc/codex/config.toml`、checkout 固有 config、初回だけ作る user config | あり | system config の lifecycle hooks |
| OpenCode | Home Manager 配備の config | あり | 自動ロードされる capture plugin |
| Antigravity | Home Manager 配備の MCP config | なし | 宣言なし |

Claude Code の user settings と Codex の user config は CLI が更新し得るため、Home Manager activation は file がない場合か symlink の場合だけ seed を書く。managed settings と checkout 固有 config は Nix が所有し、doctor が immutable source と比較する。OpenCode と Antigravity の gateway config は Home Manager が所有する。

## agentgateway と MCP target

各 [`mcp/NAME/module.nix`](../../mcp) が `my.mcp.targets.<name>` を一度だけ宣言し、収集は flake が行う。target は front の port と、その port で Streamable HTTP を話す起動 command を宣言する。target 名は gateway が公開する tool prefix の安定 contract であり、package 名とは別である。

[`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) は target 宣言を agentgateway の YAML へ畳み込み、systemd service を設定ユーザーで起動する。各 AI CLI は一つの gateway URL だけを持ち、個別 MCP server の command や backend port を知らない。front は target ごとの systemd service として常駐し、gateway は loopback の HTTP へ接続するだけである。downstream の session が増えても process は増えない。stdio しか話さない front は `mcp-proxy` が HTTP へ載せる。

target を持つかどうかは、agent が消費するかで決まる。agent が読み書きするものは target、人が browser で開くだけのものは endpoint に留める。SonarQube のように両方あるものは両方持つ。container application の endpoint は [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix)、agent が使う target は [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix) が宣言する。

browser を使う target は二つある。[`playwright`](../../mcp/playwright) は通常の操作、snapshot、screenshot、console、network の観測に使う。[`chrome-devtools`](../../mcp/chrome-devtools) はperformance trace、heap、Lighthouseなどの詳細観測に使う。両targetはisolated browser contextで動くため、sessionを共有すると仮定しない。chromium は `my.contract.mcp.chromium` で共有し、二つの closure を持たない。

MCP target の実装は、host process だけで完結するものと常駐 backend を使うものに分かれる。完全な target 一覧は各 [`mcp/NAME/module.nix`](../../mcp) の `my.mcp.targets` を参照する。

session の生存は downstream が response body を保持しているかで決まる。pending の SSE stream は 15 秒ごとに comment frame を返し、body が生きている GET stream は idle TTL を超えても reap されない。idle の 30 分は body の終了時刻から数え、明示 DELETE は即座に session を削除する。

## Docker backend

[`containers/module.nix`](../../containers/module.nix) は `dotfiles.containers` の型付き service contract、Docker daemon、`dotfiles-backends` network、OCI image の同期を所有する。[`container-backend.nix`](../../containers/impl/container-backend.nix) は container 宣言と systemd 依存を組み立て、必要な host port だけを `127.0.0.1` に publish する。front は host loopback の backend port に接続する。

application 固有の contract と container 宣言は各 application の [`containers`](../../containers) unit が所有する。対応する [`mcp`](../../mcp) unit には front package と target だけを置き、SOPS、OCI container、provisioning は宣言しない。SonarQube の front は container owner が公開する endpoint、admin password file、backend unit を型付き contract から読む。

全 container は暗黙 pull を無効にしている。upstream image は digest 固定の宣言と `dotfiles-sync-images`、Nix 生成 image は `imageFile` が取得を担当する。image があるかは docker が答えるので、同期の状態を別に記録しない。操作手順は [OCI images](../operations/oci-images.md)を参照する。

## agentmemory

[`containers/agentmemory/module.nix`](../../containers/agentmemory/module.nix) は agentmemory engine の Docker container、lifecycle hook、OpenCode capture plugin を配備する。保存先は host の `/var/lib/agentmemory/data` を container の `/data` へ mount した領域であり、Nix store には保存しない。[`mcp/memory/module.nix`](../../mcp/memory/module.nix) は engine の型付き endpoint と client version を読み、MCP front と memory target を配備する。

```text
Claude Code / Codex hooks ─┐
OpenCode capture plugin ───┼─► 127.0.0.1 の engine API ─► /var/lib/agentmemory/data
                           │
AI CLI ─► gateway ─► memory MCP front ──────────────────┘

session start ─► recall と context 注入
session event ─► 観測、要約、reflect、consolidation
```

Claude Code と Codex は `/run/current-system/sw/bin/agentmemory-hook-*` を呼ぶ。OpenCode は Home Manager が配備した capture plugin を自動ロードする。Antigravity は gateway 経由の memory target を使えるが、自動 capture の設定はない。現在の差異は個別 CLI module と managed config が正本である。

agentmemory の LLM 処理は外部の OpenAI 互換 endpoint を使う。API key は SOPS template が runtime の環境ファイルへ展開し、Docker が container 環境へ渡す。session の prompt や code が外部 provider へ送られる境界を持つ。

## 正本

| 変更対象 | 正本 |
|---|---|
| CLI roster と配備差 | [`clis/module.nix`](../../clis/module.nix) と各 CLI module |
| 共通 rules | [`clis/assets/AGENTS.md`](../../clis/assets/AGENTS.md) |
| local agent と skill | [`clis/assets/agents/`](../../clis/assets/agents)、[`clis/assets/skills/`](../../clis/assets/skills) |
| plugin skill source | [`flake.nix`](../../flake.nix) と `flake.lock` |
| MCP target | 各 [`mcp/NAME/module.nix`](../../mcp) |
| gateway と Docker backend の共通層 | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix)、[`containers/module.nix`](../../containers/module.nix)、[`containers/impl/container-backend.nix`](../../containers/impl/container-backend.nix) |
| language server の roster | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.lsp` |
| CLI ごとの LSP 登録形式 | 各 CLI の module |
| 使用量の観測 | [`telemetry/module.nix`](../../telemetry/module.nix) |
| agentmemory backend、hook、OpenCode plugin | [`containers/agentmemory/module.nix`](../../containers/agentmemory/module.nix) と [`containers/agentmemory/`](../../containers/agentmemory) |
| memory MCP front と target | [`mcp/memory/module.nix`](../../mcp/memory/module.nix) と [`mcp/memory/`](../../mcp/memory) |
| Crawl4AI backend と API token | [`containers/crawl4ai/module.nix`](../../containers/crawl4ai/module.nix) |
| Crawl4AI MCP front と target | [`mcp/crawl4ai/module.nix`](../../mcp/crawl4ai/module.nix) |
| SearXNG backend、設定、server secret | [`containers/searxng/module.nix`](../../containers/searxng/module.nix) |
| SearXNG MCP front と target | [`mcp/searxng/module.nix`](../../mcp/searxng/module.nix) |
| SonarQube server、database、provisioning、secret | [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix) |
| SonarQube MCP package、front、target | [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix) と [`mcp/sonarqube/`](../../mcp/sonarqube) |

## LSP と観測

language server の binary は `toolchain` が PATH へ置き、roster も同じ unit が持つ。CLI ごとに登録形式が違うため、変換は各 CLI の module が持つ。Claude Code は `settings.json` に LSP の設定 key を持たないので、plugin と marketplace を Nix store に生成して managed settings から指す。OpenCode は設定ファイルの `lsp` block へ直接書く。LSP を持たない CLI には配らない。

同じ拡張子を二つの server が宣言すると、先に登録された片方だけが動き、もう片方は黙って起動しない。roster と各 CLI の登録の一致、拡張子の衝突は `lsp-registration` が検査する。

telemetry collector は OTLP を loopback で受け、生の record を残す。集計しないのは、どの操作で token を使ったかを後から追うためである。CLI は endpoint を `my.contract.telemetry` から取るので、port を変えても CLI 側の宣言は変わらない。

配備後の調査は [Doctor](../operations/doctor.md)、構成変更の適用は [Rebuild](../operations/rebuild.md)に従う。
