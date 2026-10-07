---
name: github-operations
description: Safely performs account-scoped GitHub reads and requested writes through configured GitHub MCP targets. Use when an agent must inspect or change a GitHub repository, issue, pull request, review, or branch. Resolves the acting identity and exact target, reads current state before writing, avoids duplicate retries, and requires last-moment confirmation for merges, deletions, and history-changing operations. Does not compose change descriptions, judge code reviews, write commit messages, search local repositories, or change GitHub authentication.
---

# GitHub上の操作を安全に実行する

GitHub MCPは実行手段である。このSkillは、誰としてどのresourceを操作するか、どのreadを根拠にwriteしてよいか、結果をどう確定するかを所有する。GitHub上で操作できることを、ユーザーがその副作用を依頼した証拠にはしない。

## 公開操作を解決する

`github-resources` Capabilityが公開するaccount別のgateway targetを使う。
操作名を推測せず、選んだtargetで現在公開されているtoolのschemaを読む。
このsessionのaccount-1なら`xd://mcp__gateway_github_account_1_get_me`などへJSON引数を渡し、account名をresourceのownerから組み立てない。

| 操作 | 現在のschemaで渡す入力 | 確認する返却値 |
|---|---|---|
| identity | 選んだtargetの`get_me`へ`{}` | 実行login |
| issueの現state | `issue_read`へ`method: "get"`、`owner`、`repo`、`issue_number` | canonical URL、番号、state、変更するfield |
| PRの現stateとdiff | `pull_request_read`へ`method: "get"`または`"get_diff"`、`owner`、`repo`、`pullNumber` | PR identity、head/baseとSHA、stateまたは実diff |
| branchの解決 | `list_branches`へ`owner`、`repo`と必要なpagination | exactなbranch名とhead SHA |
| issueの依頼された更新 | `issue_write`へ`method: "update"`、同じtarget、`issue_number`と変更するfieldだけ | 更新されたID、URL、state |
| 指定されたreviewの送信 | `pull_request_review_write`へ対象、`method`、確定した`event`、本文、必要な`commitID` | review ID、送信state、対象commit |

branchは一覧の一ページで不存在と決めず、対象のexact名を確認するまで必要なpageを読む。
reviewの`create`で`event`を省くとpending reviewを作るため、送信済みとは扱わない。
`submit_pending`は同じidentityのpending reviewを現stateで確認した場合だけ使い、thread操作には現reviewから得た`threadId`を使う。
他の操作も選んだtargetのschemaへ同じidentityとresource識別子を対応させる。
tool未公開、認証失敗、権限不足ではその境界を返し、provider、container、別account、認証を変更して回避しない。

branch作成が依頼された場合は、確認したsource branchを`create_branch`の`from_branch`、新branchを`branch`へ明示する。
file更新では同じbranchを`get_file_contents`の`ref`へ渡して現blob SHAを取得し、直前確認後に`create_or_update_file`へ`branch`、`path`、raw `content`、確定した`message`、既存fileなら`sha`を渡す。
mergeの直前確認後は、`merge_pull_request`へ対象PR、確認した`merge_method`と`expectedHeadSha`を渡し、結果のSHAとstateを確定する。
これらは選んだaccount targetに実際に公開されている場合だけ使い、secret設定など対応する公開操作がないwriteをproviderの直接APIで補わない。

## identityとtargetを固定する

1. 依頼と既存contextから、`account target`、実行主体のGitHub login、`owner/repo`、issueまたはPRの種別と番号、対象branchを取り出す。branch間の操作ではheadとbaseを区別する。
2. 完全修飾された指定、canonical URL、選択済みrepositoryやbranchのcontextを優先する。複数の根拠が食い違う場合は、一方を黙って採用しない。
3. 足りない値だけをread-only lookupで補う。候補account targetのidentityは`get_me`相当のreadで確認し、repository、issue、PR、branchはexact lookupの返り値で存在、種別、canonical owner/nameを確定する。広い一覧や曖昧なtitle検索は、exact lookupへ絞るために必要な場合だけ使う。
4. `account target`はresourceの`owner`とは別に固定する。明示された実行identityと一致するtargetを使い、明示がなければ既存contextとread結果から一意になるtargetだけを選ぶ。複数accountが同じ操作を行えることは選択理由にならない。
5. pre-read、write、結果確認は同じaccount targetで行う。選択したtargetに権限がなければ別accountへ黙って切り替えない。

対象または実行identityが一意にならない場合は、候補と曖昧な項目を示して止める。lookupのためにbranch、comment、draft reviewなどを作成してはならない。

## readとwriteを分ける

依頼を、GitHub上で成立させるpostconditionと、許可された副作用へ分解する。情報取得とtarget解決はreadであり、remote state、可視性、通知、履歴を変える呼出しはwriteとして扱う。

writeの前に、選択したaccount targetで対象の現stateを読む。対象の存在と種別に加え、変更するfield、open/closedやdraftなどの関連state、branchを扱う場合のexact refとhead SHAを記録する。古い会話、検索snippet、local branch名だけを変更前stateにしない。

現stateと依頼されたpostconditionを比較し、すでに成立していればwriteせずno-opとして返す。成立していない場合も、依頼された差分だけを一度実行する。例えば、PR作成からbranch作成を、comment追加からreactionやcloseを、field更新から別fieldの整形を推測して追加しない。複数の副作用を含む依頼では、それぞれが明示されていることを確認する。

