---
name: commit-writing
description: Writes a commit message from the staged diff and repository policy. Use when asked for a commit message or immediately before committing staged changes. Names the changed target in the reader's terms and what changed there as one change with one revert reason, writes a type-prefixed subject in the form owned by architecture-standard, runs the subject through the commit-msg hook before finishing, and never changes the index. Does not write PR bodies, changelogs, or release notes.
---

# Commit messageを書く

件名の内容と形の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、正本を読んで件名へ当てる手順だけを持つ。

| 規則 | 正本 |
|---|---|
| 件名に書く対象と変化、一つの対象と変化、個人名の禁止 | `principles/documentation/commit-purpose.md` |
| 件名の文末、句読点、中黒と並列の接続 | `principles/documentation/sentence-endings.md` |

標準本文は、callerが明示した`<standard-root>`、なければAGENTSが案内する現行規範rootから読む。
配備済みSkillの所在から導いた固定版は使わない。
正本を読めない場合は記憶や過去の履歴で補わず、読めなかったrootまたはfileを示してmessageを作らない。

## 手順

1. repository rootの`AGENTS.md`と`CONTRIBUTING.md`、`git rev-parse --git-path hooks/commit-msg`が示すhookを読む。
   形式、type、長さ、bodyの可否はlocal policyに従い、type接頭辞はpolicyに記述がなくても省かない。
2. `git diff --staged`を読む。
   staged diffが空ならmessageを作らない。
3. 変更の対象と、その対象で何がどう変わったかを一つに定める。
   対象は読み手が扱う作業や物の名前(テーブル設計、注文の取消など)にし、変化は操作とそれで成り立つ結果で言う。
4. diff全体が同じ対象と変化、同じrevert理由を持つか確認する。
   対象を一つの名前で言えない、または複数の変化が混ざるなら、indexを変更せず、分けるべき対象とpathを報告する。
5. typeを差分の形ではなく変化に合わせて選ぶ。
   `test`や`docs`は、それ自体が変化の中身である場合だけ使う。
6. 正本の形で件名を書く。
   依頼文、issue、review、diffに現れた依頼者、作業者、参考にした人の名前は件名へ移さない。
7. 構造判断の文脈、代替案、帰結は、repositoryがADRを採用していればADRへ置く。
8. 日本語の語の選び方には、利用可能なら`ja-writing`を併用し、staged diffから確定した対象と変化を保つ。
   `ja-writing`が扱う散文の文の形は件名の文末と句読点に当てず、利用できない場合も正本とrepository policyで件名を仕上げる。

## 完了前の確認

1. 件名だけを有効なcommit-msg hookへ渡し、commitせずに同じ検査を実行する。
   `"$(git rev-parse --git-path hooks/commit-msg)" <(printf '%s\n' '<件名>')`で実行できる。
2. hookが拒否したら、表示された規則と正本に従って件名を書き直し、通るまで繰り返す。
   `--no-verify`、hookの無効化、hookが判定しない語形への置き換えで通さない。
3. hookが判定しない条件と、hookがないrepositoryでの全条件を、正本の完了条件で確かめる。
   一つの関心だけを述べているか、中黒が一つの関心を成す語だけを並べているか、個人名がないか、件名だけで対象と、そこで何がどう変わったかが読めるかを見る。
4. 書き直しても関心が二つ残るなら、語を削って隠さず、commitを分ける対象とpathを報告する。
5. 件名が規則に合うと報告するときは、実行したhookの結果と読んだ正本のfileを根拠にする。
   Skillや正本にない規定を、読まずにあると述べない。

## 失敗例

次の失敗は、どれも上の確認を飛ばした結果である。

| 誤った件名 | 飛ばした確認 | 直し方 |
|---|---|---|
| `fix: 規律の所在を層の定義に合わせて直す` | 末尾の語が動詞 | `fix: 層の定義と食い違う規律の所在の是正` |
| `CSS疑似要素が使うアイコン字形をサブセットに追加` | type接頭辞の欠落 | `feat: CSS疑似要素が使うアイコン字形のサブセットへの追加` |
| `feat: 一覧と件数を区分とタグで、検索を置き場で絞る` | 読点が示す二つの関心 | commitを分ける |
| `feat: 区分による一覧の絞り込み 置き場による検索の絞り込み` | 読点を空白に置き換えた二つの関心 | commitを分ける |
| `feat: SEOメタ・構造化データの追加` | 中黒で束ねた二つの関心 | 一つの対象と変化に言い直すかcommitを分ける |
| `fix: 佐藤さん指摘の件名の読点の拒否` | 個人名 | `fix: 読点を含む件名の拒否` |
| `feat: 事実の行から今の状態を導くデータ設計の採用` | 対象がなく目的だけの抽象的な名詞 | `feat: テーブル設計で状態の列を置かず事実の行から導く規律の追加` |
| `feat: data 原則への状態の導出の規律の追加` | repository内の分類の名前を対象にした | 読み手が扱う作業の名前を対象にする |
| hookを実行せず「Skillが体言止めを定めている」と報告した | 根拠の確認 | 正本を読み、hookの結果を示す |

空白、中黒、個人名をhookが判定するかは、対象repositoryのhookで確認する。
hookを通るだけでは、一つの関心と個人名の不在を確認したことにならない。

## 出力

repositoryが要求するcommit messageだけを出す。
候補を複数並べない。
確定できない場合はmessageを作らず、足りない事実を示す。

## 禁止事項

- staged stateを変更しない。
- 「更新」「修正」「整理」「採用」「整備」のような語だけで変化を隠さない。
- file名、directory名、層の名前、変更操作の列挙を、対象と変化の代わりにしない。
- 実行していない検証や、確認していないissueをmessageへ入れない。
- repository policyが禁じるscope、body、trailer、AI attributionを足さない。
