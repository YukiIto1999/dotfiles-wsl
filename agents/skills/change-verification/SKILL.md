---
name: change-verification
description: Runs a repository's registered verification entry or durable regression checks for a change. Use for declared verify tiers, tests, static checks, architecture checks, contract checks, or mutation runs. Keeps detection-power analysis separate from acceptance evidence. Not for one-off acceptance through a live CLI/TUI, Windows app, or web page, even when the request says to verify it; use surface-operation for that. Does not design test-first implementation, author verification harnesses, audit standard conformance, review code, or investigate security.
---

# 変更の保証を正規の入口で確かめる

変更が壊し得る保証ごとに検査を選び、対象 project が登録した入口から実行して、実行した検査、再利用した証拠、未実行を分けて返す。
検査の方法と段の定義は対象 project と、それが採用する規範が持つ。
このSkillは入口の解決、検査の選択、実行と結果の扱いを担う。

## 保証と範囲を固定する

1. 変更の範囲（比較元の commit、変更した file と package、生成物）と、変更で影響する保証を列挙する。
   保証は「何を、どの境界で、どの観測で確かめるか」で書き、検査の名前から逆算しない。
2. 対象 project の `AGENTS.md`、`CONTRIBUTING.md`、README、CI の workflow を読み、検証入口と段の運用を確かめる。
   architecture-standard を採用する project では、段の意味と検査の選択を標準の `process/verification.md` と `structure/tests/methods.md` から読む。
   規範をこの project へ当てはめる判断が要る場合は `standard-apply` へ渡し、適合性の監査は `standard-conformance` へ渡す。
3. 次の仕事はこのSkillで行わず、担当へ渡して結果を受け取る。

| 仕事 | 担当 |
|---|---|
| .NET の test command、filter、runner の選択 | `run-tests`（platform の判定は同Skillが`platform-detection`を読む） |
| MSBuild、restore、pack の失敗や build の遅さ | `msbuild` |
| 不変条件、境界入力、操作列を生成で検査する test の設計 | `property-testing` |
| 回帰 test をどの表面の境界で書くか（Vitest Browser Mode、Playwright Test、CLI/TUI） | `surface-operation`。返った境界と入口でこのSkillが実行する |
| 検証 harness や検証Skillの作成・保守 | `create-verification-skill`、`maintain-verification-skill` |
| 実画面での受入、仕様と標準のレビュー、脆弱性の判断 | `surface-operation`、`code-review`、`security-review` |
| 検証中に動かす app や依存 service の起動 | `local-development` |

## 入口を解決する

対象projectの文書・CIと、それを実際に読むresolverから入口を確認する。dotfiles-wslの環境は、検査の段、時間の予算、入口を課さない。
対象projectが採用する入口だけを使う。Nxなどを自分から足さない。
入口が未登録なら、CIや文書が示す検査を個別に実行し、正規のT1を通したとは報告しない。不正・欠落と明示された宣言を無視した代替実行はしない。

## 編集中は変更に関係する検査だけを回す

編集のたびに全量の入口を起動せず、変更した保証に関係する検査を、project が設定した呼出し方で実行する。
同じ source と command で成功済みの確認は繰り返さない。

| 分岐 | 例（project が採用している場合） | 扱い |
|---|---|---|
| 型、analyzer、lint | `tsc --noEmit -p tsconfig.json` と `oxlint`、`cargo clippy --all-targets -- -D warnings`、Roslyn analyzer を含む `dotnet build`、`ruff check`、`shellcheck`、`actionlint`、`statix check`、`deadnix --fail` | 警告の扱いは project の設定に従い、抑制を足して通さない |
| 整形の確認 | `nixfmt --check`、`shfmt -d`、`ruff format --check`、`dotnet format --verify-no-changes` | 確認用の mode を使う |
| test | project の test command。.NET は `run-tests` が返す command | 選んだ test が発見され、実行された件数を確かめる |
| 実結合 | Testcontainers を使う project の結合 test | container の起動と破棄は test が所有する。Docker が使えなければ未実行として返し、手で container を起動して代えない |
| 構造 | project の architecture test や依存方向の検査 | 層や依存の違反を、test の削除や除外で消さない |
| 契約 | TypeSpec の `tsp compile .` の後に `git diff --exit-code -- 生成先`、project 自身の API へ `st run SCHEMA --url http://127.0.0.1:PORT` | 生成物の差分を契約の変更として読む。Schemathesis は loopback 上の自分の検証用 instance だけに向ける |
| browser の回帰 | `surface-operation` が選んだ Vitest Browser Mode または Playwright Test の既存設定 | runner が起動した browser を使い、利用者の tab を借りない |

この dotfiles repository では、変更した unit の検査を `nix build --no-link .#checks.x86_64-linux.<check>` で実行する。

## 書き込む操作を分ける

検証は作業木を変えない mode で行う。
次の操作は file、index、外部の状態を書き換えるため、変更範囲に含まれる場合にだけ実行し、実行後に差分を確かめる。

- 整形と自動修正: `nix fmt`、`treefmt`（`--ci` でも file を書き換えてから失敗する）、`cargo fmt`、`dotnet format`、`oxlint --fix`、`ruff check --fix`。
- snapshot や golden の更新、契約の再生成、lock file の更新。
- push、release、外部への送信。T2 は利用者が許可した push の pre-push hook が repository 自身の検査を実行するもので、証拠のために push しない。

失敗した test、analyzer、契約差分を、期待値の書換え、skip、除外、閾値の緩和で通さない。

## 段ごとに実行する

- T1: 最後の source 変更の後に、repository の根で解決した入口を一度実行する。
  例は `nix run --no-write-lock-file .#verify`、`devenv shell -- verify`。
- T2: push の hook に任せる。`--no-verify` は利用者だけが使う。
- T3: 全量回帰（T3a）と、mutation や長期負荷による検出力の分析（T3b）は、依頼された場合か project の契機で、別の走行として実行する。
  mutation の道具（`mutation-dotnet`、`cargo-mutants`、`@mizchi/mutator`）は project が固定した版と設定で動かし、対象の選び方と結果の分類は採用する規範の言語別の文書に従う。
  mutation の結果は report と終了 status を生のまま残し、変更の受入の完了条件に混ぜない。

終了値はそのまま記録し、どこまで実行したかは検査自身の出力で確かめる。
検査が始まっていれば、同じ終了値でも未実行とは報告しない。
期限で取り消された検査は未完了である。再実行や上限変更を決める前に、最後に終えた検査単位と残りを調べる。終了理由や進捗を特定できないときは、不明とする。

## 結果を返す

保証ごとに、検査、実行した command、終了 status、証拠の所在（log、report）を対応させる。
同じ source の成功済み証拠を再利用した場合はその command と source を示し、実行しなかった検査は理由（不要、利用不能、資源、権限、別段に属する）と一緒に残す。
失敗は最初に失敗した検査と、原因を示す出力の抜粋を返し、修正したら同じ検査を実行し直す。
受入の検査と検出力の分析を、同じ合否に畳まない。
