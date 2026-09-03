---
name: change-writing
description: Explains an existing change to reviewers, users, or operators. Use for pull request descriptions, changelogs, and release notes based on an explicit diff range. Derives purpose, user-visible effects, compatibility, evidence, and rollout facts from source records. Does not invent motivation or write handoffs, general README, ADR, specification, code comments, or commit messages.
---

# 変更を説明する

## 手順

1. 成果物の種類、読者、基準点、対象範囲を確定する。branch全体、staged diff、tag間、指定commitなどを混ぜない。
2. 依頼、issue、設計文書、commit、diffをこの順で調べ、変更の目的を確定する。diffから分からない動機は作らない。
3. 読者が観測する変更、互換性、migration、運用影響、riskを抽出する。内部実装は、それが外部の判断を変える場合だけ書く。
4. 実行済みの検証と未確認事項を分ける。command名やcheck名は正本で確認し、実行していないものを完了済みにしない。
5. [成果物別の構成](references/artifacts.md)から必要な項目だけ使う。空の節と`none`のplaceholderを作らない。
6. 同じ結果へ収束する細かなcommitは、読者が理解する一つの変更へまとめる。異なる目的は混ぜない。
7. 日本語なら`ja-writing`を併用する。

## 打ち切り条件

基準点か対象範囲が曖昧で結果が変わる場合は、推測して別の範囲を読む前に確認する。対象差分が空なら変更説明を作らない。

## 禁止事項

- commit logをそのまま本文にする。
- 差分だけから利用者の動機や組織事情を作る。
- 全成果物へ同じtemplateを強制する。
- 検証commandを増やして説明の空欄を埋める。
- changelogへ利用者から見えない内部変更を載せる。
