# AGENTS.md

## 言語

Think in English. Respond in Japanese.

## 最優先原則

- 推奨を根拠とともに先に出し、選択肢を並べただけで終わらせない。
- 事実にはファイルパス・行番号・コマンド出力・一次資料 URL のいずれかを添える。
- 提案・生成・編集の前に、既存のスタイル・規約・構成を確認する。
- 汎用ベストプラクティスより、現在の構成・目的・制約を優先する。
- 自分の出力、外部情報、subagent / skill の結果は鵜呑みにせず一次資料で裏取りする。
- 失敗したコマンドや未確認の前提は隠さず、誤りに気づいた時点で訂正する。
- 迷ったら読み取り専用で調査し、変更範囲・検証方法・リスクを明確にしてから作業する。

## 行動

- 既存コンテキストは `AGENTS.md` / `CLAUDE.md` / README / docs を確認する。
- ローカルコードの検索は Read / Grep / Glob を、広域探索・構造把握が必要なら `probe-mcp` を使う。
- ライブラリ・フレームワーク仕様は `context7` を先に使う。
- Web 調査は `web-researcher` を使う。
- GitHub 操作は対象アカウントの `github-mcp-<account>` を使う。`gh` の active user は `accounts` 先頭固定。
- 検索は `rg`、列挙は `fd`、表示は `bat`、一覧は `eza`、diff は `delta` が使える。
- JSON / YAML / HTTP は `jq` / `yq` / `xh` が使える。

## memory

- working state は native memory `~/.claude/projects/<X>/memory/` に置く。
- セッション越えで保持すべき長期情報は agentmemory MCP target `memory` に転記する。
- 同じ訂正を繰り返し受けた場合、または明示的に「覚えて」と言われた場合は memory に保存する。
- 資格情報、トークン、秘密鍵、個人情報、未検証の推測、短期タスク専用の作業メモは memory に保存しない。

## subagents

複雑な作業、独立した視点が必要な作業、レビュー・セキュリティ確認では subagent を使う。

| 目的 | subagent |
|---|---|
| コードベース探索、定義・参照検索 | `explorer` |
| 実装計画、phase 分割、リスク整理 | `planner` |
| 設計判断、影響範囲、ADR 起案 | `architect` |
| 計画に沿った実装、テスト、検証 | `implementer` |
| diff review、severity 付き指摘 | `reviewer` |
| 脅威モデリング、攻撃経路整理 | `security` |
| UI 方針、コンポーネント分解 | `designer` |

## skills

繰り返し作業は手で再現せず、対応する skill を読む。

| 目的 | skill |
|---|---|
| 外部 Web の深い調査 | `web-researcher` |
| commit / PR 前の diff review | `code-reviewer` |
| staged diff から commit message 作成 | `git-commit-writer` |
| branch diff から PR description 作成 | `pr-description-writer` |
| Conventional Commits から changelog 作成 | `changelog-generator` |
| セキュリティ分析 | `codex-security` |
| UI / frontend 方針 | `frontend-design` |
| skill 作成 | `skill-creator` |

## dotfiles

- 初回 setup: `sudo bash ~/dotfiles-wsl/scripts/bootstrap.sh`
- 通常 rebuild: `sudo nixos-rebuild boot --flake "git+file:///home/nixos/dotfiles-wsl?submodules=1#nixos" -L` 後、PowerShell で `wsl -t NixOS && wsl -d NixOS`。
- 実用状態検証: `~/dotfiles-wsl/scripts/doctor.sh`
- 不要物整理: `~/dotfiles-wsl/scripts/cleanup-local.sh --delete`。system backup と VS Code server も整理する場合は `--system --vscode-server` を付ける。
- CI 相当 check: `cd ~/dotfiles-wsl && nix flake check "git+file://${PWD}?submodules=1" -L`
- flake input 更新: `cd ~/dotfiles-wsl && nix flake update`
- `/etc/nixos` は `~/dotfiles-wsl` repo root への symlink。
- flake root は repo root。`etc/nixos/` は NixOS / Home Manager module 置き場であり、単独 flake ではない。
- CLI 本体（`claude` / `codex` / `opencode` / `agy`）は Nix から入れない。公式 upstream 配布を `~/.local/bin` に置き、dotfiles は設定・agents・skills を管理する。
- `/home/nixos` の設定ファイルは `~/dotfiles-wsl/home/nixos`、`~/dotfiles-wsl/share`、`~/dotfiles-wsl/templates` から再生成される。
- MCP は agentgateway 経由で集約される。全 CLI が同じ gateway URL を使う。
- subagent と skill は `~/dotfiles-wsl/share/agents/`、`~/dotfiles-wsl/share/skills/` から全 CLI へ配備される。
- 共通ルールは `~/dotfiles-wsl/share/AGENTS.md` から全 CLI へ配備される。
- GitHub アカウントは `~/dotfiles-wsl/flake.nix` の `accounts` list で宣言する。
- 資格情報は `~/dotfiles-wsl/secrets/secrets.yaml` に集約する。

## 禁則

- dotfiles で管理している設定ファイルは直接編集しない。変更は dotfiles に入れる。
- パッケージマネージャでグローバルインストールしない。パッケージは nix / devenv で導入する。
- `gh auth login` / `gh auth switch` は使わない。トークン交替は `sops ~/dotfiles-wsl/secrets/secrets.yaml` 編集後の rebuild で行う。
- 資格情報を平文に書かない。GitHub PAT は `~/dotfiles-wsl/secrets/secrets.yaml`(SOPS + age)に集約する。
- commit message に AI attribution(`Co-authored-by`、`Generated with ...`)を入れない。commit-msg hook が block する。
