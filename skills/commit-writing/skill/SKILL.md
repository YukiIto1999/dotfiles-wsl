---
name: commit-writing
description: Writes a commit message from the staged diff and repository policy. Use when asked for a commit message or immediately before committing staged changes. Identifies one purpose and one revert reason, writes a type-prefixed subject in the form owned by architecture-standard, runs the subject through the commit-msg hook before finishing, and never changes the index. Does not write PR bodies, changelogs, or release notes.
---

# Commit messageを書く

件名の内容と形の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、正本を読んで件名へ当てる手順だけを持つ。

| 規則 | 正本 |
|---|---|
| 変更の目的、一つの目的と取り消し理由、個人名の禁止 | `principles/documentation/commit-purpose.md` |
| 件名の文末、句読点、中黒と並列の接続 | `principles/documentation/sentence-endings.md` |

標準本文は、配備済みの`standard-apply` Skillの`SKILL.md`を実体まで辿り、その二段上のdirectoryから読む。
正本を読めない場合は記憶や過去の履歴で補わず、読めなかったfileを示してmessageを作らない。

## 手順

1. repository rootの`AGENTS.md`と`CONTRIBUTING.md`、`git rev-parse --git-path hooks/commit-msg`が示すhookを読む。
   形式、type、長さ、bodyの可否はlocal policyに従い、type接頭辞はpolicyに記述がなくても省かない。
2. `git diff --staged`を読む。
   staged diffが空ならmessageを作らない。
3. 変更が解消する問題か成立させる目的を一つに定める。
   変更したfileや操作を主語にしない。
4. diff全体が同じ目的と同じrevert理由を持つか確認する。
   複数ならindexを変更せず、分けるべき目的とpathを報告する。
5. typeを差分ではなく目的に合わせて選ぶ。
   `test`や`docs`は、それ自体が変更目的の場合だけ使う。
6. 正本の形で件名を書く。
   依頼文、issue、review、diffに現れた依頼者、作業者、参考にした人の名前は件名へ移さない。
7. 構造判断の文脈、代替案、帰結は、repositoryがADRを採用していればADRへ置く。
8. 日本語の語の選び方には`ja-writing`を併用する。
   `ja-writing`が扱う散文の文の形は、件名の文末と句読点に当てない。

## 完了前の確認

1. 件名だけを有効なcommit-msg hookへ渡し、commitせずに同じ検査を実行する。
   `"$(git rev-parse --git-path hooks/commit-msg)" <(printf '%s\n' '<件名>')`で実行できる。
2. hookが拒否したら、表示された規則と正本に従って件名を書き直し、通るまで繰り返す。
   `--no-verify`、hookの無効化、hookが判定しない語形への置き換えで通さない。
3. hookが判定しない条件と、hookがないrepositoryでの全条件を、正本の完了条件で確かめる。
   一つの関心だけを述べているか、中黒が一つの関心を成す語だけを並べているか、個人名がないか、件名だけで目的が読めるかを見る。
4. 書き直しても関心が二つ残るなら、語を削って隠さず、commitを分ける目的とpathを報告する。
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
| `feat: SEOメタ・構造化データの追加` | 中黒で束ねた二つの関心 | 一つの目的に言い直すかcommitを分ける |
| `fix: 佐藤さん指摘の件名の読点の拒否` | 個人名 | `fix: 読点を含む件名の拒否` |
| hookを実行せず「Skillが体言止めを定めている」と報告した | 根拠の確認 | 正本を読み、hookの結果を示す |

空白、中黒、個人名の3件はhookを通るため、完了前の確認の3でしか見つからない。

## 出力

repositoryが要求するcommit messageだけを出す。
候補を複数並べない。
確定できない場合はmessageを作らず、足りない事実を示す。

## 禁止事項

- staged stateを変更しない。
- 「更新」「修正」「整理」のような語だけで目的を隠さない。
- file名や変更操作の列挙を目的の代わりにしない。
- 実行していない検証や、確認していないissueをmessageへ入れない。
- repository policyが禁じるscope、body、trailer、AI attributionを足さない。
