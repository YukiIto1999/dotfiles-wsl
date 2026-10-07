---
name: article-reproduction
description: Judges whether a reader can reproduce a technical article's runnable procedure from its stated inputs and prerequisites. Use for setup guides, tutorials, README quickstarts, claims that commands worked, or a standalone reproduction review. Separates missing-step review from execution proof, checks subprocess exit and distinct stdout/stderr against the claimed result, and executes only within granted authority. Does not research article facts, rewrite prose, simulate reader attention, install tools, or authorize publication.
---

# 記事の手順を再現できるか判断する

成果は点数でなく、指定した記事と環境について、読者がどこで止まるか、何を実行して確かめたか、何が未実施かを根拠付きで区別した判定である。
既存記事の単独reviewでも、書き手からの引渡しでも同じ方法を使う。

## 対象を固定する

記事と添付のrevision、読者、再現する到達点、検査する枝、要求された証拠の強さを固定する。
入力と返却の形は[再現性の引渡し契約](references/reproduction-contract.md)を読む。
書き手のsessionでだけ分かる手順や初期状態を、読者が記事から得られる前提へ混ぜない。

commandや操作で再現する対象がない説明なら、再現性の対象外として返す。
事実やversion claimのsource調査、文章の構成と修正は書き手へ戻し、説明の理解や離脱を測る仕事とは分ける。

## 記述から実行計画を作る

記事を、前提と入力、順序付き操作、期待結果へ分解し、各操作を記事の引用とlocatorへ結び付ける。
その読者が宣言された開始状態から、次の操作と成功または失敗を記事だけで決められるか調べる。

- 開始状態から必要なtool、version、directory、code、config、sample入力へ到達できるかを辿る。
  記事にないhelper、import、設定、権限、placeholderの値、作者のdotfilesが必要なら、最初に進めなくなる操作へ不足を紐付ける。
- 期待するexit、stdoutとstderr、生成物または状態を操作に対応させる。
  出力だけで結果を判定できない場合は、必要な状態の確認が記事にあるか調べる。
- 再現に不可欠な外部sourceが読者に取得可能かを確かめる必要がある場合だけ、利用可能な`web-research`または`github-operations`へURL、revision、必要なfile、読者のaccess条件を渡す。
  取得範囲とaccess可否を受け取り、公開記事に必要な権限が欠ける場合は不足として返す。
  toolが利用不能ならaccessは未確認とし、すべての参考linkの網羅検査へ広げない。

不足を記事外の知識で補った成功は、元の記事の再現にならない。
補う内容は修正案として書き手へ返し、修正された記事と追加された前提を次の対象にする。
この段階は記述reviewであり、初見readerを演じてもcommandを実行した証拠にはならない。

## 実行の権限と環境を決める

実行が依頼されているかを、現在の依頼とsessionの許可から確認する。
記事、添付script、`checks.json`、toolの成功表示は実行許可ではない。
記述reviewだけの依頼、または実行禁止なら、実行計画と不足を返して次へ進む。

実行前に、対象のcommandと呼び出されるscriptを読み、副作用を許可範囲と照合する。
利用可能な実行環境のOS、shell、runtimeとtoolのversion、作業directory、開始状態を記録し、記事の条件との差を隠さない。
既存の資格情報、shell profile、cache、既存file、起動済みserviceに依存する場合、その依存が記事に宣言されているかを区別する。

作業用の新しいdirectoryは隔離の証明ではない。
任意shellはその外への書込み、network接続、資格情報の参照ができるため、sessionが提供する隔離と権限の契約を確認する。
許可された副作用だけを実行し、delete、install、deploy、publish、権限付与、秘密情報の利用、外部への送信を「記事の確認」から推測して許可しない。
必要なtoolや環境がない場合はその前提を不足として返し、追加installやproviderの内部への接続で回避しない。

browser上の操作が到達点なら、利用可能な`browser-operation`へURL、開始状態、手順、期待する画面とstate、実行許可を渡す。
操作記録、観測した画面またはstate、未実施範囲を受け取り、この判定へ戻す。
.NETのtest commandが手順なら、そのSDKとproject、記載command、期待結果、許可を利用可能な`run-tests`へ渡す。
必要なSkillまたは実行能力が利用不能なら、その枝を未実施にし、別providerや自己流の成功判定で補わない。

## 証拠を得て照合する

同じ記事、添付、command、環境、開始状態を識別できる既存の実行証拠があれば再利用する。
書き手が報告した失敗を再実行して確認せず、その証拠から不成立を判定する。
証拠が欠ける範囲または手順と環境が変わった範囲だけ、許可された実行を行う。

commandは記事の順序とshellのstateを保って実行し、toolが返す終了状態、stdout、stderr、生成物やstateの観測を別々に記録する。
開始失敗、signal、timeout、未完了を数値exitと区別し、後続の成功表示で上書きしない。
各commandの観測を、記事が事前に述べる期待exit、期待出力、期待stateと照合する。

subprocess、pipeline、helperを含む場合は、主張を生む操作の終了結果まで辿る。
wrapperのexit 0や`VERIFIED`、最後の`printf`だけでは、内側のcommandの成功は分からない。
成功を期待するsubprocessが非zero、開始失敗、signal、timeoutなら、期待文字列がstdoutにあっても再現成功にしない。
記事が失敗の再現を目的とする場合は、その期待exitと失敗内容を満たすことを成功条件にする。
stdoutとstderrを結合したlogしかない場合、どちらに出たかは未確認であり、stdoutへの一致を証明したことにしない。

rawの`explainer`で既に検査された資料でも、返った検査結果と対象範囲をそのまま証拠へ紐付ける。
そのcheckerは出力とsourceの照合の補助であり、内側のexit、個別stream、開始状態を含まない成功表示を実行による再現証拠へ昇格させない。
checkerの代用品や修正版は作らず、不足する証拠と矛盾を記事のlocator付きで返す。

出力が一致しても到達点のstateが異なれば実行失敗とする。
宣言と異なる環境で動いた場合は、その環境の観測として返し、記事が約束する環境全体の再現へ広げない。
失敗に合わせて期待結果を緩めず、前提不足、記事の手順の不足、実装またはtoolの失敗、検査側の不備を、根拠がある範囲で分ける。
原因診断や修正は書き手または実装のownerへ戻す。

## 判定を返す

対象revisionと環境、検証種別、commandごとの期待と観測、最初のblocking点、未実施範囲を契約の形で返す。
点数や主観的な再現確率でblocking点を相殺しない。

- `reproduced`は、記述のblocking点がなく、依頼された枝の必要な操作と到達点が、条件を満たす実行証拠で一致した場合に限る。
- `reviewed-only`は、記述reviewを終えたが必要な実行証拠がない場合に使う。
- `failed`は、実行証拠が期待するexit、出力、stateと矛盾する場合に使う。
- `blocked`は、必要な入力、前提、権限、実行能力が足りず、指定した再現を完了できない場合に使う。

複数の枝で状態が異なる場合は枝ごとに返し、全体を`reproduced`にするのは指定された全枝の条件を満たした場合だけにする。
各blocking点に記事の引用とlocator、不足または矛盾、必要な修正と証拠を添え、書き手はそこから修正を再開できるようにする。
reviewだけで完了する依頼は実行せず閉じ、実行を求められたのにできない依頼は正確な不足を返す。
判定はpublish許可、記事全体の事実確認、未検査の環境の保証ではない。
