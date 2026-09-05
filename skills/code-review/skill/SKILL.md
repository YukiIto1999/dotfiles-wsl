---
name: code-review
description: Reviews a fixed code change and reports only evidence-backed defects introduced or worsened by that change. Use for staged, unstaged, commit, branch, or PR diffs before commit or merge. Inspect requirements, repository constraints, affected execution paths, unchanged consumers, configuration, generated artifacts, and relevant verification. Does not audit an entire repository; perform a full security, architecture, interface, test-suite, naming, or performance review; diagnose an observed incident; redesign the solution; implement fixes; or invent findings to fill severity sections.
---

# 変更がmerge可能かを監査する

成果はfindingの数ではない。今回の変更が導入または悪化させた問題を、失敗経路と影響まで証明して返す。問題がなければfindingなしとする。

## 範囲と意図を固定する

base、head、対象diff、変更の直接目的、明示要件を確認する。範囲が指定されていなければ、staged、unstaged、base branchとの差分の順で一つを選び、報告に明記する。複数の範囲を混ぜない。

repositoryの`AGENTS.md`、対象境界の規約、仕様、ADR、隣接実装を読む。実装者の説明は探索の手掛かりにできるが、正しさの根拠にはしない。

## 機械検証を先に使う

repositoryが定めるfocused test、type check、lint、static analysisを、未実行か結果が古い場合だけ実行する。提供済みの結果を盲信せず、同じsourceとcommandの新しい成功結果は繰り返さない。

formatterやlintが決定したstyleを人手findingとして再掲しない。機械検証の成功は、必要な検査が存在することや、test自体が正しいことを保証しない。

対象repositoryがSonarQubeへ登録され、同じbranch、PR、commitの解析結果を参照できる場合は、`sonarqube` MCP targetでchanged fileのissue、security hotspot、quality gateを確認する。結果は候補発見の証拠であり、findingの正本ではない。該当sourceと今回のdiffを読み、実在する失敗経路と影響を反証してから採否を決める。解析がない、またはrevisionを対応付けられない場合は利用せず、reviewを止めない。issueの状態変更やcomment投稿は行わない。

## 変更経路を追う

diffだけで判断しない。変更された値と制御flowを、入力からobservableな結果まで追う。該当する未変更のcaller、callee、consumer、設定、生成物、testも確認する。

次の二軸を分けて監査する。

- requirementとobservable behaviorを満たすか。正常系だけでなく、failure、cancel、cleanup、resource lifetime、並行実行、ordering、default、再実行を該当範囲で見る
- repository constraintと局所的な保守性を損なわないか。owner、正本、依存方向、既存mechanism、変更局所性を現在の規約と実装から見る

consumer-visible contractを変更するdiffでは、実在consumer、requiredとoptional、absence、error、side effect、ordering、互換性を確認する。新しいcontractの設計は`interface-design`へ渡す。

新しいhelper、wrapper、dependency、abstraction、fallback、commentには、削除、直接実装、既存helper、標準機能、導入済みdependencyで足りないかを対照にする。短いdiffや少ない行数そのものを目的にしない。著者がAIかどうかを推定せず、現在のrepositoryに生じる変更costだけを扱う。

## Findingを反証する

候補ごとに、具体的なinput、state、failure path、consumer、要件を示す。次に該当する候補は棄却する。

- 今回の差分が導入も悪化もさせていない
- 現在の要件、consumer、運用への影響を示せない
- 好み、著者推定、将来だけの憶測である
- 既存の機械検証が同じ問題を十分に拒否する
- 問題がない場合に備えて数を埋めている

未確認事項はfindingに偽装せず、結論を左右するevidence gapとして分ける。脅威発見と攻撃経路は`security-review`、runtime障害の原因は`bug-analysis`へ渡す。system-wideな構造とtest suite自体の品質は、このSkillのscope外として明示する。別のreview結果を受け取った場合は、同じfindingを重複して報告しない。

## Severityを付けて返す

- Critical: 現実的な経路でsecurity compromise、回復困難なdata loss、広範な停止を起こすmerge blocker
- Major: correctness、contract、resource、concurrency、運用、保守性に実害があり、merge前に直すべき問題
- Minor: 影響が限定され、mergeを止めないが、現在の要件か規約に対する具体的な問題

findingは重要度順に、`file:line`、観測事実、失敗する経路、影響、severityの根拠、最小の修正方向を書く。修正codeや再設計を始めない。空のseverity見出しは出さない。

findingがなければ、対象範囲と確認した証拠を短く示して`findingなし`と返す。Praiseは、再利用すべき具体的な判断がある場合だけ添える。
