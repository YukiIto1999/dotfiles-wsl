# AI tooling

**読み手:** 責務の境界と要素の関係を理解したい人。学習中に読む。

AI CLI の binary、共通資材、MCP 接続は別の経路で配備する。binary は upstream から `~/.local/bin` へ更新する可変物であり、rules、skills、agents、managed config と MCP service は NixOS generation が宣言する。対象の追加や変更箇所は[変更箇所](../reference/change-map.md)を参照する。

## 配備の流れ

```text
agents/shared/AGENTS.md ─────────────────┐
agents/shared/definitions/*.md ─ client変換 ─┤
agents/shared/skills/* ──────────────────┼─ Nix store ──► 各 client の設定領域
flake input の plugin skills ────────────┘

AI CLI ── HTTP /mcp ──► agentgateway ── HTTP ──► 常駐 MCP front (target ごと)
      │                                              │
      │                                              └─► host process または Docker backend
      ├── LSP ──► language server (PATH 上の binary)
      └── OTLP ──► telemetry collector
```

[`agents/module.nix`](../../agents/module.nix) の `my.agents` が、host の必要 client、共有 source、各 client の capability、配備先、gateway fragment、最終 managed file、入手方法を型付き contract として定義する。host は必要な四 client を固定値で宣言し、各 [`agents/NAME/module.nix`](../../agents) が提供する集合と照合する。

`dotfiles-install-agents` は client contract から installer を生成し、通常ユーザーの `~/.local/bin` を更新する。`dotfiles-agent-autoupdate.timer` も同じ command を日次実行する。Nix は入手方法と固定配置先を宣言するが、client binary の内容や version を system closure に固定しない。

この root は agent client 専用である。agent ではない CLI に共通の契約と配備が必要になった時点で、別の root `clis/` を作る。現在は該当する CLI がないため、空の分類は置かない。

## 共通 rules、agent、skill

[`agents/shared/AGENTS.md`](../../agents/shared/AGENTS.md) は全 client へ配る共通 rules の正本である。Home Manager が client ごとの規定 path に同じ immutable source を配備する。

静的 agent の正本は [`agents/shared/definitions/`](../../agents/shared/definitions) に置く。Claude Code は Markdown をそのまま使い、Codex は TOML、OpenCode は frontmatter 付き Markdown へ build 時に変換する。Antigravity は `definitionMode = "unsupported"` と宣言し、設定漏れと未対応を区別する。変換は各 client module が所有する。

local skill は [`agents/shared/skills/`](../../agents/shared/skills) から自動検出する。local skill と [`flake.nix`](../../flake.nix) に固定した plugin skill は、どちらも Nix store source として全 client へ配備する。本文の変更にも rebuild が必要である。local と plugin、plugin 同士の同名 skill は評価時に拒否する。

## CLI ごとの差

| Client | Agent definitions | LSP | Telemetry | Agentmemory |
|---|---|---|---|---|
| Claude Code | native Markdown | plugin | managed settings | lifecycle hooks |
| Codex | rendered TOML | unsupported | unsupported | lifecycle hooks |
| OpenCode | rendered frontmatter Markdown | config | unsupported | capture plugin |
| Antigravity | unsupported | unsupported | unsupported | unsupported |

全 client が共通 rules、skills、単一 gateway の設定を持つ。Claude Code の user settings と Codex の user config は client が更新し得るため、Home Manager activation は配備先に通常 file、symlink、directory などの既存物がない場合だけ seed を書く。managed settings と checkout 固有 config は Nix が所有し、source から配備までの配線は `nix flake check` が検査する。`dotfiles-doctor` は managed file の runtime drift は検査しない。OpenCode と Antigravity の gateway config は Home Manager が所有する。

## MCP target、front、gateway

[`flake.nix`](../../flake.nix) の `dotfiles.mcp.enabledProviders` は、この host が必要とする provider unit を固定する。各 [`mcp/NAME/module.nix`](../../mcp) は `dotfiles.mcp.targets` に provider ID、port、起動関数、外部通信の要否、backend unit、読み取り用 probe を宣言する。provider roster と target が公開する provider 集合は完全一致し、provider が target を持たない状態も未承認 provider の target も評価時に拒否する。target 名は gateway が tool 名へ付ける prefix であり、package 名とは別である。

[`mcp/module.nix`](../../mcp/module.nix) は `dotfiles.mcp.targets` から `dotfiles.mcp.fronts` を一度だけ導く。front は target ごとの systemd service として常駐し、stdio server は `mcp-proxy` が Streamable HTTP へ載せる。backend を持つ target では `waitUnits` を front の `requires` と `after` の両方へ設定する。外部通信が不要な front は systemd の通信制限で loopback に閉じる。

