---
name: code-annotation
description: Decides what text belongs next to code and writes the smallest justified form. Use when adding, revising, or reviewing documentation comments for types, functions, methods, fields, and other declarations, private ones included, or implementation comments inside executable code. Separates a declaration's contract, taken from authoritative repository contracts and checked against the signature, implementation, and tests, from a non-obvious rejected alternative and the current constraint that forbids it. Applies the content and noun-ended line rules owned by architecture-standard and runs the repository's enabled analyzers for machine-checkable form. In reviews, reports findings without editing. Does not write repository prose, agent instructions, change history, TODOs, or commented-out code.
---

# コードのそばに契約と理由を置く

成果は、宣言の利用側が依存してよい契約と、codeから読めない実装上の理由だけが、正本の形でcodeのそばにある状態である。
それ以外の説明はcodeの明瞭化、仕様、decision record、commitへ置き、commentを増やして補わない。

## 正本を読む

ドキュメントコメントと実装コメントの内容、記法、形の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、残すものを決めて正本の形へ当てる手順だけを持つ。

| 規則 | 正本 |
|---|---|
| 宣言の契約の内容、非公開宣言、引数と型引数と戻り値の網羅、markup | `principles/comment/declaration-contracts.md` |
| 実装コメントに残せる内容としての採らなかった実装と現在も有効な制約 | `principles/comment/rejected-alternatives.md` |
| 削除するcodeの処理の説明 | `principles/comment/no-code-explanation.md` |
| 変更日、変更者、旧仕様、作業メモ、TODO、コメントアウトしたcodeの排除 | `principles/comment/no-history-in-source.md` |
| 各行、最初の一行、各タグ、節、列挙の項目の文末と句読点 | `principles/documentation/sentence-endings.md` |
| 同じ概念の同じ語、定着した語 | `principles/naming/unified-vocabulary.md` |
| 言語ごとの記法、タグ、節 | `languages/<言語>/conventions.md` |
| 言語ごとの機械検査 | `languages/<言語>/inspection.md` |

標準本文は、callerが明示した`<standard-root>`、なければAGENTSが案内する現行規範rootから読む。
配備済みSkillの所在から導いた固定版は使わない。
正本を読めない場合は、読めなかったrootまたはfileと標準に照らせなかった判断を報告し、repositoryのpolicyと既存の形式が定める範囲で仕上げる。
記憶や一般的なcomment作法で正本の規則を補わない。

reviewだけを依頼された場合は、残す、削除する、codeを直す、契約を直す、正本へ移す、のfindingだけを返す。
編集が依頼範囲にある場合だけ変更する。

## 置く場所を決める

対象のcommentごとに、次のどれに当たるかを先に決める。

- 宣言の利用側が依存してよい保証: 「宣言の契約」でドキュメントコメントにする。
- codeから読めない、採らなかった実装と現在の制約: 「実装コメント」で残す。
- codeから読める処理の説明、変更履歴、作業メモ、TODO、コメントアウトしたcode: 削除し、必要ならcommitやdecision recordへ置く。
- repositoryの説明文、利用者向けの文書: `technical-writing`の仕事であり、commentへ書かない。
- agent向けの指示: `writing-for-agents`の仕事であり、commentへ書かない。

## 宣言の契約

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

名前の言い換えしか書けない場合は、コメントを増やす前に宣言の責務、分割、命名を疑う。
署名や契約を変えた同じ変更で、ドキュメントコメントも更新する。

## 実装コメント

1. コメントを外して、配置、分割、命名、制御の流れ、型から現在の処理を読めるか確認する。
2. 読めなければコメントを足さず、まずcodeを明瞭にする。
3. 読み手が自然に選びそうな別実装と、それを採れない現在の制約があるか確認する。
4. 両方がcodeから読み取れず、将来同じ誤りが起き得る場合だけ短いコメントを残す。
5. 既存の仕様やdecision recordが正本なら、それを参照する。
   構造へ影響する長期的な決定でrepositoryがADRを採用している場合だけ、新しいADRへ分ける。
6. 残すコメントを正本の形で書く。

```text
<現在も有効な制約>のため<自然な代替案>は不可
```

文型は固定しない。
代替案と制約が具体的に分かり、名詞で終わる一行なら語順を変えてよい。

## 完了前の確認

両方の種類に共通して確かめる。

1. 各行（ドキュメントコメントでは最初の一行と各タグ、節、列挙の項目）の末尾の語が名詞か確かめる。
   動詞、形容詞、「です」「ます」で終わる行は、その動作や状態を表す名詞で終える形へ書き換える。
2. 各行に句点と読点がなく、句読点の代わりに空白や記号で二つの内容をつないでいないか確かめる。
3. 各行が一つの関心だけを述べているか確かめる。
   「または」「および」「と」や中黒で二つの関心を束ねた行は一つに言い直す。
   言い直せなければ、ドキュメントコメントでは宣言の責務と分割を疑って報告し、実装コメントでは行を分け、代替案と制約の組にならない行を削除する。
4. 対象言語の`inspection.md`が定める検査がrepositoryで有効なら、それを実行する。
   analyzerが判定した規則はその結果に従い、analyzerが扱わない規則は上の確認で判定する。

ドキュメントコメントでは次も確かめる。

5. 最初の一行が一行に収まり、宣言名を隠しても用途を判断できるか確かめる。
6. 署名の引数、型引数、戻り値と記述の過不足を照合する。
7. 表示を整えるだけのmarkupと、括弧で後置した注釈がないか確かめる。

実装コメントでは次も確かめる。

8. 各コメントについて、自然に見えるどの実装を、現在のどの制約によって採れないかを答えられるか確かめる。
   答えられないコメントは削除する。

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
| `// 指数バックオフは採らない。上流のRetry-Afterが正本のため。` | 句点と動詞終わり。旧templateの写し | `// 上流の Retry-After が待機時間の正本のため指数バックオフは不採用` |
| `// 上流の Retry-After を優先 指数バックオフは不採用` | 句読点の代わりに空白でつないだ二つの内容 | 制約を理由として一つの行に言い直す |
| `// メッセージを順に送信する` | codeから読める処理の説明 | 削除する |
| `// 性能のため` | 採らなかった実装と制約の特定 | 代替案と制約を書けなければ削除する |
| `// 2026-08の障害対応で追加` | 変更履歴 | 削除し、必要ならcommitかdecision recordへ置く |
