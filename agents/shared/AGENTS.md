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
- 実測していない結果を完了として書かない。実行した確認の結果をそのまま報告し、余分な検証手順は足さない。
- ファイルとして書く成果物も必要な実質だけにする。要約の重複や定型の節を足さない。
- ローカルで完結する作業は確認を挟まず最後まで進める。push、deploy、release、履歴改変などの非可逆な操作だけ、実行直前に確認する。
- 承認済み、確定済みの事項を蒸し返さない。同じ論点で作業を再度止めない。
- できないと結論する前に、使える手段を尽くす。

## 行動

- 既存コンテキストは `AGENTS.md` / `CLAUDE.md` / README / docs を確認する。
- session が提示する Skill、subagent、MCP tool、LSP を利用可否の正本とし、対応する入口がある作業はその入口を使う。
- ローカルコードの検索は Read / Grep / Glob を、広域探索や構造把握が必要なら `rg` と `ast-grep` を使う。
- 検索は `rg`、列挙は `fd`、表示は `bat`、一覧は `eza`、diff は `delta` が使える。
- JSON / YAML / HTTP は `jq` / `yq` / `xh` が使える。

## 資源と検証

- managed runtime wrapper を持つ client では、agent runtime が `TMPDIR`、全 project 共通の `CARGO_HOME` と `XDG_CACHE_HOME`、project 単位の build cache を割り当てる。利用者が明示した値は空文字列も含めて変更せず、project が明示する Cargo `target-dir` も上書きしない。session ごとの cache を `/tmp` に作らない。
- `nix build` は明示した out-link が必要な場合を除き `--no-link`、`nix-build` は `--no-out-link` を使う。agent runtime の shim を絶対 path で迂回しない。
- 編集中は変更箇所に対応する focused check を使う。高コストな最終確認は `dotfiles-agent-verify -- COMMAND [ARG...]` から一度だけ実行する。同じ source、command、環境で成功済みの確認を繰り返さない。
- agent session 内で linked worktree を作るときは `git worktree add` または `dotfiles-agent-worktree add` を使い、runtime の管理入口を迂回しない。終了時に自動削除できるのは、台帳所有、clean、HEAD 不変、利用中 process なしをすべて満たす worktree だけである。
- 自分が起動した server、container、background process と作成した一時資源を作業中に把握し、終了時に自分の所有物だけ停止、回収する。既存物や所有者不明の資源を削除しない。

## subagents

複雑な作業、独立した視点が必要な作業、レビューやセキュリティ確認では subagent を使う。agent は Claude / Codex / OpenCode に配備する。Antigravity は静的な agent 機能を持たないため対象外。

subagent は文脈の再構築と報告の読み直しの分だけ高くつく。独立して並列化できる作業にだけ使う。数回の tool 呼び出しで終わる調査、単一ファイルの編集、自分の作業の検証は自分で行う。委譲したら結果を再導出せず、その報告を使って先に進む。

| 目的 | subagent |
|---|---|
| コードベース探索、定義と参照の検索 | `explorer` |
| 実装計画、phase 分割、リスク整理 | `planner` |
| 設計判断、影響範囲、ADR 起案 | `architect` |
| 計画に沿った実装、テスト、検証 | `implementer` |
| diff review、severity 付き指摘 | `reviewer` |
| 脅威モデリング、攻撃経路整理 | `security` |
| 実装前のUI brief | `designer` |

## skills

繰り返し作業は手で再現せず、対応する Skill を読む。下表は全 client に配る共通 Skill の責務を示す。client 固有または plugin 由来の Skill は session が提示した名前を使い、namespace がある場合は省略しない。

`nix flake check` は配備対象の Skill、subagent、MCP provider がこの rules または Skill 本文に入口を持つことと、配備配線を検査する。`dotfiles-doctor` は `dotfiles.observations` の全登録を観測し、Skill を含む managed artifact と current source の不一致も検査する。Skill の動作や意味と実際の agent 機能との整合は自動検査しない。

| 目的 | Skill |
|---|---|
| 日本語文書の作成、推敲 | `ja-writing` |
| 外部 Web の調査 | `web-research` |
| bug、test失敗、incidentの原因分析 | `bug-analysis` |
| import、call、data、runtime、build、deploymentの依存分析 | `dependency-analysis` |
| 具体的な変更のconsumer、互換性、rollout、rollback影響分析 | `impact-analysis` |
| latency、throughput、CPU、memory、I/O、DB、browser性能のbottleneck分析 | `performance-analysis` |
| 確定済みbehaviorをRED、最小GREEN、REFACTORで実装 | `tdd` |
| observableを保った内部構造の段階的な改善 | `refactoring` |
| domain概念、境界、語彙、不変条件の設計 | `domain-modeling` |
| module境界、公開contract、visualが固定済みの内部codeとcomponent構造の設計 | `code-design` |
| moduleの責務、state、artifact、粗いcontract、依存方向の設計 | `module-design` |
| moduleやprocess境界のexact contract、failure、互換性の設計 | `interface-design` |
| 固定済みmodule、責務owner、公開contract内のfailure表現、翻訳、伝播、回復、観測の設計 | `error-design` |
| planやdecisionを依存順の質問で詰める | `grilling` |
| domain設計を質問で詰めて既存文書へ残す | `grill-with-docs` |
| commit / PR 前の diff review | `code-review` |
| staged diff から commit message 作成 | `commit-writing` |
| PR、changelog、release noteの作成 | `change-writing` |
| README、ADR、仕様、報告、技術解説の作成 | `description-writing` |
| 宣言のdocumentation comment作成 | `documentation-writing` |
| 実装commentの要否判断と作成 | `comment-writing` |
| セキュリティ分析の起点 | `security-scan` |
| セキュリティ分析の個別 phase | `threat-model` / `finding-discovery` / `validation` / `attack-path-analysis` / `fix-finding` |
| 実装前のUI方針 | `ui-design` |
| Skill 作成 | `skill-creator` |

