# ドキュメント

ルートの[README](../README.md)から、目的に合う現在の手順、構成、参照先へ進む。
`docs/`に作業ログ、日付ごとの実測、過去の調査、未実装の計画を蓄積しない。
それらは追跡対象外の`work/`へ置き、有効になった契約と手順だけを対応する文書へ反映する。

## 手順 — `operations/`

目的の作業をやり遂げたい運用者が、作業中に読む。

- [セットアップ](operations/getting-started.md)では、新規ホストの鍵の用意から初回検証までの順序が分かる。
- [rebuild](operations/rebuild.md)では、通常適用の効果判定と中断後の再開方法が分かる。
- [データの復旧](operations/recovery.md)では、設定と永続dataの再現境界、WSLのbackup、別名restoreの成功条件が分かる。
- [SOPS の鍵](operations/sops-enrollment.md)では、鍵の置き場、secret の編集、新しい host の登録が分かる。
- [secrets](operations/secrets.md)では、暗号化済み secret の編集方法と鍵の扱いが分かる。
- [OCI image](operations/oci-images.md)では、upstream image の確認、同期、更新手順が分かる。
- [doctor](operations/doctor.md)では、実用状態の検査項目と失敗時の調査先が分かる。
- [Agent client](operations/agent-clients.md)では、現在の checkout からの更新、日次 timer、release の確認方法が分かる。
- [作業日誌](operations/agent-journal.md)では、omp の作業日誌の出力先、日次 timer、作り直し方が分かる。
- [記憶の収穫](operations/memory-harvest.md)では、omp の session 記録から訂正を project memory へ保存する timer、log の読み方、状態の扱いが分かる。
- [Git hook](operations/git-hooks.md)では、dotfiles の検査と repository の hook の実行順序、repository の信頼、検証の段の入口、push 前の検証と省略の記録が分かる。
- [開発](operations/development.md)では、devShell、整形、ローカル検査、CI の使い分けが分かる。

## 説明 — `architecture/`

責務の境界と要素間の関係を理解したい人が、学習中に読む。操作手順は持たず、構造とそれを決めた設計判断を扱う。

- [構成概要](architecture/overview.md)では、Profile、Workstation、Agent、Skill、Capability、Platform、運用基盤の責務境界が分かる。
- [責務と履歴の凝集](architecture/cohesion.md)では、unit、file、commitを分ける基準が分かる。
- [AI tooling](architecture/ai-tooling.md)では、AgentからSkill、Capability、MCP/container Platformへ至る依存関係が分かる。
- [Skill source](architecture/repository-skills.md)では、固定した上流原版の直接登録と、供給元を明示的に差し替える契約が分かる。
- [Skill portfolio](architecture/skills.md)では、直接採用する原版のIDと来歴、routing、残すcustom Skillの責務が分かる。
- [セキュリティ設計](architecture/security.md)では、credential、host key、通信経路の信頼境界が分かる。

## 参照 — `reference/`

正本の場所と現在値の取り方を調べたい人が、作業中に読む。宣言の値そのものは持たず、宣言の場所を指す。

- [ツール構成](reference/tooling.md)では、導入済みCLI、Agent、Skill、Capability、MCP、serviceの正本が分かる。
- [変更箇所](reference/change-map.md)では、変更目的ごとの正本と適用方法が分かる。
- [機械検証に固定した制約](reference/verified-constraints.md)では、どの制約が build で守られ、どれが守られていないかが分かる。

## 決定 — `adr/`

構造に影響する判断の経緯を確かめたい人が、判断を見直すときに読む。

構造に影響する現在有効な判断を、`docs/adr/`へ一件ずつ置く。
ファイル名は4桁の連番と英語kebabのslugにする。
Status、Context、Decision、Consequencesで現在の契約、比較した候補、採らない理由を示す。
判断を置き換えた場合は、過去の記録を`work/`かGit履歴へ残し、追跡文書の本文と参照を新しい判断へ揃える。
