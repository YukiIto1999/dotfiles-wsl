# ドキュメント

ルートの [README](../README.md) から着手した作業を、目的別の文書へ引き継ぐ。

## 構築

- [セットアップ](getting-started.md)では、新規ホストの enrollment から初回検証までの順序が分かる。

## 運用

- [rebuild](operations/rebuild.md)では、通常適用の効果判定と中断後の再開方法が分かる。
- [SOPS enrollment](operations/sops-enrollment.md)では、host key の登録、世代移行、中断復旧の手順が分かる。
- [secrets](operations/secrets.md)では、暗号化済み secret の編集方法と鍵の扱いが分かる。
- [OCI image](operations/oci-images.md)では、upstream image の確認、同期、更新手順が分かる。
- [doctor](operations/doctor.md)では、実用状態の検査項目と失敗時の調査先が分かる。

## 構成

- [構成概要](architecture/overview.md)では、NixOS、Home Manager、生成 command の責務境界が分かる。
- [AI tooling](architecture/ai-tooling.md)では、AI CLI、agentgateway、MCP server、Docker backend の接続関係が分かる。
- [セキュリティ設計](architecture/security.md)では、credential、host key、通信経路の信頼境界が分かる。
- [ツール構成](reference/tooling.md)では、導入済み CLI、agent、skill、MCP、service と正本が分かる。

## 変更

- [開発](development.md)では、devShell、整形、ローカル検査、CI の使い分けが分かる。
- [変更箇所](reference/change-map.md)では、変更目的ごとの正本と適用方法が分かる。

## 設計判断

- [ADR](adr/README.md)では、現行構成を選んだ理由と変更時に見直す判断が分かる。

## 監査

- [2026-07-29 ツール構成監査](audits/2026-07-29-tooling.md)では、横断利用と稼働状態を基にした改善順序が分かる。
