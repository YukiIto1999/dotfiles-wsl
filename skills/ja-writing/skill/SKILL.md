---
name: ja-writing
description: Writes and revises Japanese technical prose for a known audience and purpose. Use for Japanese README, ADR, specification, explanation, change description, report, or article, and when asked to remove generic or AI-like wording. Writes complete sentences placed one per Markdown line, uses established field terms instead of coined words, and keeps emphasis minimal, following architecture-standard. Preserves uncertainty and project terminology. Does not decide facts, document type, code-comment content, or identifier names, and does not apply prose sentence form to commit subjects, implementation comments, or documentation comments, whose noun-ended label form their own Skills own.
---

# 日本語を書く

文章の内容を先に成立させ、読者に合う日本語へ整える。
AIらしさの判定や人間らしさの演出を目的にしない。

文の形、語、強調、公開文書の言語の規則と理由は、architecture-standardが所有する。
このSkillは規則を写さず、正本を文章へ当てる手順と推敲の観点だけを持つ。

| 規則 | 正本 |
|---|---|
| 散文の文末、一文一行、述語を欠いた断片 | `principles/documentation/sentence-endings.md` |
| 分野で定着した語、独自の訳語と造語 | `principles/naming/unified-vocabulary.md` |
| 強調の絞り込みと各行の削除テスト | `principles/documentation/minimal-high-signal.md` |
| 公開するlibraryのREADMEとCHANGELOGの言語 | `principles/documentation/separate-document-types.md` |

標準本文は、配備済みの`standard-apply` Skillの`SKILL.md`を実体まで辿り、その二段上のdirectoryから読む。
正本を読めない場合は記憶で補わず、読めなかったfileを示して止める。

## 手順

1. 読者、文書の目的、読後に必要な判断や行動を確認する。
   repositoryに既存文書、用語、templateがあれば先に読む。
2. 境界外へ公開するlibraryのREADMEかCHANGELOGなら、日本語で書くか、どの版を正本にするかを正本で確かめる。
3. 根拠のある事実、そこからの解釈、提案を分ける。
   確認できない事実を補わず、不確実性を保つ。
4. 一段落に一つの主張を置き、主題文と論理展開で書く。
   「構造化」を口実に安易に箇条書きへ逃げず、箇条書きは項目が同じ構造と同じ抽象度で並ぶときだけ使う。
5. 見出しは主題を一言で射抜く簡潔なラベルにする。
   見出しにカッコ、英語対訳、数量、注釈を含めない。
6. 因果、対比、経緯は地の文で書く。
   「AはBである」の短文連打を避け、主客と目的を明示した自然な複文を構成する。
   単語を中黒で数珠つなぎにせず、読点や接続詞で自然に結ぶ。
7. 段落と箇条書きは、正本が定める散文の形で書く。
8. 同じ概念には同じ語を使う。
   新しい語や訳語を作る前に、その概念に分野で定着した語があるかを確かめ、あればその語を使う。
   対象、主体、条件を曖昧な「これ」「ツール」「仕組み」で隠さない。
9. 読者と媒体に合う敬体か常体を選び、既存文書に合わせる。
   語尾を機械的に散らさない。
   同じ文型や同じ節構成が3回続いたら、一つは入り口を変える。
   均一と反復のどちらを避けるか迷ったら、読者の負荷が下がるほうを選ぶ。
10. [推敲観点](references/revision.md)を使い、内容を変えずに空句、過剰な評価、定型構成、不要な装飾を除く。
    既存文書では直す箇所を選び、全体へ一律に当てない。

## 散文の形を当てない記述

commitの件名、実装コメント、ドキュメントコメントの各行は、句点で閉じないラベルであり、散文とは逆に名詞で終える。
その形は`commit-writing`、`comment-writing`、`documentation-writing`が正本に従って所有する。
これらへ句点を足したり、完結した文へ書き換えたりしない。
語の選び方の手順だけは、これらにも使える。
見出し、表のセル、linkを並べる台帳や目次の項目も、散文の形の対象にしない。

## 完了前の確認

1. 段落と箇条書きの各行が、句点で終わる一つの文だけを持つか確かめる。
2. 「…だけ」「…など」のように述語を欠いた断片で終わる文がないか確かめる。
   あれば、省いた述語を補った文に書き換える。
3. 定義を読まないと意味を結ばない訳語、造語、無理に和訳したカタカナ語がないか確かめる。
   あれば、分野で定着した語に戻す。
4. 強調ごとに、外しても読者が誤らないかを問い、誤らないなら外す。
5. 各行を消したとき読者が誤るかを問い、誤らない行を消す。

## 失敗例

| 誤った書き方 | 飛ばした確認 | 直し方 |
|---|---|---|
| `対象は明示した差分だけ。` | 述語を欠いた断片 | `対象は明示した差分に限る。` |
| 一行に句点で区切った複数の文を並べた | 一文一行 | 句点ごとに改行する |
| `worktree`を「作業木」と訳した | 分野で定着した語 | `worktree`のまま書く |
| 意味の通らない「(鶏卵)」を文末に後置した | 括弧で後置した注釈 | 文に組み込むか削る |
| 各段落の要点を太字にした | 強調の削除テスト | 見落とすと読者が誤る少数の文だけに残す |
| commitの件名へ句点を足して文にした | 散文の形を当てない記述 | `commit-writing`の形に戻す |

## 他のwriting Skillとの関係

成果物固有の事実と構成は、該当するSkillが所有する。
`commit-writing`はcommitの目的と件名の形、`change-writing`は差分の説明、`description-writing`は構造的な文書、`documentation-writing`は宣言の契約と各行の形、`comment-writing`は実装コメントの要否と形を決める。
日本語で書く場合だけ、このSkillで表現を整える。

## 打ち切り条件

必要な事実、読者、文書の目的が分からず、既存資料からも確認できない場合は推測で埋めない。
欠けている情報と、それが文章のどの判断を変えるかを示す。
