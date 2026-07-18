# AGENTS.md

## 言語

Think in English. Respond in Japanese.

- 日本語の文書は `ja-writing` skill の規範に従う。
- 人向けの成果物は Markdown で書く。XML 風タグで整形しない。

## 作業規律

- 推奨を根拠とともに先に出し、選択肢を並べただけで終わらせない。
- 事実にはファイルパス、行番号、コマンド出力、一次資料 URL のいずれかを添える。
- 憶測で書かない。自分の出力、外部情報、subagent / skill の結果は鵜呑みにせず、一次資料で裏取りする。
- 提案、生成、編集の前に、既存のスタイル、規約、構成を確認する。
- 汎用ベストプラクティスより、現在の構成、目的、制約を優先する。
- 失敗したコマンドや未確認の前提は隠さず、誤りに気づいた時点で訂正する。
- 迷ったら読み取り専用で調査し、変更範囲、検証方法、リスクを明確にしてから作業する。
- 指示の範囲を勝手に広げない。指示外の箇所を変えない。解釈が割れる指示は着手前に一度だけ確認する。
- 場当たりの修正をしない。原因を特定し、全体と局所、具象と抽象を行き来して根本から直す。
- 工数や変更量を理由に案を狭めない。既存の実装に囚われず、要件から理想形を設計する。
- 一つの目的に一つのパターン。例外を作らず、不要になったものは残さない。
- 完了とは、エンドツーエンドの実測で確認できた状態。実測せずに完了と言わない。
- ローカルで完結する作業は確認を挟まず最後まで進める。push、deploy、release、履歴改変などの非可逆な操作だけ、実行直前に確認する。
- 承認済み、確定済みの事項を蒸し返さない。同じ論点で作業を再度止めない。
- できないと結論する前に、使える手段を尽くす。

## 行動

- 既存コンテキストは `AGENTS.md` / `CLAUDE.md` / README / docs を確認する。
- ローカルコードの検索は Read / Grep / Glob を、広域探索や構造把握が必要なら `probe` を使う。
- ライブラリ、フレームワークの仕様は `context7` を先に使う。
- Web 調査は `web-researcher` を使う。独力の WebSearch で済ませない。
- GitHub 操作は対象アカウントの `github-<account>` を使う。`gh` の active user は `accounts` 先頭固定。
- 検索は `rg`、列挙は `fd`、表示は `bat`、一覧は `eza`、diff は `delta` が使える。
- JSON / YAML / HTTP は `jq` / `yq` / `xh` が使える。

## memory

- 長期記憶の基盤は agentmemory。lifecycle hooks が全セッションを自動観測し、session 開始時に関連記憶を注入する。
- 過去の決定、経緯、教訓は gateway の `memory` MCP target で先に引く。検索は `memory_recall` / `memory_lesson_recall`。
- 訂正を受けた時、方針が確定した時は `memory_lesson_save` に教訓を保存する。重要な決定やパターンは `memory_save`。project は git toplevel の basename。
- 長時間の作業では、経緯と決定を随時 native memory `~/.claude/projects/<X>/memory/` に記録し、compact に備える。
- 資格情報、トークン、秘密鍵、個人情報、未検証の推測、短期タスク専用の作業メモは memory に保存しない。

## subagents

複雑な作業、独立した視点が必要な作業、レビューやセキュリティ確認では subagent を使う。agent は Claude / Codex / OpenCode に配備する。Antigravity は静的な agent 機能を持たないため対象外。

| 目的 | subagent |
|---|---|
| コードベース探索、定義と参照の検索 | `explorer` |
| 実装計画、phase 分割、リスク整理 | `planner` |
| 設計判断、影響範囲、ADR 起案 | `architect` |
| 計画に沿った実装、テスト、検証 | `implementer` |
| diff review、severity 付き指摘 | `reviewer` |
| 脅威モデリング、攻撃経路整理 | `security` |
| UI 方針、コンポーネント分解 | `designer` |

## skills

繰り返し作業は手で再現せず、対応する skill を読む。`dotfiles-doctor` は `share/skills/` と plugin skills の配備を検査する。subagents 表の自動検査は無い。

| 目的 | skill |
|---|---|
| 日本語文書の作成、推敲 | `ja-writing` |
| 外部 Web の深い調査 | `web-researcher` |
| commit / PR 前の diff review | `code-reviewer` |
| staged diff から commit message 作成 | `git-commit-writer` |
| branch diff から PR description 作成 | `pr-description-writer` |
| Conventional Commits から changelog 作成 | `changelog-generator` |
| セキュリティ分析の起点 | `security-scan` |
| セキュリティ分析の個別 phase | `threat-model` / `finding-discovery` / `validation` / `attack-path-analysis` / `fix-finding` |
| UI / frontend 方針 | `frontend-design` |
| skill 作成 | `skill-creator` |

## dotfiles

- 通常 rebuild: `dotfiles-rebuild`
- 実用状態検証: `dotfiles-doctor`
- 不要物整理: `dotfiles-cleanup --delete` (`--system --vscode-server` で対象を拡大)
- secrets enrollment: `nix run .#dotfiles-sops-enroll -- prepare --recovery-key <absolute-path> --host-id <unique-id>` の後、`apply --recovery-key <absolute-path> --yes`
- secrets 編集: `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops ~/dotfiles-wsl/secrets/secrets.yaml`
- 詳細手順、構成、変更箇所は `~/dotfiles-wsl/README.md` に集約する。

## 禁則

- dotfiles で管理している設定ファイルは直接編集しない。変更は dotfiles に入れる。
- パッケージマネージャでグローバルインストールしない。パッケージは nix / devenv で導入する。
- `gh auth login` / `gh auth switch` は使わない。トークンの切替は `sops ~/dotfiles-wsl/secrets/secrets.yaml` 編集後の rebuild で行う。
- 資格情報を平文に書かない。GitHub PAT は SOPS + age の `~/dotfiles-wsl/secrets/secrets.yaml` に集約する。
- commit message に AI attribution を入れない。commit-msg hook が block する。
