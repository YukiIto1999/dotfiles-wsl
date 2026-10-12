---
name: code-quality
description: Acquires SonarQube static-analysis evidence on the caller side, runs an explicitly authorized project scan with the upstream scanner, and judges whether stored findings apply to current source. Use for Sonar issues, quality gates, analysis freshness, or supplementary evidence passed in a code-review brief. Does not orchestrate a second review or require Sonar availability for review.
---

# SonarQube の静的解析証拠を使う

現在の source を正本とし、SonarQube の保存結果を検証すべき候補根拠として扱う。
既存の `code-review` の Standards/Spec review、project の build・lint・test は、それぞれの手順に従って継続する。
`code-review` の caller が必要時に取得と現在への照合を済ませ、証拠 bundle を Standards/Spec subagent の brief に渡す。
read-only reviewer に MCP が公開されていない場合も、渡された bundle を使い、backend 接続や権限の拡張で迂回しない。
この手順は一つの証拠取得を担当し、review plan を増やさない。

## 対象と権限を固定する

1. 対象 project の現在の source path、Sonar project key、解析したい範囲を、project-owned scanner 設定か caller の指定から確定する。
   key を repository 名から推測しない。
2. 保存済み結果の取得と、新しい source 解析を分ける。
   取得は読み取り専用だが、scan は source を server へ送信し、project の結果を更新する。
   新しい scan はその project と送信範囲に対する明示の許可があるときだけ行う。
3. scanner の種類、source/test/exclusion、必要な build output・coverage、quality profile/gate を project の設定から読む。
   Maven、Gradle、.NET は、それぞれの upstream build-specific scanner を使い、CLI で代用しない。
   未知 project の作成、権限付与、token 発行は owner の setup が先で、取得失敗を理由に自動変更しない。

## 保存済み結果を取得する

`code-quality` Capability の `sonarqube` provider が公開する公式 MCP tool を使う。
現在公開された schema を読んで引数を合わせる。
URI device の client では、公開一覧にある `...sonarqube...` tool の `xd://` schema が入口である。

- 生存状態は `get_system_status` であり、`UP` は今回の source が解析済みである証拠ではない。
- project key の確認には `search_my_sonarqube_projects` を使い、見えない project は不存在と権限不足を区別できる範囲までにする。
- issues は `search_sonar_issues_in_projects` に対象 project を明示し、必要な page を取得する。
  空 page を全件ゼロと扱わない。
- gate は `get_project_quality_gate_status` に分かっている analysis ID を渡す。
  project key だけの取得は最新結果であり、指定した過去解析の gate とは断定しない。
- 保存済み source の対応を確かめる必要がある場合は `get_raw_source` と `get_scm_info` を使う。
  server 上の source と現在の checkout を同一視しない。

取得時刻と、tool の入力・結果の locator を記録する。
latest issues と analysis ID 指定の gate が同じ snapshot を指すとは限らない。
同じ解析への対応を Activity/CE metadata などで確定できなければ、endpoint ごとの観測として返し、対応を不明にする。
この配備の MCP は project の解析履歴や Compute Engine task を独自 tool で追加しない。
解析日時・revision・analysis ID は、project の CI receipt、scanner receipt と SonarQube の Background Tasks/Activity UI で確定する。
UI 操作が必要なら `browser-operation` に対象 instance と project の読み取りだけを渡す。
metadata が得られない場合は「入力/解析日時不明」と記録し、取得した issues を捨てず、現在の検証済み結果とも呼ばない。

provider 非公開、認証失敗、server 未起動、解析なしは、それぞれ不足する証拠として返す。
private backend の探索や認証迂回で補わず、既存の source review と project の検証を止めない。

## 承認された source を解析する

CLI 向け project は project-owned `sonar-project.properties` と、MCP の読み取り用 User token とは別の project analysis token が前提である。
credential は SOPS の runtime file など source tree 外の private file に置き、値を表示・argv に載せない。
properties、coverage、receipt に credential を書かず、scanner の verbose/debug 出力を有効にしない。

```bash
dotfiles-sonarqube-scan --cwd <absolute-project-root> --project-key <approved-key> --token-file <private-runtime-file>
```

この command は実 upstream SonarScanner CLI を起動し、非機密 receipt の path と scanner exit を stdout に返す。
receipt は開始/終了時刻、Git revision と dirty 状態、観測した入力 fingerprint、run ID、`report-task.txt` の CE task ID を持つ。
`--wait` は upstream scanner に処理と gate の待機を要求し、gate の失敗を非zeroで伝える。通常取得のために全 project の gate を強制しない。
upload の成功と analysis complete を分け、待機しない scan では Background Tasks の同じ CE task が `SUCCESS` になったことを確認してから結果へ進む。
CE task の analysis ID と、解析日時・run ID を receipt に対応付けてから MCP で gate/issues を取得する。

CLI の fingerprint は Git tracked と non-ignored untracked file の開始/終了時点の観測であり、immutable snapshot ではない。
ignored build output、submodule の内容、server の profile/gate 変更は別に確認する。
解析中の source 変更を避ける。開始/終了で差がある場合や Git 外の入力では、入力の確定に必要な不足を残す。

## 現在への適用を判断する

各根拠について、解析入力と解析日時、取得時点、現在の source への適用状態を別々に示す。
現在への適用状態は次から選び、理由と current source の locator を添える。

- **現在で確認済み**: 指摘の対象 file/symbol と rule の条件を、現在の source で確認した。過去解析全体が現在の検証済みになった意味ではない。
- **候補として適用**: 対象構造が残っているが、現在の条件や依存を確認しきれていない。
- **現在には非適用**: 対象構造が削除・変更され、指摘の条件が成り立たないことを現在の source で確認した。
- **不明**: 入力、日時、対象対応、rule/profile、coverage の不足で判断できない。

Git SHA の不一致・履歴の到達不能だけで候補を拒否しない。同じ SHA でも dirty input や設定変更があれば同一解析ではない。
新しい scan も対象範囲の静的解析であり、review 全体や現在の全要件の検証済みという結論へ広げない。

## 返す証拠

対象 project/path、取得か新規解析か、scanner と analyzer の版、config/profile と分析 scope、解析入力の fingerprint と revision/dirty 状態、analysis/task ID、解析日時、取得時刻、endpoint ごとの issues/gate locator、現在への適用状態と source 照合根拠を caller 向け bundle にして返す。
入手できない profile/analyzer/input metadata は不明と明示し、dirty=true だけを実内容の識別に使わない。
不足がある場合は何が得られなかったかと、既存 review で継続できる範囲を明記する。
実行しなかった scan や、過去結果の取得を今回の検証として報告しない。
