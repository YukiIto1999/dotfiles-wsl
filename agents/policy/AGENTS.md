# AGENTS.md

## 言語

Think in English. Respond in Japanese.

- 日本語で成果物（README、仕様、設計文書、ADR、解説、コミットメッセージ、PR）を作成または編集する際は、ドラフト時および完了前に必ず `ja-writing` skill を読み、その推敲規律に従う。
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
- session が提示する専用ツール（LSP / Read / Grep / Glob / Edit / Write 等）を利用可否の正本とし、調査・参照追跡・編集の第一選択とする。
- シェルの CLI は、専用ツールでは担えない統計・集計・パイプライン処理や構文一括書き換え（`ast-grep`）、ファイル列挙（`fd`）、表示（`bat` / `eza`）、差分表示（`delta`）に限定して使う。shell の exact search には `rg`、indexed semantic search には `zg query` を使う。index の作成、再構築、削除は agent が暗黙に実行しない。
- JSON / YAML / HTTP は `jq` / `yq` / `xh` が使える。

## 資源と検証

- managed runtime wrapper を持つ client では、agent runtime が `TMPDIR`、全 project 共通の `CARGO_HOME` と `XDG_CACHE_HOME`、project 単位の build cache を割り当てる。利用者が明示した値は空文字列も含めて変更せず、project が明示する Cargo `target-dir` も上書きしない。session ごとの cache を `/tmp` に作らない。
- `nix build` は明示した out-link が必要な場合を除き `--no-link`、`nix-build` は `--no-out-link` を使う。agent runtime の shim を絶対 path で迂回しない。
- 編集中は変更箇所に対応する focused check を使う。高コストな最終確認は `dotfiles-agent-verify -- COMMAND [ARG...]` から一度だけ実行する。同じ source、command、環境で成功済みの確認を繰り返さない。
- agent session 内で linked worktree を作るときは `git worktree add` または `dotfiles-agent-worktree add` を使い、runtime の管理入口を迂回しない。終了時に自動削除できるのは、台帳所有、clean、HEAD 不変、利用中 process なしをすべて満たす worktree だけである。
- 自分が起動した server、container、background process と作成した一時資源を作業中に把握し、終了時に自分の所有物だけ停止、回収する。既存物や所有者不明の資源を削除しない。

## subagents

複雑な作業、独立した視点が必要な作業、レビューやセキュリティ確認では subagent を使う。配備先の client は `## 基盤` の client の能力表が示す。

subagent は文脈の再構築と報告の読み直しの分だけ高くつく。独立して並列化できる作業にだけ使う。数回の tool 呼び出しで終わる調査、単一ファイルの編集、自分の作業の検証は自分で行う。委譲したら結果を再導出せず、その報告を使って先に進む。

@subagentRoster@

## skills

繰り返し作業は手で再現せず、対応する Skill を読む。下表は全 client に配る共通 Skill の責務を示す。client 固有または plugin 由来の Skill は session が提示した名前を使い、namespace がある場合は省略しない。

依存方向は `agent → Skill → Capability → provider / runtime` とする。agent は task の委譲、context、権限、成果物の引渡しを所有し、Skill は反復する判断と手順を所有し、Capability は consumer 非依存の意味、state、security、lifecycle を所有する。provider と runtime は Capability の実装詳細であり、agent や Skill が直接選ばない。

Read / Grep / Glob / Edit / Write / Bash などの単純な local 操作、LSP、subagent と別 AI agent の起動は Skill で包まない。これらは agent が直接使う Capability とし、provider が必要な操作は対応する Skill が宣言した Capability を入口にする。単一 tool 呼出しだけを目的とする Skill は作らない。

`nix flake check` は配備対象の Skill、subagent、Skill が宣言する Capability 依存と配備配線を検査する。`dotfiles-doctor` は `dotfiles.health.observations` の全登録を観測し、Skill を含む managed artifact と current source の不一致も検査する。Skill の動作や意味と実際の agent 機能との整合は自動検査しない。

@skillRoster@

## 基盤

### MCP

全clientは単一のgatewayからprovider実装を使う。container、service、databaseを背後に持つ実装は、対応する Capability の内側に置く。agentはSkillを入口にし、Skillが宣言したCapabilityだけを要求する。provider targetの内側にあるhost process、container、databaseは起動や接続を個別に操作しない。

入口 Skill を持たない Capability は、他の Capability の依存である。agent がそれを直接起動したり、接続を個別に操作したりしない。

@capabilityRoster@

### client の能力

@clientMatrix@

### LSP

対応 client では、symbol の定義、参照、diagnostic を意味的に調べるときに LSP を使う。未対応または現在の session に提供されていない場合はローカル検索へ戻り、agent が language server を追加、再設定、直接起動しない。

### agentmemory

明示的な検索と保存は`memory`を入口にし、同Skillが`project-memory` Capabilityを使う。自動連携の経路は client ごとに異なり、client の能力表が示す。自動連携は同Skillのrecall、検証、保存判断を代替しない。

## dotfiles

- 通常 rebuild: `dotfiles-rebuild`
- 実用状態検証: `dotfiles-doctor`
- Agent client binary の更新: checkout から `nix run .#dotfiles-install-agents`
- Home Manager backup 整理: `dotfiles-cleanup --delete`
- system backup 整理: `sudo dotfiles-cleanup --delete --system`
- VS Code Server 整理: `dotfiles-cleanup --delete --vscode-server`
- secrets enrollment: `docs/operations/sops-enrollment.md` に従い、host key の公開鍵を `secrets/sops/assets/.sops.yaml` へ追加して `sops updatekeys` を実行する。
- secrets 編集: `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --config ~/dotfiles-wsl/secrets/sops/assets/.sops.yaml ~/dotfiles-wsl/secrets/sops/assets/secrets.json`
- 登録済み account の確認: `gh auth status`。account ID と個数は宣言側に無く、暗号化済み store が持つ。`gh auth login` と `gh auth switch` は使わない
- 公開入口は `~/dotfiles-wsl/README.md`、詳細手順、構成、変更箇所は `~/dotfiles-wsl/docs/README.md` から辿る。

### Agent の変更箇所

生成済みの rules、Skill、subagent、client config は直接編集しない。変更は dotfiles 内の正本に行い、作業ツリーに未コミットの変更を残さずコミットしてから `dotfiles-rebuild` を実行する（新規ファイルは `git add` を忘れない）。名前解決スタック等でキャッシュ取得が失敗する場合は `NIX_CONFIG="substitute = false" dotfiles-rebuild` でローカルビルドを継続できる。

Agent client の更新は `docs/operations/agent-clients.md`、構造は `docs/architecture/ai-tooling.md`、目的別の正本は `docs/reference/change-map.md` に従う。

## 禁則

- dotfiles で管理している設定ファイルは直接編集しない。変更は dotfiles に入れる。
- パッケージマネージャでグローバルインストールしない。パッケージは nix / devenv で導入する。
- `gh auth login` / `gh auth switch` は使わない。トークンの切替は `sops --config ~/dotfiles-wsl/secrets/sops/assets/.sops.yaml ~/dotfiles-wsl/secrets/sops/assets/secrets.json` 編集後の rebuild で行う。
- 資格情報を平文に書かない。GitHub PAT は SOPS + age の `~/dotfiles-wsl/secrets/sops/assets/secrets.json` に集約する。
- commit message は scope なし、50 文字以内の `<type>: <日本語の要約>` 一行だけにする。中黒（・）は語の簡潔な並置に限り許容する。AI attribution も commit-msg hook が block する。本文・検査・参照更新を 1 つのコミットに閉じ、未検証の中間コミットを残さない。
