## 必須制約

親の session にも subagent にも適用する。

### 完了の報告

- 実測していない結果を完了として書かない。実行した確認の結果と、失敗したコマンドや未確認の前提を隠さずそのまま報告し、誤りに気づいた時点で訂正する。原版Skillの検証表示は実行範囲の証拠であり、未観測のexit、stream、業務結果を補わない。余分な検証手順は足さない。
- 画面、CLI、TUI に現れる変更は、実際に起動して操作し、観測した結果を証拠として示すまで完了としない。型検査、単体・結合 test、lint、build は起動の代替にならない。起動できない事情があるときは完了と書かず、何を起こせなかったかと未検証である旨を述べる。

### 資源

- 編集中は変更箇所に対応する focused check を使う。高コストな最終確認は `dotfiles-agent-verify -- COMMAND [ARG...]`、それ以外の高コストな処理は `dotfiles-workload-run --seconds N -- COMMAND [ARG...]` から実行する。`--seconds` は入場してからの走行の秒数で、資源の空きを待つ秒数は別に数え、同じ秒数で待ちを打ち切って command を起動せず status 75 で返す。75 は未実行であり、成功でも失敗でもないので、同じ処理を重複投入せず、`@dotfilesDir@/docs/operations/doctor.md` の資源観測で原因を確認して空いてから投入し直す。`dotfiles-workload-run` の処理は他の作業に譲る深い検証で、T1 や設計・実装の作業が memory を要するときは取り消され、status 143 で終わる。取り消された処理は未完了であり、結果として扱わない。同じ source、command、環境で成功済みの確認を繰り返さない。
- `nix build` は明示した out-link が必要な場合を除き `--no-link`、`nix-build` は `--no-out-link` を使う。agent runtime の shim を絶対 path で迂回しない。
- managed runtime wrapper を持つ client では、agent runtime が `TMPDIR`、共有の `CARGO_HOME` と `XDG_CACHE_HOME`、checkout ごとの Cargo の build-dir を割り当てる。利用者が明示した値は空文字列も含めて変更せず、project が明示する Cargo の `target-dir` と `build-dir` も上書きしない。session ごとの cache を `/tmp` に作らない。一時的な写しで build する tool を扱うときと割当の例外は、`@dotfilesDir@/docs/architecture/ai-tooling.md` の cache 方針に従う。
- 自分が起動した server、container、background process と作成した一時資源を作業中に把握し、終了時に自分の所有物だけ停止、回収する。既存物や所有者不明の資源を削除しない。

### 配備物、資格情報、Git

- dotfiles が配備・管理する設定ファイル（生成済みの rules、Skill、subagent、client config を含む）は直接編集しない。変更は dotfiles 内の正本に行う。
- パッケージマネージャでグローバルインストールしない。パッケージは nix / devenv で導入する。
- `gh auth login` / `gh auth switch` は使わない。
- 資格情報を平文に書かない。
- repository の hook を信頼する `git config dotfiles.hooks.trusted true` は利用者だけが設定する。agent は信頼を与えず、repository 側で `core.hooksPath` を上書きしない。
- commit と push の hook を迂回しない。`--no-verify` と、push 前の検証を省く `DOTFILES_VERIFY_PUSH_BYPASS` は利用者だけが使う。hook が失敗したら原因を直すか、直せない事情を利用者へ報告する。
- commit を作る前と件名を求められたときは `commit-writing` を読み、全repository共通の形式と、同Skillが参照する正本の規則に従う。本文・検査・参照更新を 1 つのコミットに閉じ、未検証の中間コミットを残さない。
