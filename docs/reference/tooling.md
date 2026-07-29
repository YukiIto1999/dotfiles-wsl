# ツール構成

この文書は、導入しているツールと service を役割別に示す。version、依存、生成物の正本は Nix 宣言であり、この文書へ固定値を重ねて持たせない。2026 年 7 月の利用状況と改善案は[ツール構成監査](../audits/2026-07-29-tooling.md)に分離した。

## CLI

| 区分 | ツール | 正本 |
|---|---|---|
| system package | wget、curl、Vim、SOPS、age、bubblewrap | `modules/user/default.nix:22-28`、`modules/clis/codex/default.nix:87-88` |
| user package | Node.js、Python、uv、ripgrep、fd、jq、yq、xh、ShellCheck、shfmt、just、nixfmt、nixd、devenv、nvd | `modules/user/default.nix:40-56` |
| Home Manager program | Bash、GitHub CLI、fzf、zoxide、bat、eza、direnv、nix-direnv | `modules/user/default.nix:61-79` |
| 保守用 devShell | actionlint、deadnix、jq、nixfmt-tree、ShellCheck、statix、Taplo、yq | `flake.nix:103-116` |

`nixfmt` は editor と単一ファイル、`nixfmt-tree` は `nix fmt` と repository 全体の検査を担当する。[Nixfmt README](https://github.com/NixOS/nixfmt/blob/master/README.md)

## 運用 command

利用者向けの入口は `dotfiles-rebuild`、`dotfiles-doctor`、`dotfiles-install-clis`、`dotfiles-sync-images`、`dotfiles-cleanup`、`dotfiles-wsl-restart-required`、`dotfiles-sops-enroll` である。

command は `writeShellApplication` で生成し、必要な CLI を runtime closure に含める。定義は `modules/commands.nix:306-419` と `modules/secrets.nix`、bootstrap から呼ぶ flake package の公開箇所は `flake.nix:90-101` にある。

## AI CLI と agent

| 区分 | 構成 | 正本 |
|---|---|---|
| AI CLI | Claude Code、Codex、OpenCode、Antigravity | `modules/clis/default.nix:8-100` |
| 静的 agent | architect、designer、explorer、implementer、planner、reviewer、security | `share/agents/` |
| local skill | changelog-generator、code-reviewer、git-commit-writer、ja-writing、pr-description-writer、web-researcher | `share/skills/` |
| plugin skill | superpowers、codex-security、frontend-design、skill-creator が配備する skill | `flake.nix`、`flake.lock` |

local skill と plugin skill は合わせて 28 件ある。評価後の一覧は `config.my.doctor.skillNames` で確認する。plugin の追加、更新、削除は [AI tooling](../architecture/ai-tooling.md) の責務境界に従う。

## MCP と service

| 区分 | 構成 | 正本 |
|---|---|---|
| gateway | agentgateway、systemd service | `modules/mcp/gateway.nix`、`pkgs/agentgateway/` |
| MCP target | codex、context7、crawl4ai、github-account-1、github-account-2、github-account-3、memory、playwright、probe、searxng | `modules/mcp/default.nix:41-52`、`modules/mcp/servers/` |
| Docker backend | agentmemory、Crawl4AI、SearXNG、Valkey | `modules/mcp/docker.nix` と各 server module |
| host process | Codex、Context7、GitHub MCP、Playwright、Probe と各 backend の stdio front | 各 server module |

agentgateway は 10 target を一つの HTTP endpoint へ公開し、4 AI CLI が同じ target 名を使う。credential、container、host process の境界は[セキュリティ設計](../architecture/security.md)を参照する。

## 役割

| 構成 | 役割 |
|---|---|
| devenv、direnv、nix-direnv | project-local な開発環境を構築し、checkout ごとの package と環境変数を有効化する |
| SearXNG、Crawl4AI | SearXNG が URL を列挙し、Crawl4AI が本文を取得する |
| Context7、Probe | Context7 が library の一次資料を引き、Probe がローカル repository の構造を探索する |
| agentmemory | lifecycle hook と MCP を通じて長期記憶を扱う |
| 3 GitHub account | account ごとの credential と repository 権限を分離する |
| curl、xh | curl を script の安定した HTTP client、xh を対話操作に使う |
| jq、yq | JSON と YAML を対話操作し、運用 command には同じ tool を runtime closure として固定する |

構成を変更するときは[変更箇所](change-map.md)で正本を特定し、適用後に `dotfiles-doctor` で宣言と実状態の収束を確認する。