write後は、返り値が新しいstate、ID、URL、またはSHAを確定しているか確認する。不足する場合だけexact resourceを再読する。確認できない成功を成功済みとして扱わない。

## merge、delete、履歴変更を確認する

merge、resource・file・branchのdelete、commitを生成するcontent変更、branchのheadまたはhistoryを動かす操作は、実行直前にユーザーの明示確認を得る。最初の依頼にその操作が含まれていても、直前確認の代わりにはしない。

確認には次を一度に示す。

- account targetと実行login
- 完全修飾した`owner/repo`と対象issue、PR、file、branch
- 実行する操作と、削除範囲、merge方法、historyへの効果など不可逆な差分
- pre-readで得た関連stateとexact SHA、および期待するpostcondition

確認後、writeの直前に同じ対象を再読する。state、head/base、対象範囲が確認時から変わっていれば確認を無効とし、新しい差分を示して再確認する。変化がなければ、確認された一操作だけを実行する。

## idempotencyと再試行

- 各writeはtarget、変更前state、postconditionの組として扱う。更新は可能なら直前に読んだstateまたはSHAをpreconditionにする。
- timeout、接続切断、5xxなどでwrite結果が不明な場合は、同じwriteを直ちに再送しない。exact resourceをreadし、postcondition、新しいID、commit、comment、reviewなど前回の効果を確認する。
- 効果が確認できれば再試行せず成功として確定する。実行されていないと証明でき、preconditionも変わっていない場合だけ同じwriteを一度再試行できる。証明できなければ重複を避けて止め、結果が不明であることを報告する。
- 新しいresourceを作るwriteは、同じtitleや本文でも別resourceになり得る。titleや本文の一致だけで同一性を決めず、返却されたID・URL、対象、実行identity、head/baseなど、その操作を一意にする値で確認する。
- conflictやstale stateでは再読して差分を作り直す。確認対象のmerge、delete、historyが変わるなら、再試行前に改めて確認を得る。writeを並列送信しない。

## 隣接Skillへ引き渡す

PR本文、changelog、release noteの作成が必要なら、利用可能な`change-writing`へ成果物、読者、exactな差分範囲、issue、互換性と実行済み検証を渡し、確定した変更説明を受け取る。
commit済み差分のreviewが必要なら、`code-review`へ利用者が指定したfixed pointとHEADのSHA、`git diff <fixed-point>...HEAD`で表す範囲、spec sourceと標準sourceを渡し、StandardsとSpecの所見を受け取る。
そのcommitted-range契約をstaged・unstaged差分のreviewや、approve、comment、request changesの判断へ広げない。
reviewの送信種別は利用者の指定または明示的に委ねられたreview判断から確定する。
commit messageが必要で、同じ変更を表す既存のstaged diffがある場合だけ、`commit-writing`へrepositoryとそのstaged diff、policyを渡し、検査結果を伴うmessageを受け取る。
remote contentだけの変更を同Skillのstaged-diff契約へ偽装せず、対応する入力がなければmessageの不足を返す。
このSkillは確定した内容と判断を対象resourceへ反映するだけで、表現や判断を作り直さない。
専門Skillが利用不能なら未作成の本文、message、または未実施のreviewを明示し、それを必要とするwriteは行わない。

生成と反映を一緒に依頼された場合は、隣接Skillの成果を得てから本手順へ戻る。handoffを理由に、identity確認、pre-read、直前確認を省略しない。

nuget.orgへ公開するpackageのOIDC設定、API keyからの移行、`NuGet/login`が主題なら、利用可能な`nuget-trusted-publishing`へpackage、公開workflow、repositoryと実行identity、現在の認証方式、許可された変更を渡す。
認証契約、必要なworkflow変更、移行の検証結果を受け取り、一般のGitHub releaseやprivate feedの依頼を同Skillへ広げない。
workflowやsecretの反映、release実行が明示的に依頼された場合だけ、確定した成果を同じaccount targetと直前確認の手順へ戻す。
Skillまたは必要な公開操作が利用不能なら、その仕事を未実施として返す。

## 安全に報告する

実行account targetとlogin、完全修飾したtarget、行ったreadまたはwrite、変更前stateを識別する値、結果のID・URL・state・SHAを必要な範囲で報告する。writeしなかった場合は、no-op、権限不足、未確認、または結果不明を区別する。再試行した場合は、最初の結果をどうreadで判定したかも示す。

API responseまたは結果確認で裏付けられた範囲だけを成功として述べる。credential、token、不要なprivate content、raw request/response全体は出力しない。

## 打ち切り条件と対象外

次の場合はwriteせず、確定できた事実と不足する判断を返す。

- account target、実行login、`owner/repo`、resource種別・番号、またはbranchが一意でない
- exactな変更前stateを読めない
- 依頼された副作用と現在のpostconditionが対応しない
- merge、delete、history変更の直前確認がない、または確認後に対象stateが変わった
- 先行writeの成否をreadでも確定できず、安全な再試行を証明できない

GitHub MCPのAPI一覧やparameter catalog、local repositoryの調査、diffの評価、変更説明・review判断・commit messageの作成、credential設定は対象外である。`gh auth login`と`gh auth switch`は実行しない。認証失敗や権限不足は、accountを切り替えて回避せず、そのidentityとtargetに対する失敗として報告する。