[`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `dotfiles.mcp.gateway` は単一 endpoint の ID、port、URL、service、runtime directory、YAML source、target 名を公開する。gateway は全 front へ loopback HTTP で接続し、front service を起動依存に持たず、子 process も作らない。各 AI CLI が知る接続先はこの URL だけである。downstream の session が増えても front process は増えない。

target を持つかどうかは、agent が消費するかで決まる。agent が読み書きするものは target、人が browser で開くだけのものは endpoint に留める。SonarQube のように両方あるものは両方持つ。container application の endpoint は [`containers/sonarqube/module.nix`](../../containers/sonarqube/module.nix)、agent が使う target は [`mcp/sonarqube/module.nix`](../../mcp/sonarqube/module.nix) が宣言する。

browser を使う target は二つある。[`playwright`](../../mcp/playwright) は通常の操作、snapshot、screenshot、console、network の観測に使う。[`chrome-devtools`](../../mcp/chrome-devtools) はperformance trace、heap、Lighthouseなどの詳細観測に使う。両targetはisolated browser contextで動くため、sessionを共有すると仮定しない。chromium は `dotfiles.mcp.chromium` で共有し、二つの closure を持たない。

MCP target の実装は、host process だけで完結するものと常駐 backend を使うものに分かれる。現在の target は `nix eval --json .#nixosConfigurations.nixos.config.dotfiles.mcp.targets --apply builtins.attrNames` で取得する。

session の生存は downstream が response body を保持しているかで決まる。pending の SSE stream は 15 秒ごとに comment frame を返し、body が生きている GET stream は idle TTL を超えても reap されない。idle の 30 分は body の終了時刻から数え、明示 DELETE は即座に session を削除する。

## Docker backend

[`containers/module.nix`](../../containers/module.nix) は `dotfiles.containers` の型付き service contract、Docker daemon、`dotfiles-backends` network、OCI image の同期を所有する。[`container-backend.nix`](../../containers/impl/container-backend.nix) は container 宣言と systemd 依存を組み立て、必要な host port だけを `127.0.0.1` に publish する。front は host loopback の backend port に接続する。

application 固有の contract と container 宣言は各 application の [`containers`](../../containers) unit が所有する。対応する [`mcp`](../../mcp) unit には front package と target だけを置き、SOPS、OCI container、provisioning は宣言しない。SonarQube の front は container owner が公開する endpoint、admin password file、backend unit を型付き contract から読む。

全 container は暗黙 pull を無効にしている。upstream image は digest 固定の宣言と `dotfiles-sync-images`、Nix 生成 image は `imageFile` が取得を担当する。image があるかは docker が答えるので、同期の状態を別に記録しない。操作手順は [OCI images](../operations/oci-images.md)を参照する。

## agentmemory

[`containers/agentmemory/module.nix`](../../containers/agentmemory/module.nix) は agentmemory engine の Docker container を配備し、lifecycle hook package と OpenCode capture plugin の source を型付き contract で公開する。[`agents/module.nix`](../../agents/module.nix) と OpenCode adapter がその contract を読み、client 側へ配備する。保存先は host の `/var/lib/agentmemory/data` を container の `/data` へ mount した領域であり、Nix store には保存しない。[`mcp/memory/module.nix`](../../mcp/memory/module.nix) は engine の型付き endpoint と client version を読み、MCP front と memory target を配備する。

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
| Agent client contract と配備差 | [`agents/module.nix`](../../agents/module.nix) と各 client module |
| 共通 rules | [`agents/shared/AGENTS.md`](../../agents/shared/AGENTS.md) |
| local agent と skill | [`agents/shared/definitions/`](../../agents/shared/definitions)、[`agents/shared/skills/`](../../agents/shared/skills) |
| plugin skill source | [`flake.nix`](../../flake.nix) と `flake.lock` |
| MCP target | 各 [`mcp/NAME/module.nix`](../../mcp) の `dotfiles.mcp.targets` |
| MCP front | [`mcp/module.nix`](../../mcp/module.nix) の `dotfiles.mcp.fronts` と front service |
| 単一 gateway | [`mcp/gateway/module.nix`](../../mcp/gateway/module.nix) の `dotfiles.mcp.gateway` |
| Docker backend の共通層 | [`containers/module.nix`](../../containers/module.nix)、[`containers/impl/container-backend.nix`](../../containers/impl/container-backend.nix) |
| language server の roster | [`toolchain/module.nix`](../../toolchain/module.nix) の `my.toolchain.lsp` |
| client ごとの LSP 登録形式 | 各 client の module |
| 使用量の観測 | [`telemetry/module.nix`](../../telemetry/module.nix) |
| agentmemory backend と client package source | [`containers/agentmemory/module.nix`](../../containers/agentmemory/module.nix) と [`containers/agentmemory/`](../../containers/agentmemory) |
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
