# 責務と履歴の凝集

**読み手:** unit と file の境界、commit の分割基準を変更する保守者。構造変更の設計時に読む。

## 目標

実行に必要な値は一つの owner が型付き契約として公開し、consumer はその値を再構築しない。file は同じ理由で変わる定義と検査をまとめ、公開する check ID は移動後も維持する。Git 履歴は各 commit を単独で検証できる状態にし、後続 commit が先行 commit の未完成部分を埋める系列を残さない。

## Agent client の実行契約

Agent client unitはclient IDごとに設定配備とruntime wrapper適用を所有する。binaryの供給契約は通常そのclient unitが所有するが、同じbinaryをAgent以外も必要とする場合は対応するCapabilityへ置く。

- 配備する実行ファイルの絶対path
- Agent runtime wrapperの対象か、非対応か
- packageが提供する実行ファイル名

wrapper対象はclient名で判定せず、defaultを持たない列挙値で宣言する。Claude Code、Codex、OMP、OpenCodeはwrapper対象、Antigravityは非対応とする。

Codex binaryは[`capabilities/agent-session/codex/`](../../capabilities/agent-session/codex)が所有する。Agent clientとMCP adapterは同じ`runtime.executable` contractを読み、home directory、`.local/bin`、binary名を再構築しない。Agent、Skill、Capabilityの依存方向を逆転させず、CapabilityはAgent設定を参照しない。

## Check file の境界

各 unit 直下の `checks.nix` を flake からの入口として残す。入口は `checks/*.nix` を明示的に import し、check ID の重複を拒否してから attrset を合成する。公開 check ID と `allCheckNames` の意味は変えない。

`agents/checks/` は次の責務へ分ける。

- client contract
- configuration、artifact、definition、LSPの配備
- client installer
- runtime wrapper、cache、verification
- session resourceとworktree lifecycle

`health/checks/` はregistry projectionとruntime probeを分ける。runtime fixtureは出力形式と失敗条件ごとに`fixtures/`へ置き、check本体へ生成処理を集めない。

`checks/checks/` はrepository structure、runtime registry、unit boundary、documentation、static analysisへ分ける。`checks/`はunit内で許可するlayer名へ追加するが、任意のdirectory名は許可しない。

## SOPSへの寄与

MCP unit は secret の値、path、owner、mode、template を所有しない。front が既存 secret を直接読む場合に限り、secret owner の宣言へ `restartUnits` だけを寄与できる。secret の更新時に consumer を再起動するための依存であり、secret 所有権の移動ではない。

## Git履歴

次の系列は一つの目的へ統合する。

- 後続 fix で初めて先行 commit の契約が成立する
- test-only commit が同じ変更の実装より先に残る
- 同じ検査を短期間に作り直している
- 一行のコメント、style 修正、文書同期が対応する実装から分離している

非隣接 commit は SHA の近さだけで統合しない。間の commit が必要とする tree を確認し、完成した hunk を起点 commit へ移してから無関係な commit を再適用する。独立した transaction 不変条件、機械的 rename、生成 lock は、変更量が大きくても一目的なら維持する。

複数の責務を含む commit は hunk 単位で分ける。`dotfiles-doctor` の初期構造化 commit は、結果 schema、generation と managed artifact、MCP lifecycle、rebuild 文書へ分割し、それぞれの follow-up を対応先へ統合する。

## 検証

構造変更では、変更前に契約の重複と名前依存を再現する focused check を失敗させる。実装後は check ID 集合の完全一致、各 owner check、文書 link、構造 gate を確認する。

履歴変更では、全 commit について message hook、空 commit、merge、重複 subject、最終 tree、metadata を検査する。新しく作る中間 tree は、変更された Nix、shell、JSON をその commit から取り出して構文検査する。最終 source の全検証は一度だけ実行し、履歴だけの再生成では同じ source build を繰り返さない。

## 設計文書の規律

アーキテクチャ設計書（`docs/architecture/*.md`）は、現在有効なアーキテクチャの構造、境界、不変条件、設計判断の根拠のみを現在形で記述する。

- 過去の作業履歴、削除された機能の言及、旧構成の差分経過（「〜を除外した」「〜を消した」等）を設計書に書かない。
- 特定日付のスナップショットや作業ログを不変契約へ混入させない。
- 将来の検討事項や未実装の言い訳を残さず、現在成立している責務境界のみを記録する。
- 変更の経緯と理由は、Gitのコミットメッセージ（`commit-writing`）およびPR説明（`change-writing`）へ完結させる。
