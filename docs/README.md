# ドキュメント

ルートの [README](../README.md) から着手した作業を、種別別の文書へ引き継ぐ。ディレクトリと文書の種別は一対一である。種別と読み手は [ADR 0017](adr/0017-documentation-kinds.md)に定めている。

## 手順 — `operations/`

目的の作業をやり遂げたい運用者が、作業中に読む。

- [セットアップ](operations/getting-started.md)では、新規ホストの enrollment から初回検証までの順序が分かる。
- [rebuild](operations/rebuild.md)では、通常適用の効果判定と中断後の再開方法が分かる。
- [SOPS enrollment](operations/sops-enrollment.md)では、host key の登録、世代移行、中断復旧の手順が分かる。
- [secrets](operations/secrets.md)では、暗号化済み secret の編集方法と鍵の扱いが分かる。
- [OCI image](operations/oci-images.md)では、upstream image の確認、同期、更新手順が分かる。
- [doctor](operations/doctor.md)では、実用状態の検査項目と失敗時の調査先が分かる。
- [開発](operations/development.md)では、devShell、整形、ローカル検査、CI の使い分けが分かる。

## 説明 — `architecture/`

責務の境界と要素間の関係を理解したい人が、学習中に読む。手順と判断理由は持たない。

- [構成概要](architecture/overview.md)では、NixOS、Home Manager、生成 command の責務境界が分かる。
- [AI tooling](architecture/ai-tooling.md)では、AI CLI、agentgateway、MCP server、Docker backend の接続関係が分かる。
- [セキュリティ設計](architecture/security.md)では、credential、host key、通信経路の信頼境界が分かる。

## 参照 — `reference/`

正本の場所と現在値の取り方を調べたい人が、作業中に読む。宣言の値そのものは持たず、宣言の場所を指す。

- [ツール構成](reference/tooling.md)では、導入済み CLI、agent、skill、MCP、service の正本が分かる。
- [変更箇所](reference/change-map.md)では、変更目的ごとの正本と適用方法が分かる。
- [機械検証に固定した制約](reference/verified-constraints.md)では、どの制約が build で守られ、どれが守られていないかが分かる。

## 決定の記録 — `adr/`

四種別とは別の軸である。なぜその構成を選び、何を却下したかを書く。決定した時点で凍結し、後の判断は新しい ADR が置換する。

- [ADR](adr/README.md)では、現行構成を選んだ理由と変更時に見直す判断が分かる。
