---
name: description-writing
description: Writes or restructures substantial technical prose such as README, ADR, specification, proposal, report, guide, or article for a known audience. Owns source-backed content and reader-question structure, then hands runnable procedures to article-reproduction and requested reader-experience checks to first-reader. Uses explainer only for its specialized learning-material job. Does not verify command execution itself, change a domain glossary, or write code comments, declaration documentation, commit messages, changelogs, or PR-only summaries.
---

# 構造的な技術文書を書く

## 執筆契約

最初に文書の種類、読者、読書中か作業中か、読後に必要な判断や行動を定める。
読者について依頼から分かる事実と推測を分け、既存template、同種文書、用語の正本を読む。
文書の役目が終わる条件も定め、固定した節数やtemplateの空欄から構成を作らない。

次の仕事だけは、通常の執筆と分ける。

- sourceに照らす図、出力注釈、HTMLを含む速習資料、または明示的に`explainer`が求められた場合は、利用可能な原版を読み、その仕事を引き渡す。
  読者の既知と未知、読後の問い、source locator、draftまたは対象、成果物の形式、実行許可、既存の検証記録を渡す。
  「内容を成立させる」のsource調査を先に終え、資料の生成と専用の検査を原版へ渡した後は「Reviewへ引き渡す」から再開する。
  戻る資料と検査範囲、未検証の主張を受け取り、同じ構成作成やreader試行をこちらでも繰り返さない。
  原版の広いtriggerを、すべての短い説明やPRの執筆へ広げない。
- 用語の意味、context、canonical term、`GLOSSARY.md`、domainのADRを確定または変更する必要がある場合は、利用可能な`domain-modeling`へ候補語、使用箇所、既存定義、矛盾するsourceと未決事項を渡す。
  確定した用語と記録のlocatorを受け取って執筆へ戻り、用語集の別ownerを作らない。
  既存用語を読むだけなら、そのまま執筆を続ける。

必要なSkillが利用不能な枝は、その仕事を未実施として返す。
別のSkillを模倣して、引渡し済みとは書かない。

## 内容を成立させる

1. source、code、test、decision recordから、書く主張に必要な事実を集める。
   公開情報の調査は`web-research`、所在や関係が未知のrepository調査は`repository-research`が利用可能なら渡し、locator付きの根拠と未確定事項を受け取る。
   事実、解釈、提案を分け、結果を変える背景が資料から得られない場合だけ書き手に質問する。
   sourceの選定と記述の正確さは書き手が所有し、reader反応や再現性reviewで代用しない。
2. 読者の問いに答える最小の構成を作り、種類に応じて[文書別の判断](references/document-types.md)を読む。
   既知の説明、網羅のための節、後で使わない詳細を足さず、見出しを拾い読みで引ける簡潔なラベルにする。
3. 一つの正本だけを置く。
   同期できない揮発値を転記せず、正本と取得方法を示す。
   手順では読者に必要な入力、開始状態、command、期待結果を揃え、期待結果と実行して観測した結果を区別する。
4. 通読して矛盾、重複、未定義語、読者にだけ見えない前提を編集する。
   各行を消したとき読者が誤るかで残す内容を決め、日本語なら`ja-writing`へ目的、読者、既存用語、事実と解釈を区別したdraftを渡す。
   戻った文面で契約と不確実性が保たれていることを確認する。
   同Skillが利用不能ならrepositoryの表記規則で仕上げ、専門の推敲が未実施であることを区別する。

## Reviewへ引き渡す

執筆中に判断した期待結果を、検証の成功と扱わない。
本文と必要な添付が揃ったrevisionを渡し、次の二つの判断を分ける。

### 手順の再現性

setup、tutorial、操作guide、READMEの開始手順など、読者がcommandや操作で結果へ到達する部分がある場合、または「動いた」と主張する場合は、利用可能な`article-reproduction`へ渡す。
再現対象のない概念説明、ADRの背景、単なる参照表には発火しない。

入力の形は、同Skillを読んで到達する`references/reproduction-contract.md`で定める。
記事と添付のrevision、読者と到達点、環境と開始状態、順序付きcommand、codeとconfig、sample入力、期待exitとstdoutとstderr、必要な生成物、source locator、既存の実行証拠、未実施事項、許可された副作用を揃える。
不足した値は空欄を推測で埋めず、不足として渡す。

返る判定、blocking箇所の引用とlocator、検証種別、commandごとの証拠、未実施範囲を採用して記事を修正する。
書き手は同じcommand実行や想像上の再現reviewを重ねず、変更した手順、期待結果、または前提だけを同じownerへ戻す。
既存の有効な証拠を再利用し、記事や環境が変わった範囲の再検証も実行許可がある場合に限る。
Skillが利用不能ならdraftは返せるが、再現性reviewは未実施であり、再現済みとは書かない。

### 読者の理解

beta readが依頼された場合、または大きな公開資料や重要な判断文書で、読み進め方、誤解、読後に残る判断を独立に確かめる必要がある場合は、利用可能な原版`first-reader`へ渡す。
完成したdraftのpathとrevision、読者、媒体と読む場面、読む時間、読後の問い、意図する要点を渡す。
書き手が既に全文を知っていることを伝え、初見の読みは原版が定めるfreshな実行contextで行う。
原版を独立したreader担当に渡す場合は、記事本文や書き手の解答をreaderの初期contextへ混ぜず、原版のfeedとlogの分離を保つ。
freshなreaderの起動が許可されていないworkerは、この入力と未実施理由をtop-level callerへ戻し、既に全文を知る自分の読みで代用しない。

引用付きの読者反応、離脱箇所、要点の受け取り、reportのlocatorを受け取り、修正の判断は書き手が行う。
模擬readerの反応やlogからのrecallを、人間による読解実測、翌日の記憶測定、commandの実行証拠とは呼ばない。
`explainer`が同じrevisionでこの仕事を既に行った場合は、その結果を受け取り、二度起動しない。
原版が利用不能なら理解検査は未実施とし、自前のreader simulationで補ったことにしない。

## 文書を閉じる

各読者の問いに本文または正しい入口があり、主張に根拠があり、返ったblocking点が解消されたrevisionを渡す。
再現性は「記述reviewのみ」「実行で再現」「実行失敗」「前提または権限不足」を区別し、未実施の検査を本文と報告から読み取れる形にする。
記述reviewだけで終えた記事は、手順の不足を調べたdraftとして渡せるが、実行で再現済みとは書かない。
実行による証明が依頼された場合は、その判定が成立するか、不足する環境と許可を明示するまで閉じない。
再現性ownerの判定をpublish許可や全claimの正しさへ広げず、reader反応を直すために根拠、契約、不確実性を変えない。
