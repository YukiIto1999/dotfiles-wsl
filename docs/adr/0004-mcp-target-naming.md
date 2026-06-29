# 0004. MCP target 名

## 状態

Accepted

## 背景

旧命名は `my.mcp.targets` の key(gateway が全 CLI・skill に公開する tool prefix)にも `-mcp` suffix を
持ち、`pkgs/` の build 定義名(実装の都合の名前)と混同していた。target 名は skill/agent が
`<target>_<tool>` の形で直接参照する安定した公開インターフェースであり、実装パッケージのリネームで変わってはならない。

## 決定

`my.mcp.targets` の key から `-mcp` suffix を除く(`context7` / `probe` / `searxng` / `crawl4ai` /
`memory` / `playwright` / `github-<account>`)。`pkgs/` 配下の build 定義名は `-mcp` suffix を保持して
よい。target 名(公開インターフェース)と実装パッケージ名は区別する。

## 検討した代替案

pkgs 名と target 名を完全に一致させる案(`-mcp` 付き target)。実装パッケージのリネームがそのまま
tool prefix が変わり、全 skill/agent が呼び出せなくなるため不採用。

## 影響

tool prefix が `<target>_<tool>` に短縮される。この変更は リポジトリ内(`share/AGENTS.md`、skills、agents)の
参照更新で完結する。外部公開 API ではないため、外部互換性の維持は不要。
