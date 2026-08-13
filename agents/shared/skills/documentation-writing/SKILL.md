---
name: documentation-writing
description: Writes or revises documentation comments for types, functions, methods, fields, and other declarations. Use when documenting an API or internal declaration contract. Gets intended guarantees from authoritative repository contracts and checks them against implementation and tests. Does not write implementation comments, general documentation, or change history.
---

# 宣言の契約を書く

## 手順

1. 対象言語のdocumentation comment記法と、repositoryの既存形式を確認する。
2. 宣言の利用側と境界を特定する。公開宣言は境界外、非公開宣言は同じ境界内の呼び出し側が依存してよい契約を書く。
3. 仕様、schema、decision record、repository policy、declarationから、意図した目的、前提条件、事後条件、不変条件、副作用、失敗条件を抽出する。
4. 最初の一文で用途を示す。名前や型を言い換えず、利用側が呼ぶべき場面を判断できるようにする。
5. 該当する契約だけを書く。型から明白なparameter説明、空のreturnsやthrows節、実装手順を足さない。
6. 実装とtestは契約の正本にせず、意図した契約との整合確認に使う。矛盾は保証へ取り込まず、実装、test、契約のどれを直す判断が必要か報告する。不明な保証は推測しない。
7. 日本語なら`ja-writing`を併用する。

## 書かないもの

- 処理順、algorithm、private helperなど、呼び出し側が依存すべきでない実装詳細。
- 変更日、変更者、旧仕様、TODO、migration履歴。
- 型、名前、default値の単なる繰り返し。
- repositoryや言語が保証していない成功、例外、thread safety、idempotency。

名前の言い換えしか書けない場合は、コメントを増やす前に宣言の責務、分割、命名を疑う。
