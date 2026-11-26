# 変更説明

pull requestの説明、changelog、release noteは、既に存在する変更をreviewer、利用者、運用者へ説明する。
commit messageは`commit-writing`が持つ。

## 範囲と目的を確定する

1. 成果物の種類、読者、基準点、対象範囲を確定する。branch全体、staged diff、tag間、指定commitなどを混ぜない。
   基準点か対象範囲が曖昧で結果が変わる場合は、推測して別の範囲を読む前に確認する。
   対象差分が空なら変更説明を作らない。
2. 依頼、issue、設計文書、commit、diffをこの順で調べ、変更の目的を確定する。
   差分だけから利用者の動機や組織事情を作らない。
3. 読者が観測する変更、互換性、migration、運用影響、riskを抽出する。内部実装は、それが外部の判断を変える場合だけ書く。
4. 実行済みの検証と未確認事項を分ける。検証commandを増やして説明の空欄を埋めない。
5. 同じ結果へ収束する細かなcommitは、読者が理解する一つの変更へまとめる。異なる目的は混ぜない。
   commit logをそのまま本文にしない。

全成果物へ同じtemplateを強制せず、次の構成から必要な項目だけを使う。
空の節と`none`のplaceholderを作らない。

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
移行手順は読者が実行する手順として本文の「手順の再現性」の対象にする。