## 基盤

### MCP

全 client は単一の gateway から MCP target を使う。Skill が MCP target の利用規律を持つ場合は、その Skill を入口にする。該当する Skill がない用途だけ、次の target を直接使う。target の内側にある host process、container、database は起動や接続を個別に操作しない。

| 目的 | 入口 |
|---|---|
| 外部 Web の調査 | `web-research`。library と framework の仕様は同じ Skill の手順で `context7` を先に使う |
| GitHub 操作 | 対象アカウントの `github-<account>`。`gh` の active user は `accounts` 先頭固定 |
| code review の解析補助 | `code-review` |
| browser の操作、DOM、console、network、screenshot | `playwright` |
| browser の performance trace、heap、Lighthouse | `chrome-devtools`。Playwright と session を共有すると仮定しない |
| 別 client の独立した Codex session | `codex`。現在の client の subagent で足りる役割分担には使わない |
| 過去の経緯の検索と長期記憶の保存 | `memory`。下記の agentmemory 規律に従う |

### LSP

LSP は Claude Code と OpenCode で利用でき、Codex と Antigravity では未対応である。対応 client では、symbol の定義、参照、diagnostic を意味的に調べるときに LSP を使う。未対応または現在の session に提供されていない場合はローカル検索へ戻り、agent が language server を追加、再設定、直接起動しない。

### agentmemory

明示的な検索と保存は、全 client から gateway の `memory` target を使う。自動連携は Claude Code と Codex が lifecycle hooks、OpenCode が capture plugin を使い、Antigravity にはない。自動連携は明示的な検索と保存を代替しない。

- 過去の決定、経緯、教訓は作業前に `memory_recall` または `memory_smart_search` で引く。
- 訂正、確定した方針、再利用する決定やパターンは `memory_save` で保存する。project は git toplevel の basename とする。
- 資格情報、トークン、秘密鍵、個人情報、未検証の推測、短期タスク専用の作業メモは保存しない。

## dotfiles

- 通常 rebuild: `dotfiles-rebuild`
- 実用状態検証: `dotfiles-doctor`
- Agent client binary の更新: checkout から `nix run .#dotfiles-install-agents`
- Home Manager backup 整理: `dotfiles-cleanup --delete`
- system backup 整理: `sudo dotfiles-cleanup --delete --system`
- VS Code Server 整理: `dotfiles-cleanup --delete --vscode-server`
- secrets enrollment: `docs/operations/sops-enrollment.md` に従い、host key の公開鍵を `sops/assets/.sops.yaml` へ追加して `sops updatekeys` を実行する。
- secrets 編集: `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --config ~/dotfiles-wsl/sops/assets/.sops.yaml ~/dotfiles-wsl/sops/assets/secrets.yaml`
- 公開入口は `~/dotfiles-wsl/README.md`、詳細手順、構成、変更箇所は `~/dotfiles-wsl/docs/README.md` から辿る。

### Agent の変更箇所

生成済みの rules、Skill、subagent、client config は直接編集しない。新規ファイルは rebuild 前に `git add` して flake source に含める。

| 変更目的 | 正本 | 適用 |
|---|---|---|
| 共通 rules | `agents/shared/AGENTS.md` | `dotfiles-rebuild` |
| local Skill | `agents/shared/skills/NAME/` | `dotfiles-rebuild` |
| subagent | `agents/shared/definitions/NAME.md` | `dotfiles-rebuild` |
| plugin 由来の Skill | `flake.nix` の plugin input と `flake.lock` | `dotfiles-rebuild` |
| client の capability、変換、配備先 | `agents/NAME/module.nix` と `agents/NAME/assets/` | `dotfiles-rebuild` |
| client binary | 各 `agents/NAME/module.nix` の `install` contract | `nix run .#dotfiles-install-agents` |

Agent client の更新は `docs/operations/agent-clients.md`、構造は `docs/architecture/ai-tooling.md`、目的別の正本は `docs/reference/change-map.md` に従う。

## 禁則

- dotfiles で管理している設定ファイルは直接編集しない。変更は dotfiles に入れる。
- パッケージマネージャでグローバルインストールしない。パッケージは nix / devenv で導入する。
- `gh auth login` / `gh auth switch` は使わない。トークンの切替は `sops --config ~/dotfiles-wsl/sops/assets/.sops.yaml ~/dotfiles-wsl/sops/assets/secrets.yaml` 編集後の rebuild で行う。
- 資格情報を平文に書かない。GitHub PAT は SOPS + age の `~/dotfiles-wsl/sops/assets/secrets.yaml` に集約する。
- commit message は scope なし、50 文字以内の `<type>: <日本語の要約>` 一行だけにする。AI attribution も commit-msg hook が block する。
