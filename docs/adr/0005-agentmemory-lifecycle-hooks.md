# 0005. agentmemory lifecycle hooks の全 CLI 共通配備

## 状態

Accepted

## 背景

agentmemory は MCP target `memory` として稼働していたが、書き込みが「モデルの自発的な転記」に
依存し、実データはほぼ空だった。engine には hooks 由来の観測を記憶へ変換するパイプラインが
実装済みで、取り込み導線の欠落だけが原因だった。engine パッケージは Claude Code / Codex 用の
lifecycle hook script と OpenCode 用 capture plugin を同梱している。

## 決定

engine 同梱 script を `pkgs/agentmemory` で `agentmemory-hook-<event>` として bin 化し、
`modules/mcp/servers/memory.nix` に配備宣言を集約する。各 CLI は自分の設定形式で
`/run/current-system/sw/bin` の stable 名を参照する。

- Claude Code: `managed-settings.json` の `hooks`(12 event)
- Codex: `/etc/codex/config.toml` のインライン `[hooks]`(upstream 準拠 6 event)
- OpenCode: `~/.config/opencode/plugins/` への capture plugin 配置(自動ロード)

recall 側は `session-start` の `AGENTMEMORY_INJECT_CONTEXT=true` による注入で自動化する。
LLM provider は設定しない。noop mode で開始し、要約 / reflect / consolidation は provider key
導入時に有効化する。この時点の判断は履歴として残し、provider の導入は
[ADR 0006](0006-agentmemory-llm-provider.md)で変更する。

## 検討した代替案

- `share/AGENTS.md` の指示強化のみ: 1 か月の実績で書き込みゼロが実証済みのため不採用。
- upstream の Claude plugin / Codex plugin としての導入: install が imperative になり
  nix の宣言管理から外れるため不採用。
- `memory_claude_bridge_sync` による native MEMORY.md 同期: engine コンテナは `/data` しか
  見えず host の MEMORY.md に到達できないため不採用。

## 影響

全 CLI のセッションが自動で観測・記憶化され、session 開始時に注入される。hook は
fire-and-forget の REST POST で、engine 停止時も CLI の動作を阻害しない。初回のみ
Claude Code は managed hooks の承認、Codex は `/hooks` の trust 承認が必要。
