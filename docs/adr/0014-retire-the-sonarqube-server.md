# ADR 0014: SonarQube server を廃止し、解析を repository の analyzer へ移す

**読み手:** 静的解析の置き場所を判断する人と、Capability の境界を変える人。

## Status

Accepted

## Context

`code-quality` Capability は SonarQube の server、PostgreSQL、admin password の provisioning、MCP front を作業機に置いていた。architecture-standard は SonarQube の profile を cognitive complexity(S3776)だけに絞り、各言語の lint と同じ目的の規則を重ねないと定めている。実測でも、全 project の全期間の issue 92 件はすべて S3776 だった。

この単一の規則のために、4 GiB と 1 GiB の container、DB の volume、二つの secret、timer 付きの provisioning、MCP front を保守していた。解析を verify に組み込んでいた repository は 2 つだけで、ほかは手で scanner を起動したときにしか測られなかった。履歴の書き換えで解析済みの revision が現在の branch から到達できなくなり、`code-review` Skill の「同じ revision の解析だけを使う」条件はほぼ成立しなかった。agent が解析結果を受け取る経路は事実上無かった。

候補は三つあった。server を残して全 repository の verify へ scanner を足す案、server を残して revision の対応付けを緩める案、同じ規則を各 repository の build と lint の analyzer へ移す案である。

一つ目は server と DB の固定費を残したまま、scanner の実行時間と server の稼働を全 repository の検証の前提にする。二つ目は古い解析を今の差分の根拠に使うことになり、review の証拠として誤る。三つ目は規則が build と lint の出力として編集した場でそのまま agent に届き、解析の古さと revision の到達性の問題が消える。失うのは傾向の dashboard だけである。

## Decision

`capabilities/code-quality/` を削除し、`code-quality` を host profile の Capability 選択から外す。SonarQube の container、DB、provisioning の service と timer、MCP target、SOPS の secret と template、暗号化済み store の `sonarqube` の key を廃止する。

cognitive complexity は各 repository の analyzer が測る。C# は SonarAnalyzer.CSharp の S3776、Rust は clippy の `cognitive_complexity`、TypeScript は architecture-standard の linter 規定に従い、通常の build と lint の段で新しい違反を失敗にする。既存の違反は各 project の抑止の仕組みに理由付きで列挙し、backlog にする。言語ごとの選定と閾値の正本は architecture-standard が持つ。

`code-review` Skill は、今回の source に対して build と lint が出した診断を静的解析の正本にする。`code-quality` だけが使っていた Skill の `optionalCapabilities` は、利用者がいなくなるため廃止する。

## Consequences

MCP target は 11 個から 10 個になり、port 8778 と、SonarQube と DB の container が無くなる。`dotfiles-rebuild` は container と secret を外すが、Docker の named volume は削除しない。`sonarqube-data`、`sonarqube-db`、`sonarqube-extensions`、`sonarqube-logs` は適用後に手で削除する。

project ごとの quality gate と解析履歴の閲覧は無くなる。傾向が必要になった場合は、全量検証の段で analyzer の指標を file へ出す。

SonarQube を再び置く判断をする場合は、解析の revision を review 対象へ対応付けられるか、server の固定費に見合う規則が S3776 以外にあるかを先に決める。
