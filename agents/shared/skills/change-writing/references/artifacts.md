# 変更成果物の構成

## Pull request

reviewerが判断するために必要な順で書く。

- 目的: 解消する問題か成立させる目的。
- 変更: reviewerが追う主要な境界と振る舞い。
- 証拠: 実行済みの検証と結果。
- 影響: compatibility、migration、rollout、rollback、既知の未確認事項。
- 関連資料: 実在するissue、ADR、仕様だけ。

repository templateがあれば従う。情報のない節は省く。checkboxは実施状況を区別する必要がある場合だけ使う。

## Changelog

tagやreleaseの利用者が観測する結果を書く。commit typeは候補の抽出に使えるが、分類と文言は実際の効果で決める。

- `Added`: 新しく利用できる能力。
- `Changed`: 既存能力の振る舞いの変更。
- `Deprecated`: 将来除去する能力と移行先。
- `Removed`: 利用できなくなった能力。
- `Fixed`: 利用者が遭遇した不具合の解消。
- `Security`: 利用者が対応すべきsecurity上の変更。

破壊的変更には、影響を受ける利用者と移行方法を添える。空の分類、内部refactoring、検査だけのcommit、release作業自体は載せない。既存`CHANGELOG.md`の形式を優先する。

## Release note

変更を使うか、移行するか、運用を変えるかを判断できる内容にする。主要な価値、互換性、移行手順、既知の制約を必要な順で置く。changelogの全項目を繰り返さない。
