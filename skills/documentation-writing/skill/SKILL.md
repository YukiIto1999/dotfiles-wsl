---
name: documentation-writing
description: Writes or revises documentation comments for types, functions, methods, fields, and other declarations, private ones included. Use when documenting an API or internal declaration contract. Gets intended guarantees from authoritative repository contracts, checks them against implementation and tests, covers every parameter, type parameter, and return value, and writes each line in the noun-ended label form owned by architecture-standard. Does not write implementation comments, general documentation, or change history.
---

# 宣言の契約を書く

ドキュメントコメントの内容、記法、形の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、契約を集めて正本の形へ当てる手順だけを持つ。

| 規則 | 正本 |
|---|---|
| 契約の内容、非公開宣言、引数と型引数と戻り値の網羅、markup | `principles/comment/declaration-contracts.md` |
| 最初の一行と各タグ、節、列挙の項目の文末と句読点 | `principles/documentation/sentence-endings.md` |
| 変更日、変更者、旧仕様、TODOの排除 | `principles/comment/no-history-in-source.md` |
| 同じ概念の同じ語、定着した語 | `principles/naming/unified-vocabulary.md` |
| 言語ごとの記法、タグ、節 | `languages/<言語>/conventions.md` |
| 言語ごとの機械検査 | `languages/<言語>/inspection.md` |

標準本文は、配備済みの`standard-apply` Skillの`SKILL.md`を実体まで辿り、その二段上のdirectoryから読む。
正本を読めない場合は記憶で補わず、読めなかったfileを示して止める。

## 手順

1. 対象言語の`languages/<言語>/conventions.md`と、repositoryの既存形式を確認する。
   標準に対象言語がなければ、言語の標準的な記法とrepositoryの既存形式に従い、形は同じ正本に従う。
2. 宣言の利用側と境界を特定する。
   公開宣言は境界外、非公開宣言は同じ境界内の呼び出し側が依存してよい契約を書き、非公開を理由に省かない。
3. 仕様、schema、decision record、repository policy、declarationから、意図した目的、前提条件、事後条件、不変条件、副作用、失敗条件を抽出する。
4. 最初の一行で、呼び出し側が呼ぶべき場面を判断できる目的を示す。
   名前や型を言い換えない。
5. 該当する契約だけを書く。
   該当しない節、定型文、処理順やalgorithmのような呼び出し側が依存すべきでない実装詳細を足さない。
6. 署名の引数、型引数、戻り値を記述と一対一で照合し、型が表さない役割か前提を全てに書く。
7. 実装とtestは契約の正本にせず、意図した契約との整合確認に使う。
   矛盾は保証へ取り込まず、実装、test、契約のどれを直す判断が必要か報告する。
   不明な保証は推測しない。
8. 日本語の語の選び方には`ja-writing`を併用する。
   `ja-writing`が扱う散文の文の形は、各行の文末と句読点に当てない。

名前の言い換えしか書けない場合は、コメントを増やす前に宣言の責務、分割、命名を疑う。

## 完了前の確認

1. 最初の一行が一行に収まり、宣言名を隠しても用途を判断できるか確かめる。
2. 最初の一行と各タグ、節、列挙の項目の末尾の語が名詞か確かめる。
   動詞、形容詞、「です」「ます」で終わる行は、名詞で終える形へ書き換える。
3. 各行に句点と読点がなく、句読点の代わりの空白や記号もないか確かめる。
4. 各行が一つの関心だけを述べているか確かめる。
   「または」「および」「と」や中黒で二つの関心を束ねた行は一つに言い直し、言い直せなければ宣言の責務と分割を疑って報告する。
5. 署名の引数、型引数、戻り値と記述の過不足を照合する。
6. 表示を整えるだけのmarkupと、括弧で後置した注釈がないか確かめる。
7. 対象言語の`inspection.md`が定める検査がrepositoryで有効なら、それを実行する。

## 失敗例

| 誤った記述 | 飛ばした確認 | 直し方 |
|---|---|---|
| `processPayment`の要約を「支払いを処理する」にした | 名前の直訳と動詞終わり | 呼び出し側が選ぶ場面を示す目的を名詞で終える |
| 要約を「台帳へ記帳し、競合を返す」にした | 読点が示す二つの関心 | 記帳を要約に、競合を失敗条件の行に分ける |
| 読点を消して「台帳への記帳 競合時の拒否」にした | 空白でつないだ二つの関心 | 同じく要約と失敗条件の行に分ける |
| 要約に「(entry point の Program.cs だけを許容)」を後置した | 括弧で後置した注釈と述語のない断片 | 前提条件として独立した行に書く |
| 段落のために`<p>`を足した | 表示だけのmarkup | 削除する |
| 自明に見える`@param`と`@returns`を省いた | 署名との照合 | 型が表さない役割か前提を書く |
| 非公開の宣言にだけ付けなかった | 非公開宣言の内部契約 | 同じ規則で付ける |
| 引数名を変えてもコメントを直さなかった | 署名との照合 | 同じ変更で契約を更新する |
